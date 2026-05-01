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
    }

    /// 5-mile search radius (8047 m via 5 × 1609.344). Passed to
    /// the SPARQL fetch as 8.047 km — Wikidata's `wikibase:around`
    /// has no hard cap like Wikipedia's geosearch did.
    private static let searchRadiusMeters = 8_047
    /// How many landmarks to hydrate + render per fetch. The SPARQL
    /// query returns up to 300 hits in dense areas; we sort by
    /// distance and truncate to this cap before hydrating.
    private static let fetchLimit = 100
    /// Minimum distance the map center must move before we fire a new
    /// pan-centered geosearch — half the search radius (~2.5 miles).
    /// Below this, the existing 5-mile fetch already covers where the
    /// user is looking.
    private static let panRefetchThresholdMeters: CLLocationDistance = 4_023

    @State private var state: LoadState = .idle
    @State private var isReloading = false
    @State private var isFetchingMore = false
    @State private var userLocation: CLLocation?
    /// Center of the most recent geosearch. Drives the pan-threshold
    /// check: if the new map center is more than
    /// `panRefetchThresholdMeters` from this, fire another fetch.
    @State private var lastFetchCenter: CLLocationCoordinate2D?
    @State private var pushedLookup: LandmarkLookup?
    @State private var displayMode: LandmarkDisplayMode = .list
    /// Incremented by `refresh(force: true)` to tell the map view to
    /// snap its camera back to the user's location. The map's camera
    /// is its own `@State` — the parent can't reach in to update it
    /// directly — so we pass this counter down and the map observes
    /// it via `.onChange`.
    @State private var recenterSignal = 0
    @State private var searchText: String = ""
    @State private var showHiddenSheet = false

    private let locationManager = LocationManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Show the list/map picker whenever we've got a
                // location, not just when results are loaded. In the
                // .empty state we explicitly tell the user to switch
                // to the map and pan — they need the switcher visible
                // to actually do that.
                if displayModePickerVisible {
                    Picker("Display mode", selection: $displayMode) {
                        ForEach(LandmarkDisplayMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
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
                            Text("Brown Sign uses your location to find landmarks within 5 miles of you. Turn on location access in Settings.")
                        } actions: {
                            Button {
                                LocationManager.openAppSettings()
                            } label: {
                                Label("Open Settings", systemImage: "gear")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                        }
                    case .locationUnavailable:
                        ContentUnavailableView(
                            "Can't find your location",
                            systemImage: "location.slash",
                            description: Text("Try again once you have GPS signal.")
                        )
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
                                description: Text("No geo-tagged Wikipedia landmarks within 5 miles of your location. Switch to the map and pan to a different area to keep exploring.")
                            )
                        case .map:
                            NearbyMapView(
                                results: [],
                                userLocation: userLocation,
                                recenterSignal: recenterSignal,
                                onSelect: { open($0) },
                                onMapCenterChanged: { center in
                                    Task { await fetchAroundMapCenter(center) }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                            .padding(.top, 16)
                            // Same gap below the map as above so the
                            // tab bar has breathing room — matches
                            // the search-field-to-map gap.
                            .padding(.bottom, 16)
                        }
                    case .loaded(let results):
                        let visible = visibleResults(from: results)
                        switch displayMode {
                        case .list:
                            list(visible)
                        case .map:
                            NearbyMapView(
                                results: visible,
                                userLocation: userLocation,
                                recenterSignal: recenterSignal,
                                onSelect: { open($0) },
                                onMapCenterChanged: { center in
                                    Task { await fetchAroundMapCenter(center) }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                            .padding(.top, 16)
                            // Same gap below the map as above so the
                            // tab bar has breathing room — matches
                            // the search-field-to-map gap.
                            .padding(.bottom, 16)
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
                    if isReloading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await refresh(force: true) }
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
            if case .idle = state {
                await refresh(force: false)
            }
            // Cold start often races location services and the SPARQL
            // endpoint — first fetch can come back empty even when the
            // area has plenty of nearby landmarks. Wait a few seconds
            // and retry once before leaving the user staring at "no
            // landmarks nearby" (or a location-unavailable error) when
            // a manual tap on Refresh would have worked.
            if shouldAutoRetryInitialFetch {
                try? await Task.sleep(for: .seconds(3))
                if shouldAutoRetryInitialFetch {
                    await refresh(force: false)
                }
            }
        }
    }

    /// True while the initial-load state is one a retry can plausibly
    /// fix — empty results or a location-services miss. `.loaded`,
    /// `.locationDenied`, and `.loading` aren't candidates.
    private var shouldAutoRetryInitialFetch: Bool {
        switch state {
        case .empty, .locationUnavailable: return true
        default: return false
        }
    }

    /// Apply the user's hide-list and the search-text filter to the
    /// raw discover results. Both filters compose: a landmark whose URL
    /// is hidden never appears, and what's left is narrowed by partial
    /// (case-insensitive) substring match against the title.
    private func visibleResults(from results: [LandmarkResult]) -> [LandmarkResult] {
        let hiddenURLs = Set(hiddenLandmarks.map(\.pageURLString))
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        VStack(spacing: 14) {
            ProgressView()
            Text("Finding landmarks near you…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func list(_ results: [LandmarkResult]) -> some View {
        // Lat/long context row sits OUTSIDE the List so it doesn't
        // steal the inset-grouped section's rounded top corners from
        // the first landmark row. Inside the List with a clear
        // background, the List still treats it as row 0 and applies
        // top-rounded corners there — making the first visible row
        // look chopped.
        VStack(spacing: 0) {
            if let loc = userLocation {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.caption)
                    Text(String(format: "Within 5 miles of current location (%.4f, %.4f)",
                                loc.coordinate.latitude, loc.coordinate.longitude))
                        .font(.caption)
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }

            List {
                // Identify rows by canonical page URL — a stable
                // identifier that survives the result set shrinking
                // when a row is hidden. Indexing by `\.offset` would
                // re-number the remaining rows and SwiftUI could
                // mis-diff which row left the list.
                ForEach(results, id: \.pageURL) { result in
                    Button {
                        open(result)
                    } label: {
                        NearbyRow(result: result, userLocation: userLocation)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color("CardBackground"))
                    // Zero leading/trailing so row content aligns
                    // with the picker / search field above (the
                    // outer .padding(.horizontal) provides the only
                    // margin; plain style would otherwise add ~16pt
                    // of its own, doubling the gap).
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            hide(result)
                        } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                        .tint(.orange)
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
                        // Match the .caption sizing used by the
                        // "Within 5 miles…" header at the top of the
                        // list — same compact label style.
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                    .listRowBackground(Color("CardBackground"))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            // Plain style instead of the default inset-grouped, so
            // the rows extend full-width within the padded list
            // frame. Inset-grouped adds its own per-row inset on top
            // of any outer .padding(.horizontal), squeezing the rows.
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            // Hide the system bg and replace with parchment so the
            // swipe-action area matches the row color (no seam).
            .scrollContentBackground(.hidden)
            .background(Color("CardBackground"))
            // Round corners and clip so the list reads as a parchment
            // card on the system page bg, matching the Scan recents
            // pattern. Bottom rounding may sit behind the tab bar; the
            // top rounding is what the user actually sees.
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Match the picker/search field's horizontal margin so
            // the list lines up with the chrome above it.
            .padding(.horizontal)
            // Header bottom padding (8) already gives breathing room
            // above the first row, so the list's own top content
            // margin can be tight.
            .contentMargins(.top, 4, for: .scrollContent)
            .refreshable {
                await refresh(force: true)
            }
        }
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

    private func refresh(force: Bool) async {
        // Preserve existing results while reloading so pull-to-refresh
        // and the toolbar button don't wipe the list. Only flip to the
        // full-screen loading view when we have nothing to show yet.
        if !hasResults { state = .loading }
        isReloading = true
        defer { isReloading = false }

        // Manual refresh discards any panned-around pins and recenters
        // on the user. Otherwise the "Nearby" list could drift to a
        // totally different part of the world without the user
        // realizing.
        lastFetchCenter = nil

        let granted = await locationManager.ensurePermission()
        guard granted else {
            state = .locationDenied
            return
        }
        guard let loc = await locationManager.currentLocation(withTimeout: 5) else {
            if !hasResults { state = .locationUnavailable }
            return
        }
        userLocation = loc
        let found = await discoverLandmarksAt(
            center: loc.coordinate,
            radiusMeters: Self.searchRadiusMeters,
            limit: Self.fetchLimit
        )
        lastFetchCenter = loc.coordinate
        state = found.isEmpty ? .empty : .loaded(found)

        // Tell the map to snap its camera back to the user. If we
        // don't do this, the refresh button is silent on the map —
        // the underlying data resets but the view stays wherever the
        // user had panned to, which is exactly the "doesn't bring me
        // home" bug.
        recenterSignal += 1
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
        guard !isFetchingMore else { return }
        // Pan threshold: if the new center is still within the
        // current 5-mile fetch's area, we already have its landmarks.
        if let last = lastFetchCenter {
            let dist = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            guard dist > Self.panRefetchThresholdMeters else { return }
        }

        isFetchingMore = true
        defer { isFetchingMore = false }

        let fresh = await discoverLandmarksAt(
            center: center,
            radiusMeters: Self.searchRadiusMeters,
            limit: Self.fetchLimit
        )
        lastFetchCenter = center
        guard !fresh.isEmpty else { return }

        // Merge into existing results. Dedup by canonical page URL —
        // the same landmark surfaced by two overlapping geosearches
        // would otherwise appear as two pins.
        guard case .loaded(var existing) = state else {
            state = .loaded(fresh)
            return
        }
        let seen = Set(existing.map(\.pageURL))
        for result in fresh where !seen.contains(result.pageURL) {
            existing.append(result)
        }
        // Re-sort by distance from USER (not from the map center) so
        // the list remains anchored to where the user actually is.
        if let user = userLocation {
            existing.sort { a, b in
                let da = a.coordinates.map {
                    user.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                } ?? .infinity
                let db = b.coordinates.map {
                    user.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                } ?? .infinity
                return da < db
            }
        }
        state = .loaded(existing)
    }

    // MARK: - Tap-to-open

    /// Upsert an unenriched placeholder immediately so the detail view
    /// has something to render, then enrich in the background. Mirrors
    /// the scan flow in ContentView.
    private func open(_ result: LandmarkResult) {
        let placeholder = upsertLookup(result: result)
        pushedLookup = placeholder
        Task {
            let enriched = await enrichDiscoveredLandmark(result, query: result.title)
            _ = upsertLookup(result: enriched)
        }
    }

    @discardableResult
    private func upsertLookup(result res: LandmarkResult) -> LandmarkLookup {
        let key = res.pageURL.absoluteString
        let descriptor = FetchDescriptor<LandmarkLookup>(
            predicate: #Predicate { $0.pageURLString == key }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.resolvedTitle = res.title
            existing.summary = res.summary
            existing.rawSummary = res.rawSummary
            existing.source = res.source
            existing.articleImageURLString = res.articleImageURL?.absoluteString
            if let newData = res.articleImageData {
                existing.articleImageData = newData
            }
            existing.latitude = res.coordinates?.latitude
            existing.longitude = res.coordinates?.longitude
            if let year = res.inceptionYear { existing.inceptionYear = year }
            if let type = res.wikidataType { existing.wikidataType = type }
            if let kg = res.externalConfidence { existing.externalConfidence = kg }
            if let m = res.onDeviceMatchScore { existing.onDeviceMatchScore = m }
            existing.date = Date()
            return existing
        }

        let lookup = LandmarkLookup(
            rawSignText: "",
            resolvedTitle: res.title,
            summary: res.summary,
            rawSummary: res.rawSummary,
            pageURLString: res.pageURL.absoluteString,
            source: res.source,
            imageData: nil,
            articleImageURLString: res.articleImageURL?.absoluteString,
            articleImageData: res.articleImageData,
            latitude: res.coordinates?.latitude,
            longitude: res.coordinates?.longitude,
            inceptionYear: res.inceptionYear,
            wikidataType: res.wikidataType,
            externalConfidence: res.externalConfidence,
            onDeviceMatchScore: res.onDeviceMatchScore
        )
        modelContext.insert(lookup)
        return lookup
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
                            Text(formatDistance(d))
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

    @ViewBuilder
    private var thumbnail: some View {
        if let url = result.articleImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    Color.secondary.opacity(0.1)
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.brown.opacity(0.18))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "signpost.right.fill")
                    .font(.title2)
                    .foregroundStyle(.brown)
            }
    }

    private func distanceMeters(from user: CLLocation?, to coord: Coordinate) -> CLLocationDistance {
        guard let user else { return 0 }
        let other = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return user.distance(from: other)
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        let usesMetric = Locale.current.measurementSystem == .metric
        if usesMetric {
            if meters < 1_000 { return "\(Int(meters)) m" }
            return String(format: "%.1f km", meters / 1_000)
        } else {
            let miles = meters / 1609.344
            if miles < 0.1 {
                let feet = meters / 0.3048
                return "\(Int(feet)) ft"
            }
            if miles < 10 { return String(format: "%.1f mi", miles) }
            return "\(Int(miles)) mi"
        }
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

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedID: String?

    /// Pageurl-keyed lookup so the Map's selection binding (which has to
    /// be Hashable) doesn't need LandmarkResult itself to be Hashable.
    private var resultsByID: [String: LandmarkResult] {
        Dictionary(uniqueKeysWithValues: results.map { ($0.pageURL.absoluteString, $0) })
    }

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
                        .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
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
                // Parent bumped the counter via the toolbar refresh
                // button — re-fit to user + pins so the user comes
                // home after panning off to another region.
                withAnimation { cameraPosition = .region(initialRegion()) }
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

            if let id = selectedID, let selected = resultsByID[id] {
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
            latitudeDelta: max(0.02, (lats.max()! - lats.min()!) * 1.4),
            longitudeDelta: max(0.02, (lons.max()! - lons.min()!) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
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
            RoundedRectangle(cornerRadius: 14)
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
                .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = result.articleImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.brown.opacity(0.18))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "signpost.right.fill")
                    .font(.title2)
                    .foregroundStyle(.brown)
            }
    }
}
