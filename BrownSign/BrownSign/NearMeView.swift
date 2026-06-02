//
//  NearMeView.swift
//  BrownSign
//
//  Nearby discovery tab — surface brown-sign-worthy landmarks. The
//  list shows places within 5 miles of the user's GPS, sorted by
//  distance. The map starts the same way but supports pan-to-search:
//  when the user pans far enough, we fetch another 5 miles centered
//  on the new map location and merge the pins in. Pins accumulate
//  across the areas the user explores, so you can build up a dotted
//  trail of landmarks by panning around.
//
//  The fetch primary is a Wikidata SPARQL query that returns only
//  items with a heritage designation (P1435) or a curated landmark
//  P31 type (recursive via P279*) — server-side equivalent of "would
//  this be on a brown highway sign?". See `WikidataLandmarkSearch`
//  for the query and allowlist; `discoverLandmarksAt` in
//  `LandmarkResult` handles hydration and the operating-institution
//  gate that drops still-active schools/stations.
//

import SwiftUI
import SwiftData
import CoreLocation
import UIKit
import MapKit

struct NearMeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HiddenLandmark.dateHidden, order: .reverse)
    private var hiddenLandmarks: [HiddenLandmark]

    private enum LoadState {
        case idle
        case loading
        case locationDenied
        case locationUnavailable
        case loaded([LandmarkResult])
        case empty
        case serviceUnavailable
    }

    /// Sub-phase of `.loading`, surfaced as the spinner's label so a
    /// slow cold-start tells the user what it's waiting on instead of
    /// one static string for the whole location→search→hydrate chain.
    private enum LoadingPhase {
        case locating
        case searching
        var message: String {
            switch self {
            case .locating: return "Getting your location…"
            case .searching: return "Finding landmarks near you…"
            }
        }
    }

    /// Search-radius options (miles), stepped by the map zoom control and
    /// the list-header stepper. 2 mi is the default (cleanest, least
    /// cluttered first view); 5/10/25 widen out for sparser areas or a
    /// broader sweep. Server-side distance ordering (see
    /// `discoverLandmarksViaSPARQL`) keeps the closest results correct even
    /// at the wide end. The pan-refetch threshold is half the current
    /// radius, so it scales with the chosen radius.
    private static let radiusOptionsMiles = [2, 5, 10, 25]
    private static let defaultRadiusIndex = 0   // 2 mi
    private static func radiusMeters(forMiles miles: Int) -> Int {
        Int(Double(miles) * 1609.344)
    }
    /// How many landmarks to hydrate + render per fetch. Set to the SPARQL
    /// result cap so the *radius* governs how many show: widening always
    /// surfaces more (and farther) landmarks instead of stopping at an
    /// artificial 100, which in a dense area filled up within ~10 miles and
    /// made 25-mile look identical to 10-mile.
    private static let fetchLimit = 300
    /// Upper bound on accumulated nearby results. Pan-merge and load-more
    /// both append into the set; without a ceiling a long session grows it
    /// (and its re-sorts) without bound. Sorted nearest-first before the
    /// cap, so it keeps the closest results. Generous enough that no real
    /// session reaches it.
    private static let maxNearbyResults = 1000

    @State private var state: LoadState = .idle
    @State private var loadingPhase: LoadingPhase = .locating
    /// Index into `radiusOptionsMiles` for the current search radius.
    /// Stepped by the +/- controls; seeded from the disk cache on
    /// cold-start so the restored pins and the "Within N miles" header
    /// agree.
    @State private var radiusIndex = NearMeView.defaultRadiusIndex
    /// In-flight primary refreshes. A COUNTER, not a Bool: `startRefresh`
    /// cancels the prior refresh, but a cancelled task's `defer` decrement can
    /// land after the superseding task's increment, so a Bool would flicker
    /// the toolbar spinner off mid-fetch when the radius is stepped quickly.
    /// Same reason `panFetchCount` is a counter.
    @State private var reloadingCount = 0
    private var isReloading: Bool { reloadingCount > 0 }
    @State private var userLocation: CLLocation?
    /// Center of the most recent geosearch. Drives the pan-threshold
    /// check: if the new map center is more than
    /// `panRefetchThresholdMeters` from this, fire another fetch.
    /// Also seeded from the disk cache on cold-start so the spatial
    /// invalidation check (current GPS vs. cached center) can run as
    /// soon as the fresh GPS fix lands.
    @State private var lastFetchCenter: CLLocationCoordinate2D?
    /// The map's current visible center, updated on every pan (and on the
    /// programmatic camera moves the map reports). Lets a radius change
    /// anchor to what's on screen once the user has panned away from their
    /// GPS, instead of snapping home. nil until the map first reports a center.
    @State private var mapCenter: CLLocationCoordinate2D?
    /// The `UIScrollView` backing the Nearby `List`, resolved via a small
    /// introspection finder. A radius increase nudges the content DOWN by half
    /// a row as a "more appeared below" cue — a precise sub-row offset that
    /// `List` + `ScrollViewReader.scrollTo` (row-granular) can't express, so we
    /// set `contentOffset` directly. nil until the list first lays out.
    @State private var listScrollView: UIScrollView?
    /// Measured height of a Nearby list row (the first one), so the nudge moves
    /// exactly half a row regardless of the dynamic-type size that drives row
    /// height. Includes the row's vertical insets.
    @State private var measuredRowHeight: CGFloat = 0
    /// Latest in-flight refresh task. Tracked so a second refresh
    /// (rapid toolbar-tap, pull-then-tap) cancels the first instead
    /// of racing with it. Without this, two `AsyncStream` consumers
    /// could both write to `state` and the user would see results
    /// flicker between the two fetches.
    @State private var refreshTask: Task<Void, Never>?
    /// Latest in-flight pan-search task. Mirrors `refreshTask`:
    /// rapid map pans (continuous swipe across threshold boundaries)
    /// cancel the previous fetch instead of dropping the later pan
    /// position. Also cancelled by `startRefresh` so a primary refresh
    /// can't be raced by a stale pan-merge.
    @State private var panTask: Task<Void, Never>?
    /// Latest in-flight "load more" page fetch. Cancelled on tab-switch
    /// (`.onDisappear`) and superseded by a primary refresh, like the other
    /// two — its `Task.isCancelled` checks then bail cleanly.
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var pushedLookup: LandmarkLookup?
    @State private var displayMode: LandmarkDisplayMode = .list
    /// Incremented by `refresh(force: true)` to tell the map view to
    /// snap its camera back to the user's location. The map's camera
    /// is its own `@State` — the parent can't reach in to update it
    /// directly — so we pass this counter down and the map observes
    /// it via `.onChange`.
    @State private var recenterSignal = 0
    /// Explicit recenter target for the map. Set by a radius-decrease so
    /// the camera zooms IN before the pins are trimmed; nil = fit the
    /// current pins (the normal recenter).
    @State private var recenterRegion: MKCoordinateRegion?
    @State private var searchText: String = ""
    @State private var showHiddenSheet = false
    /// True when the current fetch returned a full SPARQL page, i.e. the
    /// radius holds more landmarks than are shown — drives the "Load more"
    /// list footer. Reset on each primary fetch.
    @State private var hasMore = false
    /// SPARQL pages loaded at the current center/radius (1 after the
    /// initial fetch). "Load more" fetches page `pagesLoaded` via
    /// OFFSET = pagesLoaded × `sparqlResultLimit`, then increments.
    @State private var pagesLoaded = 0
    /// True while a "load more" page is in flight (footer shows a spinner).
    @State private var isLoadingMore = false
    /// Count of in-flight pan-search fetches (a counter, not a Bool, so
    /// overlapping fetches during continuous panning keep the map's
    /// "Loading…" pill up until the last one finishes).
    @State private var panFetchCount = 0

    private let locationManager = LocationManager.shared

    // MARK: - Radius

    private var currentRadiusMiles: Int { Self.radiusOptionsMiles[radiusIndex] }
    private var currentRadiusMeters: Int { Self.radiusMeters(forMiles: currentRadiusMiles) }
    private var canIncreaseRadius: Bool { radiusIndex < Self.radiusOptionsMiles.count - 1 }
    private var canDecreaseRadius: Bool { radiusIndex > 0 }

    /// When the user has panned the map away from their GPS by more than the
    /// pan-search threshold (half the current radius), the live map center;
    /// otherwise nil. When non-nil a radius change anchors here (filter/fetch
    /// + zoom around what's on screen) instead of snapping back to the user.
    /// Only meaningful on the map; the list is always user-anchored.
    private var pannedMapCenter: CLLocationCoordinate2D? {
        guard displayMode == .map, let center = mapCenter, let user = userLocation else { return nil }
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        guard centerLoc.distance(from: user) > Double(currentRadiusMeters) / 2 else { return nil }
        return center
    }

    /// Step the search radius by `delta` (+1 wider, −1 tighter), clamped to
    /// the ladder, then refetch at the new radius. `force: false` keeps the
    /// current pins visible (no full-screen spinner) and reuses the cached
    /// GPS fix; the existing recenter refits the map to the new extent once
    /// the fetch lands.
    private func changeRadius(by delta: Int) {
        let newIndex = max(0, min(Self.radiusOptionsMiles.count - 1, radiusIndex + delta))
        guard newIndex != radiusIndex else { return }
        let decreasing = newIndex < radiusIndex
        // Capture the pan anchor BEFORE mutating radiusIndex (so the "panned
        // away" test uses the radius currently on screen). Non-nil = the user
        // panned the map away from their GPS, so anchor the change to the map
        // center instead of snapping home; nil = default GPS-anchored path.
        let anchor = pannedMapCenter
        radiusIndex = newIndex

        // Narrowing the radius: the smaller radius is a subset of what's
        // already loaded, so just filter the current results by distance —
        // instant, no network, no loading flash. Only valid when our data
        // actually reaches past the new radius (we trimmed something);
        // otherwise (a dense area where even the wider fetch capped short)
        // fall through to a real fetch.
        if decreasing, case .loaded(let current) = state, let user = userLocation {
            // Trim + zoom around the panned map center when panned away, else
            // the user's location (the default).
            let centerCoord = anchor ?? user.coordinate
            let centerLoc = CLLocation(latitude: centerCoord.latitude, longitude: centerCoord.longitude)
            let maxMeters = Double(currentRadiusMeters)
            let filtered = current.filter { r in
                guard let c = r.coordinates else { return true }
                return centerLoc.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) <= maxMeters
            }
            if filtered.count < current.count {
                hasMore = false
                if displayMode == .map {
                    // Map: zoom IN first (to the new radius) keeping the
                    // current pins, THEN trim the out-of-range ones once the
                    // camera has moved — so they leave off-screen instead of
                    // popping out from under the camera.
                    recenterRegion = MKCoordinateRegion(
                        center: centerCoord,
                        latitudinalMeters: maxMeters * 2,
                        longitudinalMeters: maxMeters * 2
                    )
                    recenterSignal += 1
                    let targetIndex = radiusIndex
                    Task {
                        // Wait for the zoom-in camera animation to visually
                        // settle before removing the now-out-of-range pins, so
                        // they leave after the map has finished zooming rather
                        // than mid-animation (which looked odd). The camera
                        // animation runs ~0.8s; 0.9s clears it with a small
                        // margin. Erring long is fine (pins linger a beat);
                        // too short trims mid-zoom.
                        try? await Task.sleep(for: .seconds(0.9))
                        guard radiusIndex == targetIndex, case .loaded = state else { return }
                        state = .loaded(filtered)
                        recenterRegion = nil
                    }
                } else {
                    // List: trim immediately (no camera to animate).
                    state = .loaded(filtered)
                }
                return
            }
        }

        // Widening (or a narrow we can't satisfy from cache): refetch,
        // keeping the current list/pins visible during the fetch (the
        // toolbar spinner and the map's "Loading…" pill show progress).
        // recenter: true — fit the map to the new (wider) result set once
        // it lands. reuseLocation: true — a radius change doesn't move the
        // user.
        if let anchor = anchor {
            // Panned away on the map: widen around the map center, not the
            // user, and zoom out around it. Never snaps back to the GPS.
            fetchAroundCenterForRadiusChange(anchor)
        } else {
            let task = startRefresh(force: false, recenter: true, reuseLocation: true)
            // List + widening: the wider-radius rows append below the fold, so
            // from the top it looks unchanged. Once the fetch commits more
            // rows, nudge the content DOWN by half a row as a "more appeared
            // below" cue. Half a row (not a full one) reads as a gentle hint,
            // and because the new rows append below, the same downward nudge
            // works whether the user was at the top (0 → half-row) or at the
            // bottom (the old max-scroll now has rows below to advance into).
            // (Map mode recenters instead; a narrowing refetch adds no rows.)
            if displayMode == .list, !decreasing, case .loaded(let before) = state {
                let beforeCount = before.count
                Task {
                    await task.value
                    // Let the widened set commit and lay out so the new rows
                    // exist below the fold (and contentSize has grown) before we
                    // scroll toward them.
                    try? await Task.sleep(for: .milliseconds(150))
                    guard displayMode == .list,
                          case .loaded(let after) = state,
                          after.count > beforeCount,
                          let scrollView = listScrollView else { return }
                    // Read the live offset (List keeps it put when rows append
                    // below) and advance half a row, clamped so it never
                    // overscrolls past the content's end.
                    let halfRow = (measuredRowHeight > 0 ? measuredRowHeight : 84) / 2
                    let maxOffsetY = max(
                        scrollView.contentSize.height
                            + scrollView.adjustedContentInset.bottom
                            - scrollView.bounds.height,
                        -scrollView.adjustedContentInset.top
                    )
                    let targetY = min(scrollView.contentOffset.y + halfRow, maxOffsetY)
                    scrollView.setContentOffset(
                        CGPoint(x: scrollView.contentOffset.x, y: targetY),
                        animated: true
                    )
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Show the list/map picker whenever we've got a
                // location, not just when results are loaded. In the
                // .empty state we explicitly tell the user to switch
                // to the map and pan — they need the switcher visible
                // to actually do that.
                if displayModePickerVisible {
                    DisplayModeSegmentedPicker(selection: $displayMode)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // 16pt below the picker — matches the VStack(spacing: 16)
                    // gap between the "Snap a landmark sign" button and the
                    // text field on the Scan card.
                    SearchField(
                        text: $searchText,
                        placeholder: "Search nearby landmarks"
                    )
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 2)
                }

                Group {
                    switch state {
                    case .idle, .loading:
                        loadingView
                    case .locationDenied:
                        ContentUnavailableView {
                            Label("Location permission needed", systemImage: "location.slash")
                        } description: {
                            Text("Brown Sign uses your location to find landmarks near you. Turn on location access in Settings.")
                        } actions: {
                            Button {
                                LocationManager.openAppSettings()
                            } label: {
                                Label("Open Settings", systemImage: "gear")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color("BrandBrown"))
                            .buttonBorderShape(.roundedRectangle(radius: 12))
                        }
                    case .locationUnavailable:
                        ContentUnavailableView(
                            "Can't find your location",
                            systemImage: "location.slash",
                            description: Text("Try again once you have GPS signal.")
                        )
                    case .serviceUnavailable:
                        // SPARQL fetch (Wikidata) failed transiently —
                        // timed out, retries exhausted, or task
                        // cancelled. Distinct from `.empty`: we can't
                        // know whether the area has landmarks until
                        // the service responds. Surface as retryable
                        // so the user isn't told an area is empty
                        // when it isn't.
                        ContentUnavailableView {
                            Label("Couldn't load landmarks", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("There was a problem reaching the landmark service. This is usually temporary.")
                        } actions: {
                            Button {
                                startRefresh(force: true)
                            } label: {
                                Label("Try again", systemImage: "arrow.clockwise")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color("BrandBrown"))
                            .buttonBorderShape(.roundedRectangle(radius: 12))
                        }
                    case .empty:
                        // In list mode, explain the emptiness and
                        // point the user at the map + pan affordance.
                        // In map mode, just show an empty map —
                        // panning will fetch more and things will
                        // populate as the user explores.
                        switch displayMode {
                        case .list:
                            ContentUnavailableView(
                                "No landmarks nearby",
                                systemImage: "signpost.right.and.left",
                                description: Text("No geo-tagged Wikipedia landmarks within \(currentRadiusMiles) miles of your location. Switch to the map to widen the search, or pan to a different area to keep exploring.")
                            )
                        case .map:
                            nearbyMap([])
                        }
                    case .loaded(let results):
                        let visible = visibleResults(from: results)
                        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        switch displayMode {
                        case .list:
                            // List mode + active search filter that
                            // narrows to zero hits → explicit "No
                            // results" instead of a blank list. Map
                            // mode keeps the empty map so the user
                            // can pan-search to find more.
                            if visible.isEmpty && !trimmedSearch.isEmpty {
                                ContentUnavailableView(
                                    "No results",
                                    systemImage: "magnifyingglass",
                                    description: Text("No nearby landmarks match \"\(trimmedSearch)\".")
                                )
                            } else {
                                list(visible)
                            }
                        case .map:
                            nearbyMap(visible)
                        }
                    }
                }
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Custom principal title — system inline title is
                // ~17pt; 21pt is ~25% larger as Sean asked for.
                ToolbarItem(placement: .principal) {
                    Text("Nearby")
                        .font(.system(size: 21, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Spin whenever a fetch is in flight, including a
                    // pan-search on the map: mirrors the map's "Loading…"
                    // pill (isReloading || panFetchCount > 0) so the two
                    // loading cues stay in sync. panFetchCount is only ever
                    // > 0 on the map, so list mode still keys off isReloading.
                    if isReloading || panFetchCount > 0 {
                        ProgressView()
                    } else {
                        Button {
                            startRefresh(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .navigationDestination(item: $pushedLookup) { lookup in
                LandmarkDetailView(lookup: lookup)
            }
            .sheet(isPresented: $showHiddenSheet) {
                HiddenLandmarksView()
            }
        }
        .task {
            // Stale-while-revalidate cold-start: render last session's
            // pins instantly from the disk cache so the user isn't
            // staring at a spinner while SPARQL + hydration runs. The
            // fresh fetch kicks immediately afterwards and replaces
            // these pins as its yields arrive. `lastFetchCenter` is
            // seeded so `refresh` can spatially invalidate the cache
            // if the user has moved cities between sessions.
            if case .idle = state, let cached = NearbyResultsCache.load() {
                // Always start at the default radius (we don't restore the
                // last-used one). Only render last session's pins instantly
                // when they were fetched at that same default radius;
                // otherwise (e.g. a 25-mile cache) start clean and let the
                // fast 2-mile fetch populate, so we never flash wide-radius
                // pins under a "Within 2 miles" header.
                if cached.radiusMeters == currentRadiusMeters {
                    state = cached.results.isEmpty ? .empty : .loaded(cached.results)
                    lastFetchCenter = CLLocationCoordinate2D(
                        latitude: cached.fetchCenter.latitude,
                        longitude: cached.fetchCenter.longitude
                    )
                }
            }

            await startRefresh(force: false).value

            // Auto-retry only on .locationUnavailable — that's the case
            // a 1 s wait can plausibly fix (the GPS first-fix landed
            // late). `.empty` is no longer a retry trigger: SPARQL
            // transient failures are already retried inside
            // `httpDataWithRetry`, and a genuinely empty area shouldn't
            // re-fire the whole pipeline. Pre-warming the GPS at app
            // launch (BrownSignApp) makes this branch rare anyway.
            if shouldAutoRetryInitialFetch {
                try? await Task.sleep(for: .seconds(1))
                if shouldAutoRetryInitialFetch {
                    await startRefresh(force: false).value
                }
            }
        }
        .onDisappear {
            // Stop streaming SPARQL + Wikipedia hydration when the user
            // leaves the Nearby tab. These are stored unstructured tasks, so
            // SwiftUI's `.task` auto-cancellation doesn't reach them; without
            // this they keep fetching and writing state off-screen. Re-entry
            // re-runs `.task`, which refetches in the background while the
            // retained in-memory pins stay visible.
            refreshTask?.cancel()
            panTask?.cancel()
            loadMoreTask?.cancel()
        }
    }

    /// True while the initial-load state is one a retry can plausibly
    /// fix — currently only `.locationUnavailable`. `.empty` is not a
    /// retry candidate because SPARQL transient failures are already
    /// handled by `httpDataWithRetry`'s internal ladder.
    private var shouldAutoRetryInitialFetch: Bool {
        switch state {
        case .locationUnavailable: return true
        default: return false
        }
    }

    /// Cancels any in-flight refresh and starts a new one. Returns the
    /// new task so callers that need to await completion (the initial
    /// `.task` body, pull-to-refresh) can do so. Toolbar button taps
    /// don't need to await — they're fire-and-forget.
    /// Also cancels any pan-search in flight: a primary refresh
    /// supersedes a pan-merge, and letting a stale pan write after
    /// the refresh has reset the list would clobber the fresh results.
    @discardableResult
    private func startRefresh(force: Bool, recenter: Bool = true, reuseLocation: Bool = false) -> Task<Void, Never> {
        refreshTask?.cancel()
        panTask?.cancel()
        loadMoreTask?.cancel()
        let task = Task {
            await refresh(force: force, recenter: recenter, reuseLocation: reuseLocation)
        }
        refreshTask = task
        return task
    }

    /// Cancels any in-flight pan-search and starts a new one for the
    /// given map center. Called from the map's `onMapCenterChanged`
    /// callback — when the user is actively swipe-panning across
    /// `panRefetchThresholdMeters`, the most recent pan position is
    /// the one we want, not whichever earlier pan happened to start
    /// first. `fetchAroundMapCenter` checks `Task.isCancelled` at every
    /// await point, so a cancelled fetch stops cheaply.
    private func startPanFetch(_ center: CLLocationCoordinate2D) {
        panTask?.cancel()
        panTask = Task {
            await fetchAroundMapCenter(center)
        }
    }

    /// Apply the user's hide-list and the search-text filter to the
    /// raw discover results. Both filters compose: a landmark whose URL
    /// is hidden never appears, and what's left is narrowed by partial
    /// (case-insensitive) substring match against the title.
    private func visibleResults(from results: [LandmarkResult]) -> [LandmarkResult] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Common case (nothing hidden, no active search): skip the Set
        // build and the filter pass entirely.
        if hiddenLandmarks.isEmpty && q.isEmpty { return results }
        let hiddenURLs = Set(hiddenLandmarks.map(\.pageURLString))
        return results.filter { r in
            if hiddenURLs.contains(r.pageURL.absoluteString) { return false }
            if q.isEmpty { return true }
            return r.title.lowercased().contains(q)
        }
    }

    private var hasResults: Bool {
        if case .loaded = state { return true }
        return false
    }

    /// The Nearby map for `results`, with the shared controls and chrome.
    /// Both the empty-state map (no pins) and the loaded map route through
    /// this so the long parameter list lives in one place.
    private func nearbyMap(_ results: [LandmarkResult]) -> some View {
        NearbyMapView(
            results: results,
            userLocation: userLocation,
            recenterSignal: recenterSignal,
            onSelect: { open($0) },
            onMapCenterChanged: { center in
                mapCenter = center
                startPanFetch(center)
            },
            radiusMiles: currentRadiusMiles,
            canIncreaseRadius: canIncreaseRadius,
            canDecreaseRadius: canDecreaseRadius,
            onIncreaseRadius: { changeRadius(by: 1) },
            onDecreaseRadius: { changeRadius(by: -1) },
            isLoading: isReloading || panFetchCount > 0,
            recenterRegion: recenterRegion
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 16)
        // Same gap below the map as above so the tab bar has breathing
        // room, matching the search-field-to-map gap.
        .padding(.bottom, 16)
    }

    /// True when a map is currently on screen (loaded pins or the
    /// empty-area map), so a background refetch — e.g. a radius change that
    /// widens an empty search — keeps the map visible instead of flashing
    /// the full-screen spinner.
    private var isShowingMap: Bool {
        guard displayMode == .map else { return false }
        switch state {
        case .loaded, .empty: return true
        default: return false
        }
    }

    /// Show the list/map picker any time the user has a location —
    /// even in the .empty state, because the empty-state copy tells
    /// the user to switch to map and pan, and we need the picker
    /// visible for them to do that.
    private var displayModePickerVisible: Bool {
        switch state {
        case .loaded, .empty: return true
        default: return false
        }
    }

    private var loadingView: some View {
        NearbyLoadingView(message: loadingPhase.message)
    }

    @ViewBuilder
    private func list(_ results: [LandmarkResult]) -> some View {
        // "Load more" footer shows only when the radius holds more than
        // the current page AND we're not filtering (paging a filtered
        // list would be confusing).
        let showLoadMore = hasMore && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Lat/long context row sits OUTSIDE the List so it doesn't
        // steal the inset-grouped section's rounded top corners from
        // the first landmark row. Inside the List with a clear
        // background, the List still treats it as row 0 and applies
        // top-rounded corners there — making the first visible row
        // look chopped.
        VStack(spacing: 0) {
            if userLocation != nil {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill")
                        Text("Within \(currentRadiusMiles) miles of your location")
                    }
                    Spacer(minLength: 8)
                    // Trailing radius stepper so the list can widen/tighten
                    // the search without switching to the map. Same step
                    // logic as the map's zoom control.
                    RadiusStepper(
                        canIncrease: canIncreaseRadius,
                        canDecrease: canDecreaseRadius,
                        onIncrease: { changeRadius(by: 1) },
                        onDecrease: { changeRadius(by: -1) }
                    )
                }
                // Match the "Recent finds" section header on Scan
                // (subheadline + semibold) so the three list-section
                // labels read consistently across tabs. Lat/long
                // values used to live in this string but wrapped to
                // a second line at the larger size — dropped them
                // since the user already knows where they are.
                // Bottom padding matches Scan's 8pt VStack spacing
                // between header and list; top stays at 16 for
                // breathing room between the search field above and
                // the section header.
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            List {
                // Identify rows by canonical page URL — a stable
                // identifier that survives the result set shrinking
                // when a row is hidden. Indexing by `\.offset` would
                // re-number the remaining rows and SwiftUI could
                // mis-diff which row left the list.
                ForEach(Array(results.enumerated()), id: \.element.pageURL) { index, result in
                    let isFirst = index == 0
                    // Last result row is also the visual last row of
                    // the card UNLESS the "Hidden landmarks (N)"
                    // footer button is present below it.
                    let isLastVisible = index == results.count - 1 && hiddenLandmarks.isEmpty && !showLoadMore
                    Button {
                        open(result)
                    } label: {
                        NearbyRow(result: result, userLocation: userLocation)
                    }
                    .buttonStyle(.plain)
                    // Parchment per-row, with rounded outer corners
                    // only on the first and last rows of the visual
                    // card. Replaces the prior list-level background
                    // + clipShape + maxHeight cap — the per-row
                    // approach lets the parchment end exactly with
                    // the last row regardless of how short the list
                    // is, fixing the "extra parchment below the last
                    // row" Sean saw on a sparse History/Nearby list.
                    .listRowBackground(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(
                                topLeading: isFirst ? 12 : 0,
                                bottomLeading: isLastVisible ? 12 : 0,
                                bottomTrailing: isLastVisible ? 12 : 0,
                                topTrailing: isFirst ? 12 : 0
                            )
                        )
                        .fill(Color("CardBackground"))
                    )
                    // 6pt vertical insets to match the Scan recents
                    // card so the same landmark looks the same size
                    // in both places.
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            hide(result)
                        } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                        .tint(.orange)
                    }
                    // Measure the first row (content + the 12pt vertical insets)
                    // so the radius nudge can advance exactly half a row at the
                    // current dynamic-type size.
                    .background {
                        if isFirst {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { measuredRowHeight = proxy.size.height + 12 }
                                    .onChange(of: proxy.size.height) { _, h in
                                        measuredRowHeight = h + 12
                                    }
                            }
                        }
                    }
                }

                if !hiddenLandmarks.isEmpty {
                    Button {
                        showHiddenSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "eye.slash")
                            Text("Hidden landmarks (\(hiddenLandmarks.count))")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        // Compact .caption sizing keeps this footer
                        // visually subordinate to the section header
                        // ("Within 5 miles…") above the list — that
                        // header is now subheadline+semibold to match
                        // Scan's "Recent finds".
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                    // The footer button is the visual last row of
                    // the card whenever it's present, so it carries
                    // the rounded bottom corners.
                    .listRowBackground(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(
                                topLeading: 0,
                                bottomLeading: showLoadMore ? 0 : 12,
                                bottomTrailing: showLoadMore ? 0 : 12,
                                topTrailing: 0
                            )
                        )
                        .fill(Color("CardBackground"))
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }

                if showLoadMore {
                    // A full-width brand-brown action button matching the
                    // "Snap a landmark sign" treatment (borderedProminent,
                    // .infinity width, minHeight 28, regular weight, 12pt
                    // corners) — prominent, white text + icon, with the
                    // current count. Reads as "tap to fetch more", distinct
                    // from the small Hidden landmarks navigation row.
                    Button {
                        loadMore()
                    } label: {
                        Group {
                            if isLoadingMore {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("Loading…")
                                }
                            } else {
                                Label("Load more (\(results.count) shown)", systemImage: "arrow.down.circle")
                            }
                        }
                        .fontWeight(.regular)
                        // Force both text and icon white (don't rely on the
                        // button style tinting the SF Symbol).
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        // Swap "Load more" ↔ "Loading…" instantly instead of
                        // cross-fading, which briefly overlaps the two
                        // centered labels.
                        .animation(nil, value: isLoadingMore)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandBrown"))
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(isLoadingMore)
                    // Visual last row of the card, so the parchment behind
                    // it carries the rounded bottom corners.
                    .listRowBackground(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(
                                topLeading: 0,
                                bottomLeading: 12,
                                bottomTrailing: 12,
                                topTrailing: 0
                            )
                        )
                        .fill(Color("CardBackground"))
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            }
            // Plain style instead of the default inset-grouped, so
            // the rows extend full-width within the padded list
            // frame. Inset-grouped adds its own per-row inset on top
            // of any outer .padding(.horizontal), squeezing the rows.
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            // No list-level background — per-row backgrounds carry
            // the parchment so it ends exactly at the last visible
            // row.
            .scrollContentBackground(.hidden)
            // Resolve the List's backing UIScrollView so a radius increase can
            // nudge the content by an exact half-row offset (see changeRadius).
            .background(
                ListScrollViewFinder { scrollView in
                    if listScrollView !== scrollView { listScrollView = scrollView }
                }
            )
            // Round the viewport edges so the top corners stay
            // rounded as the first row scrolls out of view. Without
            // this clip, the per-row rounded corners leave the
            // screen with row 1 and the visible top becomes square
            // mid-scroll.
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Match the picker/search field's horizontal margin so
            // the list lines up with the chrome above it.
            .padding(.horizontal)
            .refreshable {
                await startRefresh(force: true).value
            }
        }
        // Match the map case's bottom padding so the parchment list
        // card sits the same distance above the tab bar as the map.
        .padding(.bottom, 16)
    }

    /// Persist a HiddenLandmark for this result so future Nearby fetches
    /// filter it out. Keyed on the canonical page URL — same identifier
    /// the discover pipeline uses for dedup. Snapshots the summary +
    /// article-image fields so the Hidden Landmarks sheet can show a
    /// thumbnail/preview card without re-fetching.
    private func hide(_ result: LandmarkResult) {
        let key = result.pageURL.absoluteString
        let descriptor = FetchDescriptor<HiddenLandmark>(
            predicate: #Predicate { $0.pageURLString == key }
        )
        if let _ = try? modelContext.fetch(descriptor).first { return }
        let hidden = HiddenLandmark(
            pageURLString: key,
            title: result.title,
            summary: result.summary,
            articleImageURLString: result.articleImageURL?.absoluteString,
            articleImageData: result.articleImageData
        )
        modelContext.insert(hidden)
        // Insertion is normally auto-saved on the next runloop, but
        // explicit save makes the insert visible to other @Query
        // observers immediately and surfaces any persistence error.
        try? modelContext.save()
    }

    // MARK: - Load

    private func refresh(force: Bool, recenter: Bool = true, reuseLocation: Bool = false) async {
        // Preserve existing results while reloading so pull-to-refresh
        // and the toolbar button don't wipe the list. Only flip to the
        // full-screen loading view when we have nothing to show yet.
        // Cached pins from a previous session count as "results" for
        // this purpose — keep them visible while the fresh stream
        // populates.
        // Only flip to the full-screen spinner when there's genuinely
        // nothing on screen. If a map is already showing (loaded pins or
        // the empty-area map), keep it visible during the refetch — when
        // the radius control widens an empty search, the user should watch
        // the map fill in, not lose it to a spinner.
        if !hasResults && !isShowingMap {
            loadingPhase = .locating
            state = .loading
        }
        reloadingCount += 1
        defer { reloadingCount -= 1 }

        // A radius change doesn't move the user, so reuse the known fix
        // (skips a fresh GPS round-trip that can stall up to the 12 s
        // timeout if the cached fix went stale). Cold start and
        // pull-to-refresh still fetch a fresh fix.
        let loc: CLLocation
        if reuseLocation, let known = userLocation {
            loc = known
        } else {
            let granted = await locationManager.ensurePermission()
            guard granted else {
                state = .locationDenied
                return
            }
            // `bypassCache: force` makes an explicit refresh always re-issue
            // `requestLocation()` — without this, a stale fix from before a
            // Location-Services toggle survived for the cache's 5-min TTL and
            // refresh was a no-op against the GPS.
            guard let fetched = await locationManager.currentLocation(
                withTimeout: LocationManager.nearbyTimeout,
                bypassCache: force
            ) else {
                if !hasResults { state = .locationUnavailable }
                return
            }
            loc = fetched
        }

        // `LocationManager.currentLocation` deduplicates concurrent
        // callers via `inflightFetch` — multiple `refresh` Tasks
        // waiting for the same GPS fix all resume in the same
        // microsecond when the fix arrives. If `startRefresh`
        // cancelled an older Task, that Task is still running here
        // (cancellation is cooperative; `currentLocation` has no
        // `Task.isCancelled` check). Without this gate, both the
        // cancelled and active Task fall through to
        // `discoverLandmarksAt` simultaneously and we issue two
        // identical concurrent SPARQL queries.
        if Task.isCancelled { return }

        userLocation = loc

        // Spatial cache invalidation: if the rendered pins are from a
        // previous session and the fresh GPS fix is more than one
        // search-radius from the cached center, the user has moved
        // cities — drop the stale pins so they don't keep staring at
        // last-session's landmarks while the new fetch runs. Done
        // BEFORE the `lastFetchCenter = nil` reset below so we still
        // know the cached center.
        if hasResults, let cachedCenter = lastFetchCenter {
            let cachedLoc = CLLocation(
                latitude: cachedCenter.latitude,
                longitude: cachedCenter.longitude
            )
            if loc.distance(from: cachedLoc) > Double(currentRadiusMeters) {
                state = .loading
                NearbyResultsCache.clear()
            }
        }

        // Manual refresh discards any panned-around pins and recenters
        // on the user. Otherwise the "Nearby" list could drift to a
        // totally different part of the world without the user
        // realizing.
        lastFetchCenter = nil

        // Consume the streaming discover pipeline. First yield is the
        // closest-30 batch (gated); second yield is the full set
        // (also gated). Cancellation propagates: if a second refresh
        // is started, the for-await unwinds and `discoverLandmarksAt`
        // tears down its inner SPARQL/hydration task via
        // `continuation.onTermination`.
        //
        // Progressive rendering is only useful when there's nothing
        // to show yet. On a manual refresh that already has results
        // (cache pins or a previous fetch), letting the closest-30
        // yield commit mid-stream causes the list to shrink from
        // ~100 → 30 → 100 — visible as the top-row "jump" Sean saw
        // mid pull-to-refresh. Snapshot at start of stream consumption
        // so the gate doesn't flip if the spatial-invalidation branch
        // above transitioned us into `.loading`.
        let progressiveRender = !hasResults

        // We have a fix — the spinner now reflects the search phase
        // rather than the locating phase. No-op visually unless the
        // loading view is on screen (cold start / moved-cities reload).
        loadingPhase = .searching

        let stream = discoverLandmarksAt(
            center: loc.coordinate,
            radiusMeters: currentRadiusMeters,
            limit: Self.fetchLimit
        )
        var finalResults: [LandmarkResult] = []
        var sparqlFailed = false
        var streamHasMore = false
        for await yield in stream {
            if Task.isCancelled { return }
            switch yield {
            case .batch(let results, let more):
                // Cold-start path: render each non-empty yield as
                // soon as it's ready so the user sees pins fast.
                // Manual-refresh path: skip intermediate yields and
                // swap atomically once the stream finishes. The
                // `.empty` decision in either case is made after the
                // stream completes — an empty intermediate yield
                // (rare, e.g. fast batch fully gated) shouldn't flash
                // "No landmarks nearby".
                if progressiveRender, !results.isEmpty {
                    state = .loaded(results)
                }
                finalResults = results
                streamHasMore = more
            case .sparqlFailed:
                sparqlFailed = true
            }
        }
        if Task.isCancelled { return }

        if sparqlFailed && finalResults.isEmpty {
            // SPARQL transport failed (timeout, retry exhaustion,
            // cancel). Don't claim the area is empty when we never
            // heard back from the service. Leave `lastFetchCenter`
            // alone — a future pan should still trigger a fetch from
            // this center. Leave existing pins alone if we already
            // have some (a refresh that failed shouldn't blow away
            // the last successful results); only switch to the
            // explicit failure state when there are no pins to keep.
            if !hasResults { state = .serviceUnavailable }
            return
        }

        if finalResults.isEmpty {
            // SPARQL succeeded with zero hits — area is genuinely
            // empty within the search radius.
            lastFetchCenter = loc.coordinate
            state = .empty
            hasMore = false
        } else {
            // Always commit the final set. In the progressive path
            // this is usually a no-op (loop already set the same
            // state); in the non-progressive path it's the actual
            // atomic swap from the previous results to the fresh
            // fetch.
            lastFetchCenter = loc.coordinate
            state = .loaded(finalResults)
            // Fresh primary fetch = page 1; arm "load more" if the page
            // came back full (radius holds more than one page).
            pagesLoaded = 1
            hasMore = streamHasMore
        }

        // Tell the map to snap its camera back to the user (refit to
        // pins). If we don't, the refresh button is silent on the map —
        // the underlying data resets but the view stays wherever the
        // user had panned to, which is exactly the "doesn't bring me
        // home" bug. Skipped on a radius change (recenter == false): the
        // map already zoomed itself to the new radius the instant the
        // button was tapped, and a refit here would clobber that.
        if recenter {
            // Fit the current pins (clear any leftover decrease target).
            recenterRegion = nil
            recenterSignal += 1
        }

        // Persist for the next cold-start so the user sees pins
        // instantly next time. Saved as a Coordinate so the cache is
        // self-describing without depending on CoreLocation types.
        await NearbyResultsCache.save(CachedNearbyFetch(
            schemaVersion: NearbyResultsCache.currentSchema,
            fetchCenter: Coordinate(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude
            ),
            radiusMeters: currentRadiusMeters,
            fetchedAt: Date(),
            results: finalResults
        ))
    }

    /// Pan-triggered fetch. Fires when the user has panned the map
    /// far enough from the last fetch center that we're looking at
    /// landmarks the existing 5 miles of geosearch doesn't cover.
    /// Fetches 5 miles around the new center and merges the results
    /// into the existing list (dedup by canonical page URL) so the
    /// map accumulates pins as the user explores.
    ///
    /// The list re-sorts by distance from the user's GPS, so panned
    /// results land below whatever's in the user's immediate
    /// neighborhood — consistent with the "Within 5 miles of your
    /// location" header framing.
    private func fetchAroundMapCenter(_ center: CLLocationCoordinate2D) async {
        // Pan-search is conceptually an augmentation of an
        // established result set, never the initial fetch. While a
        // primary `refresh` is in flight, drop pan triggers — the
        // map's `.onMapCameraChange` fires during the cold-start
        // window too (programmatic camera changes from `.onAppear`
        // and `recenterSignal` trigger it), and racing two SPARQL
        // queries against `query.wikidata.org` for identical coords
        // doubles Wikidata load.
        guard !isReloading else { return }
        // No anchor center means either the initial fetch hasn't
        // completed yet or it's mid-refresh (`refresh` nils
        // `lastFetchCenter` to discard panned pins before
        // re-fetching). In both windows the GPS-centered `refresh`
        // is the right path; firing a pan-fetch here would race it.
        guard let last = lastFetchCenter else { return }
        // Pan threshold: if the new center is still within the
        // current 5-mile fetch's area, we already have its landmarks.
        let dist = CLLocation(latitude: last.latitude, longitude: last.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        guard dist > Double(currentRadiusMeters) / 2 else { return }

        // Surface the map's "Loading…" pill while the pan-search runs —
        // it's otherwise a silent background merge.
        panFetchCount += 1
        defer { panFetchCount -= 1 }

        // Pan-search consumes the same streaming API as the cold-start
        // refresh, but only commits the final (full) yield. Pan never
        // blocks the UI (the user keeps panning while the fetch runs),
        // so showing a half-hydrated pin set mid-pan would be UX churn
        // for no benefit.
        let stream = discoverLandmarksAt(
            center: center,
            radiusMeters: currentRadiusMeters,
            limit: Self.fetchLimit
        )
        var fresh: [LandmarkResult] = []
        var sparqlFailed = false
        for await yield in stream {
            if Task.isCancelled { return }
            switch yield {
            case .batch(let results, _):
                fresh = results
            case .sparqlFailed:
                sparqlFailed = true
            }
        }
        if Task.isCancelled { return }

        // Pan failure path: don't update `lastFetchCenter` (so the
        // next pan past the threshold tries again) and don't surface
        // UI — pan augments existing results, not the primary fetch.
        if sparqlFailed && fresh.isEmpty { return }

        lastFetchCenter = center
        guard !fresh.isEmpty else { return }

        // Merge into existing results (dedup by canonical URL, re-sorted by
        // distance from the USER so the list stays anchored where the user
        // actually is, capped). See `mergeResults`.
        guard case .loaded(let existing) = state else {
            state = .loaded(fresh)
            return
        }
        state = .loaded(mergeResults(fresh, into: existing, user: userLocation, cap: Self.maxNearbyResults).merged)
    }

    /// Widen the search around `center` (the panned map center) at the current
    /// radius and merge the new pins in, then zoom the camera out around
    /// `center` to reveal the wider area. Used by `changeRadius` for a zoom-out
    /// (more miles) while the map is panned away from the user, so the wider
    /// radius pulls in pins around what's on screen instead of snapping home.
    /// Unlike `fetchAroundMapCenter` there's no pan-distance threshold (the
    /// radius changed, not the center). The merge mirrors that function's
    /// (dedup + user-anchored sort) — a small, deliberate duplication kept
    /// local to avoid touching the tested pan path.
    private func fetchAroundCenterForRadiusChange(_ center: CLLocationCoordinate2D) {
        // Zoom out around the panned center to the new radius right away (keep
        // the current pins visible while the fetch fills in), so the camera
        // reveals the wider area without snapping to the user's GPS.
        recenterRegion = MKCoordinateRegion(
            center: center,
            latitudinalMeters: Double(currentRadiusMeters) * 2,
            longitudinalMeters: Double(currentRadiusMeters) * 2
        )
        recenterSignal += 1

        let targetIndex = radiusIndex
        let radiusMeters = currentRadiusMeters
        refreshTask?.cancel()
        panTask?.cancel()
        panTask = Task {
            // Surface the map's "Loading..." pill while the widen runs.
            panFetchCount += 1
            defer { panFetchCount -= 1 }
            let stream = discoverLandmarksAt(
                center: center,
                radiusMeters: radiusMeters,
                limit: Self.fetchLimit
            )
            var fresh: [LandmarkResult] = []
            var sparqlFailed = false
            for await yield in stream {
                if Task.isCancelled { return }
                switch yield {
                case .batch(let results, _):
                    fresh = results
                case .sparqlFailed:
                    sparqlFailed = true
                }
            }
            if Task.isCancelled { return }
            // A newer radius change supersedes this one.
            guard radiusIndex == targetIndex else { return }
            recenterRegion = nil
            if sparqlFailed && fresh.isEmpty { return }
            lastFetchCenter = center
            guard !fresh.isEmpty else { return }
            // Merge into the existing pins (dedup + user-anchored sort,
            // capped), mirroring fetchAroundMapCenter. See `mergeResults`.
            guard case .loaded(let existing) = state else {
                state = .loaded(fresh)
                return
            }
            state = .loaded(mergeResults(fresh, into: existing, user: userLocation, cap: Self.maxNearbyResults).merged)
        }
    }

    /// Merge `fresh` into `existing`, de-duplicated by canonical page URL
    /// and (when `user` is known) re-sorted nearest-first so the list stays
    /// anchored to the user's location. When `cap` is set, keeps only the
    /// nearest `cap` results so continuous panning / load-more can't grow
    /// the set without bound. Returns the merged list and the count of
    /// genuinely new rows (before any cap) so "load more" can tell whether a
    /// page actually contributed anything.
    private func mergeResults(
        _ fresh: [LandmarkResult],
        into existing: [LandmarkResult],
        user: CLLocation?,
        cap: Int? = nil
    ) -> (merged: [LandmarkResult], added: Int) {
        var merged = existing
        let seen = Set(existing.map(\.pageURL))
        let before = merged.count
        for result in fresh where !seen.contains(result.pageURL) {
            merged.append(result)
        }
        let added = merged.count - before
        if let user {
            merged.sort { a, b in
                let da = a.coordinates.map {
                    user.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                } ?? .infinity
                let db = b.coordinates.map {
                    user.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                } ?? .infinity
                return da < db
            }
        }
        if let cap, merged.count > cap {
            merged = Array(merged.prefix(cap))
        }
        return (merged, added)
    }

    // MARK: - Load more

    /// Fetch the next SPARQL page at the current center + radius and append
    /// it to the list (dedup by canonical URL, re-sorted by distance from
    /// the user — same merge as pan-search). Driven by the "Load more" list
    /// footer, shown only while `hasMore`.
    private func loadMore() {
        guard !isLoadingMore, hasMore, let user = userLocation else { return }
        isLoadingMore = true
        loadMoreTask = Task {
            defer { isLoadingMore = false }
            let stream = discoverLandmarksAt(
                center: user.coordinate,
                radiusMeters: currentRadiusMeters,
                limit: Self.fetchLimit,
                offset: pagesLoaded * sparqlResultLimit
            )
            var fresh: [LandmarkResult] = []
            var more = false
            var failed = false
            for await yield in stream {
                if Task.isCancelled { return }
                switch yield {
                case .batch(let results, let m):
                    fresh = results
                    more = m
                case .sparqlFailed:
                    failed = true
                }
            }
            if Task.isCancelled { return }
            // On failure, leave hasMore/pagesLoaded alone so the footer
            // stays and the user can retry.
            guard !failed else { return }
            // Merge into the current set (dedup + user-anchored sort, capped).
            guard case .loaded(let current) = state else { return }
            let (merged, added) = mergeResults(fresh, into: current, user: user, cap: Self.maxNearbyResults)
            state = .loaded(merged)
            pagesLoaded += 1
            // `more` only reflects that the raw SPARQL page came back full.
            // After the operating-institution gate + URL dedup, a full page
            // can still contribute zero new rows (dense area, mostly gated or
            // already-shown landmarks). Retire the footer if this page added
            // nothing, or once we've hit the result cap, so the user can't tap
            // "Load more" on a list that won't grow.
            hasMore = more && added > 0 && merged.count < Self.maxNearbyResults
        }
    }

    // MARK: - Tap-to-open

    /// Upsert an unenriched placeholder immediately so the detail view
    /// has something to render, then enrich in the background. Mirrors
    /// the scan flow in ContentView.
    private func open(_ result: LandmarkResult) {
        // Upsert an unenriched placeholder so the detail view has
        // something to render immediately, then enrich in the
        // background. `LandmarkLookup.upsert` preserves any enrichment
        // an earlier pass already saved, so the placeholder write never
        // clears type/year on a re-tap.
        pushedLookup = LandmarkLookup.upsert(result: result, in: modelContext)
        Task {
            let enriched = await enrichDiscoveredLandmark(result, query: result.title)
            LandmarkLookup.upsert(result: enriched, in: modelContext)
        }
    }
}

// MARK: - Loading

/// Cold-start loading view for Nearby. Shows the current phase
/// ("Getting your location…" → "Finding landmarks near you…") and,
/// after a grace period, a reassurance line. A fresh install has no
/// cached pins to mask the cold-start chain (a cold GPS first-fix plus
/// a slow Wikidata pass can stack toward ~30 s before any cache
/// exists), and a static spinner that long reads as "broken" — which
/// is exactly what a first-run user reported. The grace timer lives
/// here so it resets each time the loading view appears, and survives
/// the locating→searching change (that only updates `message`, not
/// view identity, so `.task` isn't restarted).
private struct NearbyLoadingView: View {
    let message: String
    @State private var showSlowHint = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if showSlowHint {
                Text("Still working — this can take a moment.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.25), value: message)
        .animation(.easeInOut(duration: 0.25), value: showSlowHint)
        .task {
            // ~12 s: long enough that the common (now interim-fix-seeded)
            // path never shows it, short enough to reassure before the
            // user concludes it's frozen and leaves the tab.
            try? await Task.sleep(for: .seconds(12))
            showSlowHint = true
        }
    }
}

// MARK: - Row

private struct NearbyRow: View {
    let result: LandmarkResult
    let userLocation: CLLocation?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(result.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let coord = result.coordinates {
                        let d = distanceMeters(from: userLocation, to: coord)
                        // Manual HStack instead of Label so the
                        // location-arrow / number gap is tighter than
                        // the default Label spacing.
                        HStack(spacing: 3) {
                            Image(systemName: "location")
                            Text(formatLandmarkDistance(d))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if let type = result.wikidataType {
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        // Nearby list results carry only a remote URL (bytes aren't
        // downloaded until tap-time enrichment), so this resolves through
        // AsyncImage; passing the (usually nil) data keeps it correct if
        // that ever changes. See `LandmarkThumbnail`.
        LandmarkThumbnail(
            articleImageData: result.articleImageData,
            articleImageURL: result.articleImageURL
        )
    }

    private func distanceMeters(from user: CLLocation?, to coord: Coordinate) -> CLLocationDistance {
        guard let user else { return 0 }
        let other = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return user.distance(from: other)
    }
}

// MARK: - Map mode

/// Map alternative for the Nearby tab. Drops a brown signpost pin per
/// nearby result, plus the user-location dot, with selection-driven
/// callout card mirroring the History map.
private struct NearbyMapView: View {
    let results: [LandmarkResult]
    let userLocation: CLLocation?
    /// Parent-driven "snap back to user" counter. When this changes,
    /// the map re-fits its camera on the user's location. Used by
    /// the toolbar refresh button to bring the user home after they
    /// panned away.
    let recenterSignal: Int
    let onSelect: (LandmarkResult) -> Void
    /// Called at the end of every camera gesture with the new map
    /// center. Parent decides (via `panRefetchThresholdMeters`)
    /// whether the pan was significant enough to warrant a new
    /// geosearch at this location.
    let onMapCenterChanged: (CLLocationCoordinate2D) -> Void
    /// Radius-control wiring from the parent (same actions as the list header
    /// stepper), surfaced here as an Apple/Google-style zoom control. The map
    /// inverts them to zoom convention at the call site below, so its +/- read
    /// opposite to the list stepper by design. The current radius (miles)
    /// shows between the buttons as the scale cue, since the map has no
    /// "Within N miles" header like the list does.
    let radiusMiles: Int
    let canIncreaseRadius: Bool
    let canDecreaseRadius: Bool
    let onIncreaseRadius: () -> Void
    let onDecreaseRadius: () -> Void
    /// True while a fetch is in flight — shows a "Loading…" pill at the
    /// bottom of the map (the map keeps its current pins meanwhile).
    let isLoading: Bool
    /// Optional explicit recenter target. A radius-decrease sets this to the
    /// new (smaller) radius so the camera zooms IN before the pins are
    /// trimmed; nil means "fit the current pins" (the normal recenter).
    let recenterRegion: MKCoordinateRegion?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedID: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition, selection: $selectedID) {
                UserAnnotation()
                ForEach(results, id: \.pageURL) { result in
                    if let coord = result.coordinates {
                        Marker(
                            result.title,
                            systemImage: "signpost.right.fill",
                            coordinate: CLLocationCoordinate2D(
                                latitude: coord.latitude,
                                longitude: coord.longitude
                            )
                        )
                        .tint(Color("BrandBrown"))
                        .tag(result.pageURL.absoluteString)
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onAppear {
                cameraPosition = .region(initialRegion())
            }
            .onChange(of: recenterSignal) { _, _ in
                // Recenter: use a parent-supplied region when present (a
                // radius-decrease zooms to the new radius BEFORE its pins
                // are trimmed); otherwise fit the current pins.
                withAnimation { cameraPosition = .region(recenterRegion ?? initialRegion()) }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // Report the new map center to the parent at the end
                // of every gesture. The parent compares against its
                // last-fetched center and decides whether the pan was
                // significant enough to warrant another geosearch.
                // `.onEnd` only fires after the user stops
                // interacting, so we don't spam refetches mid-gesture.
                onMapCenterChanged(context.region.center)
            }
            // Apple/Google-style zoom control, bottom-trailing (where map
            // apps usually put it). Follows zoom convention ("+" = zoom in =
            // fewer miles), the inverse of the list stepper; see the call
            // site for the wiring. Shows the current radius between the
            // buttons. Hidden while a pin's card is up so it doesn't sit
            // underneath it.
            .overlay(alignment: .bottomTrailing) {
                if selectedID == nil {
                    MapZoomControl(
                        miles: radiusMiles,
                        // zoom in = fewer miles = parent's "decrease"
                        // (and vice versa); inverted so the list keeps +=more
                        canZoomIn: canDecreaseRadius,
                        canZoomOut: canIncreaseRadius,
                        onZoomIn: onDecreaseRadius,
                        onZoomOut: onIncreaseRadius
                    )
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }

            // "Loading…" pill, bottom-centre, while a fetch is in flight
            // (e.g. widening the radius). Hidden when a pin's card is up.
            if isLoading, selectedID == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading…")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.regularMaterial))
                .padding(.bottom, 12)
                .transition(.opacity)
            }

            if let id = selectedID,
               let selected = results.first(where: { $0.pageURL.absoluteString == id }) {
                SelectedNearbyCard(
                    result: selected,
                    onView: { onSelect(selected) },
                    onDismiss: { selectedID = nil }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedID)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .toolbarBackground(.visible, for: .tabBar)
    }

    /// Fit the bounding box of the user-location dot plus every pin with
    /// 40% padding. Tighter than a fixed-span center-on-user in dense
    /// areas (pins cluster); opens up naturally when results are spread
    /// out to the 5-mile search radius.
    private func initialRegion() -> MKCoordinateRegion {
        var points: [CLLocationCoordinate2D] = []
        if let user = userLocation {
            points.append(user.coordinate)
        }
        for r in results {
            if let c = r.coordinates {
                points.append(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
            }
        }
        guard !points.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 50)
            )
        }
        if points.count == 1 {
            return MKCoordinateRegion(
                center: points[0],
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            )
        }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.02, (lats.max()! - lats.min()!) * 1.2),
            longitudeDelta: max(0.02, (lons.max()! - lons.min()!) * 1.2)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Radius controls

/// Apple/Google-style map zoom control: a vertical +/- pair on a
/// material background, overlaid on the Nearby map. Follows true map
/// zoom convention: "+" (top) zooms IN, tightening the search radius
/// (fewer miles); "−" zooms OUT, widening it. Both disable at the ends
/// of the ladder. This is intentionally the inverse of the list header's
/// RadiusStepper (where "+" reads as "more miles"): on a map, "+" = zoom
/// in is the expected gesture. The "N mi" between the buttons is the
/// scale cue, since the map has no "Within N miles" header.
private struct MapZoomControl: View {
    let miles: Int
    let canZoomIn: Bool
    let canZoomOut: Bool
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            button("plus", action: onZoomIn, enabled: canZoomIn)
            Divider().frame(width: 44)
            // Current search radius — the scale cue, since the map has no
            // "Within N miles" header like the list.
            Text("\(miles) mi")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 28)
            Divider().frame(width: 44)
            button("minus", action: onZoomOut, enabled: canZoomOut)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .accessibilityElement(children: .contain)
    }

    private func button(_ systemName: String, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .accessibilityLabel(systemName == "plus" ? "Zoom in, tighter radius" : "Zoom out, wider radius")
    }
}

/// Compact radius stepper for the Nearby list header: a joined −/+
/// capsule that steps the search radius (mirrors the map's zoom
/// control). "−" tightens, "+" widens; both disable at the ladder ends.
private struct RadiusStepper: View {
    let canIncrease: Bool
    let canDecrease: Bool
    let onIncrease: () -> Void
    let onDecrease: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", action: onDecrease, enabled: canDecrease)
            Divider().frame(height: 16)
            button("plus", action: onIncrease, enabled: canIncrease)
        }
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
    }

    private func button(_ systemName: String, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote.weight(.semibold))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(systemName == "plus" ? "Widen search radius" : "Tighten search radius")
    }
}

/// Compact summary card shown over the Nearby map when a pin is
/// selected. The whole card body is a single tap target that calls
/// `onView` (the enrich + push flow shared with the list rows). The X
/// is a sibling button so dismissing the card doesn't also trigger
/// navigation.
private struct SelectedNearbyCard: View {
    let result: LandmarkResult
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onView) {
                cardContent
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full landmark details")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        )
    }

    /// Card content that's the tappable area. "View details" is a
    /// real Button (nested inside the outer Button) so it gets press
    /// feedback as its own tap target. SwiftUI routes taps inside the
    /// inner button to it; taps elsewhere in the card fire the outer
    /// button — both call `onView`, so the destination is the same
    /// either way.
    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(action: onView) {
                    Label("View details", systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandBrown"))
                .controlSize(.small)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        LandmarkThumbnail(
            articleImageData: result.articleImageData,
            articleImageURL: result.articleImageURL
        )
    }
}
