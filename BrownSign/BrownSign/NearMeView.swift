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
import StoreKit

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

    /// Fallback row height (points) for the radius scroll-nudge before the
    /// first row has been measured; a real measured value replaces it as soon
    /// as a row appears.
    private static let estimatedRowHeight: CGFloat = 88
    /// Vertical chrome added to a measured row's content height: the 8pt top +
    /// 8pt bottom `listRowInsets` applied to every Nearby row (8 + 8 = 16).
    private static let rowVerticalInset: CGFloat = 16

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
    /// The map's current visible center, updated on every USER pan the map
    /// reports (programmatic camera moves — the auto-fit on appear and the
    /// recenter signal — are filtered out in NearbyMapView, so they can't
    /// masquerade as a pan). nil until the map first reports a center.
    @State private var mapCenter: CLLocationCoordinate2D?
    /// The panned map center the LIST is anchored to, or nil when anchored to
    /// the user's GPS. Explicit @State, NOT derived per-render: it is set or
    /// cleared ONLY when the user pans the map (`updateAreaAnchor`, threshold
    /// measured at the radius in effect at pan time), and cleared by
    /// `returnToUserLocation` and a primary `refresh`. Deriving it from
    /// `mapCenter` + the CURRENT radius made radius steps flip the anchor as
    /// a side effect (widen → threshold grows → silently snapped the list
    /// back to "your location") and let a refresh strand the list on a stale
    /// area. Radius changes deliberately never move this.
    @State private var areaAnchor: CLLocationCoordinate2D?
    /// Center of the most recent USER-GPS-centered primary fetch (never a
    /// panned center, unlike `lastFetchCenter`). Drives the moved-cities
    /// spatial cache invalidation in `refresh`: comparing the fresh GPS fix
    /// against a PANNED `lastFetchCenter` made tab re-entry while panned wipe
    /// the pins to a spinner and clear the disk cache. Seeded from the disk
    /// cache on cold-start (the cache's `fetchCenter` is always the user's
    /// GPS — see `saveCurrentResultsToCache`).
    @State private var lastUserFetchCenter: CLLocationCoordinate2D?
    /// `radiusIndex` at the time of the last user-GPS-centered fetch. Lets
    /// `returnToUserLocation` detect that the radius changed while the list
    /// was following a panned area (that fetch ran around the AREA, so the
    /// loaded set doesn't cover the user at the new radius) and fill the gap.
    @State private var lastUserFetchRadiusIndex: Int?
    /// Deferred radius-narrow pin trim (the 0.9 s wait for the zoom-in camera
    /// animation to settle). Tracked so `returnToUserLocation` and a primary
    /// refresh can cancel it — an anonymous task could land its area-anchored
    /// `filtered` subset AFTER the user re-anchored to their location and
    /// empty the list out from under them.
    @State private var trimTask: Task<Void, Never>?
    /// Page URLs already run through `enrichDiscoveredLandmark` this session.
    /// Re-tapping a row re-ran the FULL pipeline every time — Wikidata claims,
    /// a multi-MB article-image download, and two on-device LLM calls — for
    /// data the first pass already persisted. Only marked when the pass
    /// actually gained something, so an offline tap still retries later.
    @State private var enrichedThisSession: Set<String> = []
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

    /// Shared review-prompt counter with Scan (see `shouldRequestReview`).
    /// Nearby detail opens count as successful lookups too — only Scan
    /// incremented this before, so a Nearby-first user was never asked.
    @AppStorage("successfulLookupCount") private var successfulLookupCount = 0
    /// Set when a threshold is crossed; the actual request fires when the
    /// detail view is DISMISSED (a natural pause), never over the content
    /// the user just opened.
    @State private var reviewPromptPending = false
    @Environment(\.requestReview) private var requestReview

    // MARK: - Radius

    private var currentRadiusMiles: Int { Self.radiusOptionsMiles[radiusIndex] }
    private var currentRadiusMeters: Int { Self.radiusMeters(forMiles: currentRadiusMiles) }
    private var canIncreaseRadius: Bool { radiusIndex < Self.radiusOptionsMiles.count - 1 }
    private var canDecreaseRadius: Bool { radiusIndex > 0 }

    /// Re-derive `areaAnchor` from a USER pan event: anchored to `center`
    /// once it's more than the pan-search threshold (half the radius in
    /// effect NOW, i.e. at pan time) from the GPS fix, back to nil when the
    /// pan returns within the threshold. Called ONLY from the map's pan
    /// callback — pans are the one thing that moves the anchor, so radius
    /// steps and re-renders can't flip it as a side effect (the hysteresis
    /// the old derived `pannedAwayCenter` lacked).
    private func updateAreaAnchor(for center: CLLocationCoordinate2D) {
        guard let user = userLocation else { return }
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        areaAnchor = centerLoc.distance(from: user) > Double(currentRadiusMeters) / 2 ? center : nil
    }

    /// The point the Nearby LIST is anchored to: the explicit `areaAnchor`
    /// once the user has panned away (so the list "follows" the area shown on
    /// the map), otherwise their GPS location. `isArea` is true in the panned
    /// case — it drives the header copy ("…of this area" vs "…of your
    /// location"), the per-row distance reference, and the radius-scoping in
    /// `listResults`. nil only when there is no location at all; in `.loaded`
    /// (the only state that renders the list) a GPS fix always exists, so
    /// it's non-nil there.
    private var listAnchor: (center: CLLocationCoordinate2D, isArea: Bool)? {
        if let area = areaAnchor { return (area, true) }
        if let user = userLocation { return (user.coordinate, false) }
        return nil
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
        // Non-nil = the user panned the map away from their GPS, so anchor
        // the change to that area instead of snapping home; nil = default
        // GPS-anchored path. `areaAnchor` only moves on pan events, so the
        // radius mutation below can't flip it — a radius change made from
        // the LIST while it's following a panned area stays anchored to that
        // area. `previousIndex` lets a failed area fetch revert the ladder
        // instead of leaving the UI committed to a radius it never loaded.
        let previousIndex = radiusIndex
        let anchor = areaAnchor
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
                // The filtered subset is no longer "page N of a fetch", so reset
                // the page counter too. hasMore=false hides the footer now, and a
                // later widen runs refresh() which sets pagesLoaded=1 — this just
                // keeps the invariant "pagesLoaded describes the current fetch"
                // true in the narrow branch instead of leaving it stale.
                pagesLoaded = 0
                // Cancel any in-flight load-more: it was fetched at the OLD
                // (wider) radius/offset and would otherwise merge out-of-range
                // pins back in and revive the footer after this narrow commits.
                loadMoreTask?.cancel()
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
                    trimTask?.cancel()
                    trimTask = Task {
                        // Wait for the zoom-in camera animation to visually
                        // settle before removing the now-out-of-range pins, so
                        // they leave after the map has finished zooming rather
                        // than mid-animation (which looked odd). The camera
                        // animation runs ~0.8s; 0.9s clears it with a small
                        // margin. Erring long is fine (pins linger a beat);
                        // too short trims mid-zoom.
                        try? await Task.sleep(for: .seconds(0.9))
                        // `try?` swallows the cancellation throw, so check
                        // explicitly — a cancelled trim (returnToUserLocation,
                        // a primary refresh) must not commit its stale,
                        // possibly area-anchored subset over newer state.
                        guard !Task.isCancelled else { return }
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
            // On a failed fetch the radius reverts to `previousIndex` so the
            // header/ladder never claim a radius that never loaded.
            fetchAroundCenterForRadiusChange(anchor, revertOnFailureTo: previousIndex)
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
                // Pre-widen content height, captured now, so we can tell when the
                // new rows have actually laid out (vs racing a fixed delay). nil
                // when the scroll view hasn't been introspected yet (a radius tap
                // in the first runloop after the list appeared).
                let baselineHeight = listScrollView?.contentSize.height
                Task {
                    await task.value
                    // Only nudge when the widen actually added rows — a sparse
                    // area or the result cap adds none, and there's then nothing
                    // to hint at.
                    guard displayMode == .list,
                          case .loaded(let after) = state,
                          after.count > beforeCount else { return }

                    // Poll (up to ~1s) until the backing scroll view is resolved
                    // AND the new rows have laid out (contentSize grew past the
                    // pre-widen height), instead of a fixed 150ms guess that raced
                    // layout. The nudge now fires as soon as the list has actually
                    // grown, and rides out the one-runloop scroll-view
                    // introspection warmup on the first interaction.
                    var resolved: UIScrollView?
                    for tick in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(16))
                        guard displayMode == .list, case .loaded = state else { return }
                        guard let sv = listScrollView else { continue }
                        if let baselineHeight {
                            // Settled once the content is taller than before.
                            if sv.contentSize.height > baselineHeight + 1 { resolved = sv; break }
                        } else if tick >= 2 {
                            // No baseline (scroll view resolved after the tap):
                            // the awaited fetch means layout is long since done,
                            // so a couple of ticks is enough.
                            resolved = sv; break
                        }
                    }
                    guard let scrollView = resolved else { return }

                    // Advance half a row as a "more appeared below" cue, clamped
                    // so it never overscrolls past the content's end. A list that
                    // still fits on screen has nowhere to go and naturally no-ops.
                    let halfRow = (measuredRowHeight > 0 ? measuredRowHeight : Self.estimatedRowHeight) / 2
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

    /// Re-anchor the Nearby list (and the map) back to the user's GPS after
    /// they've been following a panned area. Instant and non-destructive: the
    /// user's local pins are already in the loaded set, so this just drops the
    /// panned anchor and recenters the map — no refetch, and the accumulated
    /// pins stay on the map. (The toolbar refresh button remains the heavier
    /// "discard panned pins + refetch from GPS" action.)
    private func returnToUserLocation() {
        guard let user = userLocation else { return }
        // Cancel any in-flight pan/area fetch — and a pending radius-narrow
        // trim, which holds an area-anchored subset — so neither can land
        // after this re-anchor and drag the list back to the area (or empty
        // it out from under the user).
        panTask?.cancel()
        trimTask?.cancel()
        // Drop the panned anchor: `listAnchor` falls back to GPS, the list
        // re-scopes to the user's radius, and the header returns to "your
        // location". Also reset the pan reference so the next pan measures
        // distance from home, not the area just left.
        areaAnchor = nil
        mapCenter = user.coordinate
        lastFetchCenter = user.coordinate
        // "No refetch" only holds while the loaded set still covers the
        // user's surroundings at the CURRENT radius. If the radius changed
        // while following the area (that fetch ran around the AREA, and a
        // narrow even trims the home pins out of the set), fill the gap with
        // a non-destructive merge fetch around the user — accumulated pins
        // stay, and the camera settles on the user at the current radius.
        // Load-more paging describes the last user-centered fetch either
        // way, so it's stale here: retire it until a primary refresh re-arms
        // it. Otherwise this stays instant: just recenter the camera.
        if lastUserFetchRadiusIndex != radiusIndex || !loadedSetCovers(user.coordinate) {
            hasMore = false
            pagesLoaded = 0
            fetchAroundCenterForRadiusChange(user.coordinate, markUserFetch: true)
        } else {
            // Recenter the map camera on the user too, so switching to the
            // map shows home rather than the area just left.
            recenterRegion = nil
            recenterSignal += 1
        }
    }

    /// True when at least one loaded result lies within the current radius of
    /// `coordinate` — a cheap proxy for "the loaded set covers this point".
    /// Used by `returnToUserLocation` to catch the trimmed-out-home case
    /// (an area-anchored narrow filters the user's own pins away even when
    /// the radius index ends up back where it started). A false positive is
    /// impossible; a false "uncovered" in a genuinely empty home area just
    /// costs one fetch that returns nothing.
    private func loadedSetCovers(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard case .loaded(let results) = state else { return false }
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let maxMeters = Double(currentRadiusMeters)
        return results.contains { r in
            guard let c = r.coordinates else { return false }
            return loc.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) <= maxMeters
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Persistent chrome: the picker + search field show in every
                // state (see displayModePickerVisible), including the
                // cold-start spinner, so the Nearby header never collapses.
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
                        // Keep the radius header above the cold-start spinner
                        // so the chrome is present from the first frame
                        // instead of popping in once the first results land.
                        VStack(spacing: 0) {
                            radiusHeader()
                            loadingView
                        }
                    case .locationDenied:
                        BrandEmptyState(
                            systemImage: "location.slash",
                            title: "Location permission needed",
                            message: "Brown Sign uses your location to find landmarks near you. Turn on location access in Settings."
                        ) {
                            Button {
                                LocationManager.openAppSettings()
                            } label: {
                                Label("Open Settings", systemImage: "gear")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            // Match the Try again recovery button's larger,
                            // better-padded size (see .serviceUnavailable).
                            .controlSize(.large)
                            .tint(Color("AccentButton"))
                            .buttonBorderShape(.roundedRectangle(radius: 12))
                        }
                    case .locationUnavailable:
                        // Plain-language copy (no "GPS signal" jargon, no
                        // missing article) and an actual Try again button —
                        // the old copy SAID "try again" while offering no
                        // affordance to do it, unlike its sibling states.
                        BrandEmptyState(
                            systemImage: "location.slash",
                            title: "Can't find your location",
                            message: "Move somewhere with a clearer view of the sky, then try again."
                        ) {
                            Button {
                                startRefresh(force: true)
                            } label: {
                                Label("Try again", systemImage: "arrow.clockwise")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(Color("AccentButton"))
                            .buttonBorderShape(.roundedRectangle(radius: 12))
                        }
                    case .serviceUnavailable:
                        // SPARQL fetch (Wikidata) failed transiently —
                        // timed out, retries exhausted, or (offline, the
                        // common case) no network at all. Distinct from
                        // `.empty`: we can't know whether the area has
                        // landmarks until the service responds, so surface
                        // it as retryable rather than calling the area empty.
                        //
                        // This state is only reached after a GPS fix, so we
                        // have a location — keep the radius header + stepper
                        // above the error so the nav chrome survives a
                        // dropout. The +/- doubles as a retry at a new radius
                        // alongside the explicit Try again button.
                        VStack(spacing: 0) {
                            radiusHeader()
                            BrandEmptyState(
                                systemImage: "wifi.exclamationmark",
                                title: "Couldn't load landmarks",
                                message: "There was a problem reaching the landmark service. This is usually temporary."
                            ) {
                                Button {
                                    startRefresh(force: true)
                                } label: {
                                    Label("Try again", systemImage: "arrow.clockwise")
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.borderedProminent)
                                // .large gives the recovery button real
                                // height/padding; at the default size the label
                                // was hugged so tightly the 12pt corners read as
                                // an over-rounded pill. 12pt is the app's
                                // standard radius — the size was the problem,
                                // not the corners.
                                .controlSize(.large)
                                .tint(Color("AccentButton"))
                                .buttonBorderShape(.roundedRectangle(radius: 12))
                            }
                        }
                    case .empty:
                        // In list mode, explain the emptiness and
                        // point the user at the map + pan affordance.
                        // In map mode, just show an empty map —
                        // panning will fetch more and things will
                        // populate as the user explores.
                        switch displayMode {
                        case .list:
                            // Keep the radius header (and its +/- stepper)
                            // above the empty state so the search can be
                            // widened right here instead of bouncing to the
                            // map. The header pins to the top; the branded
                            // empty state centres in the space below it.
                            VStack(spacing: 0) {
                                radiusHeader()
                                BrandEmptyState(
                                    systemImage: "signpost.right.and.left",
                                    title: "No landmarks nearby",
                                    message: emptyListDescription()
                                )
                            }
                        case .map:
                            nearbyMap([])
                        }
                    case .loaded(let results):
                        let visible = visibleResults(from: results)
                        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        switch displayMode {
                        case .list:
                            // The list scopes to the area shown on the map: the
                            // panned center once the user has explored away,
                            // else their GPS. The map keeps the full accumulated
                            // pin set; only the list narrows, so its "Within N
                            // miles of …" header stays honest.
                            let anchoredToArea = listAnchor?.isArea ?? false
                            let scoped = listResults(from: visible)
                            if scoped.isEmpty && !trimmedSearch.isEmpty {
                                // Active search narrowed to zero hits → explicit
                                // "No results" instead of a blank list. Map mode
                                // keeps the empty map so the user can pan-search.
                                // The radius header rides above it like every
                                // sibling state (persistent chrome): without it,
                                // an unmatched search made the header + stepper
                                // vanish and snap back per keystroke, and took
                                // away the + that could widen into a match.
                                VStack(spacing: 0) {
                                    radiusHeader(anchoredToArea: anchoredToArea)
                                    BrandEmptyState(
                                        systemImage: "magnifyingglass",
                                        title: "No results",
                                        message: "No nearby landmarks match \"\(trimmedSearch)\"."
                                    )
                                }
                            } else if scoped.isEmpty && anchoredToArea && (isReloading || panFetchCount > 0) {
                                // Following a panned area whose fetch is still in
                                // flight (panned + switched to the list before the
                                // pins landed): show the spinner rather than
                                // briefly claiming the area is empty.
                                VStack(spacing: 0) {
                                    radiusHeader(anchoredToArea: true)
                                    NearbyLoadingView(message: "Finding landmarks in this area…")
                                }
                            } else if scoped.isEmpty {
                                // No landmarks within the radius of where the
                                // list is anchored (e.g. panned to an empty
                                // area). Keep the radius header so the user can
                                // widen, or pan back / explore elsewhere, right
                                // here instead of a blank list.
                                VStack(spacing: 0) {
                                    radiusHeader(anchoredToArea: anchoredToArea)
                                    BrandEmptyState(
                                        systemImage: "signpost.right.and.left",
                                        title: anchoredToArea ? "No landmarks in this area" : "No landmarks nearby",
                                        message: emptyListDescription(anchoredToArea: anchoredToArea)
                                    ) {
                                        // When hides are why the list is empty
                                        // (hide every landmark in a sparse
                                        // radius and the footer that opens this
                                        // sheet disappears with the last row),
                                        // keep the way back to un-hiding
                                        // reachable right here.
                                        if !hiddenLandmarks.isEmpty {
                                            Button {
                                                showHiddenSheet = true
                                            } label: {
                                                Label("Hidden landmarks (\(hiddenLandmarks.count))", systemImage: "eye.slash")
                                                    .fontWeight(.semibold)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.large)
                                            .tint(Color("AccentButton"))
                                            .buttonBorderShape(.roundedRectangle(radius: 12))
                                        }
                                    }
                                }
                            } else {
                                list(scoped, anchoredToArea: anchoredToArea)
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
            .onChange(of: pushedLookup) { _, newValue in
                // Fire a pending review request at the natural pause after
                // the user closes a landmark's details.
                if newValue == nil, reviewPromptPending {
                    reviewPromptPending = false
                    requestReview()
                }
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
                    let center = CLLocationCoordinate2D(
                        latitude: cached.fetchCenter.latitude,
                        longitude: cached.fetchCenter.longitude
                    )
                    lastFetchCenter = center
                    // The cache's fetchCenter is always the user's GPS (see
                    // saveCurrentResultsToCache), so it also seeds the
                    // user-centered reference the moved-cities check runs
                    // against.
                    lastUserFetchCenter = center
                    lastUserFetchRadiusIndex = radiusIndex
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
            trimTask?.cancel()
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
        // A pending narrow-trim holds a pre-refresh (possibly area-anchored)
        // subset; landing it after this refresh commits would clobber the
        // fresh results.
        trimTask?.cancel()
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
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Common case (nothing hidden, no active search): skip the Set
        // build and the filter pass entirely.
        if hiddenLandmarks.isEmpty && q.isEmpty { return results }
        let hiddenURLs = Set(hiddenLandmarks.map(\.pageURLString))
        return results.filter { r in
            if hiddenURLs.contains(r.pageURL.absoluteString) { return false }
            if q.isEmpty { return true }
            // localizedStandardContains is the system-recommended user-search
            // comparison: case-, diacritic-, and width-insensitive, so typing
            // "chateau" matches "Château" (landmark titles carry accents).
            return r.title.localizedStandardContains(q)
        }
    }

    /// The LIST's rows, derived from the (hide + search) filtered `visible`
    /// set: scoped to within the current radius of `listAnchor` and sorted
    /// nearest-first from it, so the list reflects the area shown on the map
    /// (the panned center once explored away, else the user's location). The
    /// map keeps the full accumulated `visible` set — only the list is scoped —
    /// which is what keeps the "Within N miles of …" header honest. Results
    /// without coordinates are kept (they can't be placed, so they shouldn't
    /// silently vanish) and sort last.
    private func listResults(from visible: [LandmarkResult]) -> [LandmarkResult] {
        guard let anchor = listAnchor?.center else { return visible }
        let anchorLoc = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
        let maxMeters = Double(currentRadiusMeters)
        // Decorate-sort-undecorate: compute each result's geodesic distance
        // from the anchor ONCE, then filter and sort on the precomputed
        // value. This runs in the body on every view update (each search
        // keystroke, every spinner tick) over up to `maxNearbyResults` rows,
        // and a closure-based sort recomputed two CLLocation distances per
        // comparison. Coordinate-less results keep their "shown, sorted
        // last" behavior via .infinity.
        let scored: [(result: LandmarkResult, meters: CLLocationDistance)] = visible.map { r in
            guard let c = r.coordinates else { return (r, .infinity) }
            return (r, anchorLoc.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)))
        }
        return scored
            .filter { $0.result.coordinates == nil || $0.meters <= maxMeters }
            .sorted { $0.meters < $1.meters }
            .map(\.result)
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
                // USER pans only — NearbyMapView filters out its own
                // programmatic camera settles (auto-fit on appear, recenter
                // signal), so an auto-fit over cross-region pins can't
                // re-anchor the list to a centroid nobody chose.
                mapCenter = center
                updateAreaAnchor(for: center)
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

    /// True when the empty-state list (with its radius header) is on screen.
    /// Mirrors `isShowingMap`: a background refetch — e.g. tapping + to widen
    /// an empty search — then keeps the header + stepper visible behind the
    /// toolbar spinner instead of flashing the full-screen spinner and hiding
    /// the control the user just tapped.
    private var isShowingEmptyList: Bool {
        if case .empty = state, displayMode == .list { return true }
        return false
    }

    /// True when the service-unavailable view (with its radius header) is on
    /// screen. Like `isShowingEmptyList`, this keeps a retry — Try again, or
    /// tapping +/- to refetch — from flashing the full-screen spinner and
    /// stripping the chrome; the error and its controls stay put behind the
    /// toolbar spinner instead.
    private var isShowingServiceUnavailable: Bool {
        if case .serviceUnavailable = state { return true }
        return false
    }

    /// The list/map picker + search field are persistent chrome, shown in
    /// every state — including the cold-start spinner — so the Nearby header
    /// never collapses or pops in.
    private var displayModePickerVisible: Bool { true }

    /// Whether the radius header (Within N miles + stepper) should appear. It
    /// rides above the list, the empty/offline states, AND the cold-start
    /// spinner — any state where we have a location or are actively getting
    /// one — so the chrome is stable from the first frame. Deliberately NOT
    /// gated on `userLocation != nil`: during the cold-start fix the location
    /// isn't known yet, but we still want the header present. Only the
    /// no-location terminal states (denied/unavailable) omit it.
    private var radiusHeaderVisible: Bool {
        switch state {
        case .locationDenied, .locationUnavailable: return false
        default: return true
        }
    }

    private var loadingView: some View {
        NearbyLoadingView(message: loadingPhase.message)
    }

    /// Section header for the Nearby list: a "Within N miles of your
    /// location" label plus the +/- radius stepper. Rendered above the list
    /// rows, the empty/offline states, AND the cold-start spinner, so the
    /// radius can be widened/tightened from anywhere and the chrome is stable
    /// from the first frame. Visibility comes from `radiusHeaderVisible`, not
    /// `userLocation` — during the cold-start fix the location isn't known
    /// yet, but we still want the header present.
    @ViewBuilder
    private func radiusHeader(anchoredToArea: Bool = false) -> some View {
        if radiusHeaderVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        // "this area" when the list is following a panned map
                        // center; "your location" on the default GPS-anchored
                        // list (and in the loading / empty / offline states).
                        Image(systemName: anchoredToArea ? "mappin.and.ellipse" : "location.fill")
                        // formatRadius converts for metric locales ("3 km")
                        // so the header agrees with the per-row distances,
                        // which were already locale-aware — a metric user
                        // saw "Within 2 miles" over rows showing km.
                        Text(anchoredToArea
                             ? "Within \(formatRadius(miles: currentRadiusMiles)) of this area"
                             : "Within \(formatRadius(miles: currentRadiusMiles)) of your location")
                            // Keep the header on one line now the labeled
                            // radius capsule is wider — it pushed "your
                            // location" onto a second line. Shrink slightly
                            // before ever wrapping/truncating.
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 8)
                    // Trailing radius stepper so the list can widen/tighten
                    // the search without switching to the map. Same step
                    // logic as the map's zoom control.
                    RadiusStepper(
                        miles: currentRadiusMiles,
                        canIncrease: canIncreaseRadius,
                        canDecrease: canDecreaseRadius,
                        onIncrease: { changeRadius(by: 1) },
                        onDecrease: { changeRadius(by: -1) }
                    )
                }
                // When the list is following a panned area, give an explicit
                // way back to the user's location — the header otherwise just
                // reads "this area" with no affordance to return, and the
                // toolbar refresh (the only other way home) also discards the
                // panned pins. This re-anchor is instant and keeps them.
                if anchoredToArea {
                    Button {
                        returnToUserLocation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                            Text("Back to your location")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        // The visual chip is ~23pt tall; outset the hit area
                        // to ~44pt (HIG minimum) without growing the chip.
                        // Nothing interactive sits in the outset band.
                        .contentShape(Rectangle().inset(by: -11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to your location")
                }
            }
            // Match the "Recent finds" section header on Scan
            // (subheadline + semibold) so the section labels read
            // consistently across tabs.
            // Tuned so this "Within N miles" line AND the list below it
            // sit at the same y as History's day-group header ("TODAY")
            // and its first card — Phase-3 grouping moved History's header
            // INTO the List (row top-inset 18 / bottom 6), lower than the
            // old standalone header, so flipping tabs shouldn't make either
            // jump. 16 top moves the label down to match; 6 bottom widens
            // the gap to the list to match History's header→card gap (the
            // 26pt stepper centring the label is why these aren't 18/6).
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
        }
    }

    /// Explainer copy for the empty Nearby list. While the radius can still
    /// widen, point at the + stepper sitting right above this view (no need
    /// to leave for the map); at the widest radius the + is disabled, so
    /// suggest the map + pan instead. `anchoredToArea` swaps the copy for the
    /// "panned to an empty area" case, where the user is already on the map's
    /// area and should pan rather than "switch to the map".
    private func emptyListDescription(anchoredToArea: Bool = false) -> String {
        // The title and the radius header above already convey the emptiness,
        // so this stays a short next-step line, matching History's brevity.
        if anchoredToArea {
            return canIncreaseRadius
                ? "Tap + to widen the search, or pan the map to explore a different area."
                : "Pan the map to a different area to keep exploring."
        }
        if canIncreaseRadius {
            return "Tap + to widen the search, or switch to the map to explore a different area."
        } else {
            return "Switch to the map and pan to a different area to keep exploring."
        }
    }

    @ViewBuilder
    private func list(_ results: [LandmarkResult], anchoredToArea: Bool) -> some View {
        // "Load more" footer shows only when the radius holds more than
        // the current page, we're not filtering (paging a filtered list would
        // be confusing), AND the list isn't following a panned area — the
        // pager fetches the next page around the USER, which would then be
        // scoped out of an area-anchored list, so it'd appear to do nothing.
        let showLoadMore = hasMore
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !anchoredToArea
        // Per-row distances are measured from whatever the list is anchored to
        // (the panned area center when following the map, else the user), so
        // they agree with the "Within N miles of …" header above.
        let rowReference: CLLocation? = listAnchor.map {
            CLLocation(latitude: $0.center.latitude, longitude: $0.center.longitude)
        } ?? userLocation
        // Lat/long context row sits OUTSIDE the List so it doesn't
        // steal the inset-grouped section's rounded top corners from
        // the first landmark row. Inside the List with a clear
        // background, the List still treats it as row 0 and applies
        // top-rounded corners there — making the first visible row
        // look chopped.
        VStack(spacing: 0) {
            radiusHeader(anchoredToArea: anchoredToArea)

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
                        NearbyRow(result: result, referenceLocation: rowReference)
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
                    // 8pt + the rows' internal 4pt = a 12pt visual gap
                    // above the thumbnail, equal to the 12pt leading gap,
                    // so the first row sits symmetrically inside the
                    // card's corner (Sean: left and top must match).
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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
                                    .onAppear { measuredRowHeight = proxy.size.height + Self.rowVerticalInset }
                                    .onChange(of: proxy.size.height) { _, h in
                                        measuredRowHeight = h + Self.rowVerticalInset
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
                        // Same subheadline+semibold treatment as the
                        // "Within N miles…" radius header — Sean tried
                        // the smaller "subordinate" caption sizing and
                        // reversed it: the footer was too small to
                        // read as the control it is.
                        .font(.subheadline)
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
                    // 8pt + the rows' internal 4pt = a 12pt visual gap
                    // above the thumbnail, equal to the 12pt leading gap,
                    // so the first row sits symmetrically inside the
                    // card's corner (Sean: left and top must match).
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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
                        // Keep the "Load more" label always in the layout and
                        // fade it under the spinner instead of swapping the
                        // whole label in and out (the structural if/else swap
                        // flashed on the text change). The label also updates
                        // its count while hidden, so it reappears already
                        // showing the new total rather than animating it.
                        Label("Load more (\(results.count) shown)", systemImage: "arrow.down.circle")
                            .opacity(isLoadingMore ? 0 : 1)
                            .overlay {
                                if isLoadingMore {
                                    HStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text("Loading…")
                                    }
                                }
                            }
                            .fontWeight(.regular)
                            // Force both text and icon white (don't rely on
                            // the button style tinting the SF Symbol).
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            // Swap instantly, no cross-fade, on the loading
                            // toggle or the count update.
                            .animation(nil, value: isLoadingMore)
                            .animation(nil, value: results.count)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("AccentButton"))
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
        // the empty-area map), or the empty list / service-unavailable view
        // with its radius header is up, keep it visible during the refetch —
        // when the radius control widens an empty search (or retries an
        // offline one), the user should watch the view fill in and keep the
        // +/- they just tapped, rather than lose it to a spinner.
        if !hasResults && !isShowingMap && !isShowingEmptyList && !isShowingServiceUnavailable {
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
        // search-radius from the last USER-centered fetch, the user has
        // moved cities — drop the stale pins so they don't keep staring
        // at last-session's landmarks while the new fetch runs. Compared
        // against `lastUserFetchCenter`, never `lastFetchCenter`: pan and
        // area fetches write the latter with a PANNED center, which made
        // tab re-entry while panned look like a city move and wipe the
        // pins (and the disk cache) for nothing.
        if hasResults, let cachedCenter = lastUserFetchCenter {
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
        // realizing. Re-anchoring the LIST home matters as much as the
        // pins: leaving `areaAnchor` pointing at the old area scoped the
        // fresh GPS-centered results to a place they aren't, stranding
        // the list on "No landmarks in this area" until the Back chip
        // was found. `previousFetchCenter` is kept so the transient-
        // failure path below can restore pan-to-search.
        let previousFetchCenter = lastFetchCenter
        lastFetchCenter = nil
        areaAnchor = nil
        mapCenter = loc.coordinate

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
            // heard back from the service. Restore `lastFetchCenter`
            // (it was nil'd above, before the stream ran) — a future
            // pan should still trigger a fetch from the old center;
            // leaving it nil silently disabled pan-to-search until the
            // next successful refresh. Leave existing pins alone if we
            // already have some (a refresh that failed shouldn't blow
            // away the last successful results); only switch to the
            // explicit failure state when there are no pins to keep.
            lastFetchCenter = previousFetchCenter
            if !hasResults {
                state = .serviceUnavailable
                // The failure is otherwise visual-only; tell VoiceOver users
                // the refresh they triggered didn't land.
                announceForAccessibility("Couldn't load landmarks")
            }
            return
        }

        if finalResults.isEmpty {
            // SPARQL succeeded with zero hits — area is genuinely
            // empty within the search radius.
            lastFetchCenter = loc.coordinate
            lastUserFetchCenter = loc.coordinate
            lastUserFetchRadiusIndex = radiusIndex
            state = .empty
            hasMore = false
        } else {
            // Always commit the final set. In the progressive path
            // this is usually a no-op (loop already set the same
            // state); in the non-progressive path it's the actual
            // atomic swap from the previous results to the fresh
            // fetch.
            lastFetchCenter = loc.coordinate
            lastUserFetchCenter = loc.coordinate
            lastUserFetchRadiusIndex = radiusIndex
            state = .loaded(finalResults)
            // Fresh primary fetch = page 1; arm "load more" if the page
            // came back full (radius holds more than one page).
            pagesLoaded = 1
            hasMore = streamHasMore
        }

        // Results landing (or the area coming back empty) was visual-only;
        // announce the outcome so a VoiceOver user who triggered the refresh
        // hears that it finished without having to re-scrub the screen.
        announceForAccessibility(
            finalResults.isEmpty
                ? "No landmarks nearby"
                : (finalResults.count == 1
                    ? "1 landmark found"
                    : "\(finalResults.count) landmarks found")
        )

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
            await saveCurrentResultsToCache()
            return
        }
        state = .loaded(mergeResults(fresh, into: existing, user: userLocation, cap: Self.maxNearbyResults).merged)
        await saveCurrentResultsToCache()
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
    ///
    /// `revertOnFailureTo`: the pre-change `radiusIndex` to restore when the
    /// fetch fails outright, so the ladder/header never stay committed to a
    /// radius that never loaded. `markUserFetch`: true when `center` IS the
    /// user's GPS (the `returnToUserLocation` gap-fill), so a successful
    /// commit also updates the user-centered references the moved-cities
    /// check and the next return-home test run against.
    private func fetchAroundCenterForRadiusChange(
        _ center: CLLocationCoordinate2D,
        revertOnFailureTo previousIndex: Int? = nil,
        markUserFetch: Bool = false
    ) {
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
            if sparqlFailed && fresh.isEmpty {
                // The change never loaded. Without a revert the +/- and the
                // "Within N miles" header stay committed to a radius whose
                // pins never arrived — silently, since this path keeps the
                // existing pins. Roll the ladder back and zoom the camera
                // back to the radius that's actually on screen. (The
                // `targetIndex` guard above means no newer change is being
                // stomped.)
                if let previousIndex {
                    radiusIndex = previousIndex
                    let previousMeters = Double(Self.radiusMeters(forMiles: Self.radiusOptionsMiles[previousIndex]))
                    recenterRegion = MKCoordinateRegion(
                        center: center,
                        latitudinalMeters: previousMeters * 2,
                        longitudinalMeters: previousMeters * 2
                    )
                    recenterSignal += 1
                }
                return
            }
            lastFetchCenter = center
            if markUserFetch {
                lastUserFetchCenter = center
                lastUserFetchRadiusIndex = targetIndex
            }
            guard !fresh.isEmpty else { return }
            // Merge into the existing pins (dedup + user-anchored sort,
            // capped), mirroring fetchAroundMapCenter. See `mergeResults`.
            guard case .loaded(let existing) = state else {
                state = .loaded(fresh)
                await saveCurrentResultsToCache()
                return
            }
            state = .loaded(mergeResults(fresh, into: existing, user: userLocation, cap: Self.maxNearbyResults).merged)
            await saveCurrentResultsToCache()
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
        // Fresh duplicates used to be discarded wholesale, which made
        // any gap in an existing entry permanent: a thumbnail lost to
        // one bad hydration moment was preserved by every later merge
        // and re-saved into the disk cache, indefinitely (the Seth
        // Wetmore House placeholder rode that loop for weeks).
        // Existing entries still win on identity and order, but adopt
        // the fresh copy's fields where they have none.
        let freshByURL = Dictionary(
            fresh.map { ($0.pageURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in merged.indices {
            if let update = freshByURL[merged[index].pageURL] {
                merged[index] = merged[index].fillingEnrichmentGaps(from: update)
            }
        }
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
    /// Persist the currently-loaded results for the next cold-start, anchored
    /// to the user's GPS (so spatial invalidation still works) at the current
    /// radius. Called after pan / radius-widen / load-more merges so re-opening
    /// the app restores the area the user actually explored, not just the last
    /// GPS-centered refresh. Note: stale-while-revalidate still runs a fresh
    /// GPS-centered fetch on the next cold-start, which atomically replaces
    /// these pins once it lands; this just makes the instant first paint show
    /// the richer explored set. Best-effort and off-main; no-op without a
    /// location or loaded results.
    private func saveCurrentResultsToCache() async {
        guard let user = userLocation,
              case .loaded(let results) = state,
              !results.isEmpty else { return }
        await NearbyResultsCache.save(CachedNearbyFetch(
            schemaVersion: NearbyResultsCache.currentSchema,
            fetchCenter: Coordinate(
                latitude: user.coordinate.latitude,
                longitude: user.coordinate.longitude
            ),
            radiusMeters: currentRadiusMeters,
            fetchedAt: Date(),
            results: results
        ))
    }

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
            await saveCurrentResultsToCache()
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
        // A Nearby detail open is a successful lookup for review-prompt
        // purposes; the request itself fires on detail dismissal.
        successfulLookupCount += 1
        if shouldRequestReview(afterSuccessCount: successfulLookupCount) {
            reviewPromptPending = true
        }
        // Re-tapping a landmark already enriched this session would re-run
        // the whole pipeline — Wikidata claims, the article-image download,
        // and two on-device LLM calls — for fields the first pass already
        // persisted (upsert preserve-on-nil means nothing new could land).
        let sessionKey = result.pageURL.absoluteString
        guard !enrichedThisSession.contains(sessionKey) else { return }
        Task {
            let enriched = await enrichDiscoveredLandmark(
                result,
                query: result.title,
                onWikidata: { partial in
                    // Commit the fast Wikidata fields (type / inception year /
                    // coords) as soon as they return so the detail-view chips
                    // appear promptly instead of waiting on the on-device LLM and
                    // image download. preserve-on-nil keeps this intermediate
                    // write from clearing anything the placeholder already had.
                    LandmarkLookup.upsert(result: partial, in: modelContext)
                }
            )
            LandmarkLookup.upsert(result: enriched, in: modelContext)
            // Graft what the pass healed back into the in-state list
            // row + disk cache. Without this, enrichment only reached
            // SwiftData (History/detail), so a Nearby row missing its
            // thumbnail kept rendering the placeholder even after a
            // tap had downloaded the image.
            applyEnrichmentToRow(enriched)
            // Only mark the session done when the pass actually gained
            // something beyond the discover result — an offline tap that
            // enriched nothing should retry on the next tap, not get
            // remembered as complete.
            if enriched.articleImageData != nil
                || enriched.wikidataType != nil
                || enriched.summary != result.summary {
                enrichedThisSession.insert(sessionKey)
            }
        }
    }

    /// Fills the matching in-state row's missing thumbnail URL from a
    /// completed tap-enrichment pass, then persists the healed set so
    /// the fix survives the next cold start. ONLY the image URL is
    /// grafted: type/year made tapped rows sprout "house" chips the
    /// rest of the list doesn't show (Sean's call, 2026-06-10), and
    /// image BYTES would be serialized verbatim into the disk cache
    /// as base64 (they already live in SwiftData).
    private func applyEnrichmentToRow(_ enriched: LandmarkResult) {
        guard case .loaded(var results) = state,
              let index = results.firstIndex(where: { $0.pageURL == enriched.pageURL })
        else { return }
        let imageOnly = LandmarkResult(
            title: enriched.title,
            summary: "",
            rawSummary: "",
            pageURL: enriched.pageURL,
            source: enriched.source,
            articleImageURL: enriched.articleImageURL,
            articleImageData: nil,
            coordinates: nil,
            inceptionYear: nil,
            wikidataType: nil,
            onDeviceMatchScore: nil
        )
        results[index] = results[index].fillingEnrichmentGaps(from: imageOnly)
        state = .loaded(results)
        Task { await saveCurrentResultsToCache() }
    }
}
