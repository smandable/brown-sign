//
//  NearMeView.swift
//  BrownSign
//
//  Nearby discovery tab — surface geo-tagged Wikipedia landmarks within
//  10 km of the user without requiring a scan. Tap a row to enrich and
//  save it to history, then navigate to the full detail view (same
//  destination used by Scan and History).
//

import SwiftUI
import SwiftData
import CoreLocation
import UIKit
import MapKit

struct NearMeView: View {
    @Environment(\.modelContext) private var modelContext

    private enum LoadState {
        case idle
        case loading
        case locationDenied
        case locationUnavailable
        case loaded([LandmarkResult])
        case empty
    }

    /// Radius tiers for progressive expansion. Nearby starts at 10 km
    /// (Wikipedia's geosearch hard cap), and widens in 5 km steps as
    /// the user scrolls past the bottom of the list or zooms the map
    /// out, up to 25 km. OSM's Overpass allows the full range; the
    /// Wikipedia geosearch call is clipped at 10 km internally.
    private static let initialRadiusMeters = 10_000
    private static let maxRadiusMeters = 25_000
    private static let radiusStepMeters = 5_000

    @State private var state: LoadState = .idle
    @State private var isReloading = false
    @State private var isLoadingMore = false
    @State private var userLocation: CLLocation?
    @State private var pushedLookup: LandmarkLookup?
    @State private var displayMode: LandmarkDisplayMode = .list
    @State private var currentRadiusMeters: Int = NearMeView.initialRadiusMeters

    private let locationManager = LocationManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasResults {
                    Picker("Display mode", selection: $displayMode) {
                        ForEach(LandmarkDisplayMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                Group {
                    switch state {
                    case .idle, .loading:
                        loadingView
                    case .locationDenied:
                        ContentUnavailableView {
                            Label("Location permission needed", systemImage: "location.slash")
                        } description: {
                            Text("Brown Sign uses your location to find landmarks within 10 km of you. Turn on location access in Settings.")
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
                        ContentUnavailableView(
                            "No landmarks nearby",
                            systemImage: "signpost.right.and.left",
                            description: Text("No geo-tagged Wikipedia landmarks within 10 km of your location.")
                        )
                    case .loaded(let results):
                        switch displayMode {
                        case .list:
                            list(results)
                        case .map:
                            NearbyMapView(
                                results: results,
                                userLocation: userLocation,
                                currentRadiusMeters: currentRadiusMeters,
                                onSelect: { open($0) },
                                onZoomExpansionNeeded: { visibleRadius in
                                    Task { await loadMore(targetRadiusMeters: Int(visibleRadius)) }
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Nearby")
            .toolbar {
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
        }
        .task {
            if case .idle = state {
                await refresh(force: false)
            }
        }
    }

    private var hasResults: Bool {
        if case .loaded = state { return true }
        return false
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
        List {
            if let loc = userLocation {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill")
                            .font(.caption)
                        Text(String(format: "Within %d km of current location (%.4f, %.4f)",
                                    currentRadiusMeters / 1_000,
                                    loc.coordinate.latitude, loc.coordinate.longitude))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    Button {
                        open(result)
                    } label: {
                        NearbyRow(result: result, userLocation: userLocation)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Trigger radius expansion as the user nears
                        // the bottom of the list. Fire slightly before
                        // the absolute last row so the newly loaded
                        // items are already on-screen by the time the
                        // user gets there.
                        if index >= results.count - 3 {
                            Task { await loadMore() }
                        }
                    }
                }

                // Footer row — shows a spinner during expansion or the
                // final "showing everything within 25 km" note when we
                // hit the cap.
                footerRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .refreshable {
            await refresh(force: true)
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: 8) {
            if isLoadingMore {
                ProgressView()
                Text("Widening search…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if currentRadiusMeters >= Self.maxRadiusMeters {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Showing everything within 25 km")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    // MARK: - Load

    private func refresh(force: Bool) async {
        // Preserve existing results while reloading so pull-to-refresh
        // and the toolbar button don't wipe the list. Only flip to the
        // full-screen loading view when we have nothing to show yet.
        if !hasResults { state = .loading }
        isReloading = true
        defer { isReloading = false }

        // Manual refresh resets back to the 10 km baseline. The user
        // can re-expand by scrolling or zooming out; keeping a stale
        // 25 km radius across refreshes would be confusing and
        // wasteful on Overpass.
        currentRadiusMeters = Self.initialRadiusMeters

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
        let found = await discoverLandmarksNearby(
            userLocation: loc,
            radiusMeters: currentRadiusMeters,
            limit: limit(for: currentRadiusMeters)
        )
        state = found.isEmpty ? .empty : .loaded(found)
    }

    /// Widen the search radius up to the 25 km cap and replace the
    /// loaded list with the larger result set. Called when the user
    /// scrolls past the bottom of the list or zooms the map beyond
    /// the current radius.
    ///
    /// When `targetRadiusMeters` is provided (the map zoom path), we
    /// jump directly to the next tier that covers the visible area —
    /// a single big pinch-out shouldn't require multiple gestures to
    /// load all the pins in the visible region. When it's nil (the
    /// list scroll path), we advance one 5 km tier at a time.
    ///
    /// No-ops at the cap or when another expansion is in flight.
    private func loadMore(targetRadiusMeters: Int? = nil) async {
        guard !isLoadingMore else { return }
        guard currentRadiusMeters < Self.maxRadiusMeters else { return }
        guard let loc = userLocation else { return }

        let desired: Int
        if let target = targetRadiusMeters {
            // Round up to the nearest 5 km tier ≥ target, capped at max.
            let snapped = ((target + Self.radiusStepMeters - 1)
                / Self.radiusStepMeters) * Self.radiusStepMeters
            desired = min(max(snapped, currentRadiusMeters + Self.radiusStepMeters),
                          Self.maxRadiusMeters)
        } else {
            desired = min(currentRadiusMeters + Self.radiusStepMeters,
                          Self.maxRadiusMeters)
        }

        // Guard against no-op targets (target already within current radius).
        guard desired > currentRadiusMeters else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let found = await discoverLandmarksNearby(
            userLocation: loc,
            radiusMeters: desired,
            limit: limit(for: desired)
        )
        // Only update state if we actually got a superset — protects
        // against a transient network blip wiping out the existing
        // results. If expansion returned nothing, keep the old list.
        currentRadiusMeters = desired
        if !found.isEmpty {
            state = .loaded(found)
        }
    }

    /// Per-radius result cap. Scales linearly so dense cities don't
    /// stop at 40 pins when the user widens to 25 km.
    private func limit(for radiusMeters: Int) -> Int {
        max(40, radiusMeters / 250)
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
                        Label(formatDistance(d), systemImage: "location")
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
    /// Current search radius in meters. Drives the zoom-out expansion
    /// trigger: as the visible region grows past this value, we ask
    /// the parent to widen the search.
    let currentRadiusMeters: Int
    let onSelect: (LandmarkResult) -> Void
    /// Called when the visible map region extends meaningfully past
    /// `currentRadiusMeters`. The argument is the approximate radius
    /// of the visible region in meters, so the parent can jump
    /// straight to the right tier rather than step through one by
    /// one. Parent no-ops at the 25 km cap.
    let onZoomExpansionNeeded: (Double) -> Void

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
            .onMapCameraChange(frequency: .onEnd) { context in
                // When the visible map region extends past the current
                // search radius — either because the user zoomed out
                // OR because they panned to a nearby area that was
                // outside the previous search — ask the parent to
                // widen. `.onEnd` only fires after the user stops
                // interacting, so we don't spam refetches mid-gesture.
                guard let user = userLocation else { return }
                let needed = furthestVisibleDistanceMeters(
                    from: user,
                    region: context.region
                )
                // Trigger when the furthest visible point is at least
                // 20% past the current radius — small pans shouldn't
                // keep bumping the search.
                if needed > Double(currentRadiusMeters) * 1.2 {
                    onZoomExpansionNeeded(needed)
                }
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

    /// Distance (meters) from the user to the furthest visible corner
    /// of the map region. Used to decide how wide the search radius
    /// needs to be to cover what the user is currently looking at —
    /// handles both zoom-out (corners get further away) and pan (user
    /// stops being the center of the view).
    private func furthestVisibleDistanceMeters(
        from user: CLLocation,
        region: MKCoordinateRegion
    ) -> Double {
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        let corners: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(
                latitude: region.center.latitude + halfLat,
                longitude: region.center.longitude + halfLon
            ),
            CLLocationCoordinate2D(
                latitude: region.center.latitude + halfLat,
                longitude: region.center.longitude - halfLon
            ),
            CLLocationCoordinate2D(
                latitude: region.center.latitude - halfLat,
                longitude: region.center.longitude + halfLon
            ),
            CLLocationCoordinate2D(
                latitude: region.center.latitude - halfLat,
                longitude: region.center.longitude - halfLon
            ),
        ]
        return corners
            .map { user.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
            .max() ?? 0
    }

    /// Fit the bounding box of the user-location dot plus every pin with
    /// 40% padding. Tighter than a fixed-span center-on-user in dense
    /// areas (pins cluster); opens up naturally when results are spread
    /// out to the 10 km search radius.
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
/// selected. Its "View details" button calls `onView`, which runs the
/// same enrich + push flow used by the list rows.
private struct SelectedNearbyCard: View {
    let result: LandmarkResult
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)
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
