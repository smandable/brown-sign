//
//  NearbyViews.swift
//  BrownSign
//
//  Presentation subviews extracted from NearMeView.swift: the cold-start
//  loading view, the list row, the map view with its zoom/radius controls,
//  and the selected-pin callout card. Each is driven entirely by the values
//  and closures NearMeView passes in (no shared state), so they live here to
//  keep NearMeView focused on the load/state machine.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

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
struct NearbyLoadingView: View {
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

struct NearbyRow: View {
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
struct NearbyMapView: View {
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
        // User coordinate (when known) goes first so it's the antimeridian
        // fallback anchor, matching the previous local behavior.
        var points: [CLLocationCoordinate2D] = []
        if let user = userLocation {
            points.append(user.coordinate)
        }
        for r in results {
            if let c = r.coordinates {
                points.append(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
            }
        }
        return fittingRegion(for: points, singlePointSpan: 0.03, padding: 1.2)
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
struct MapZoomControl: View {
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
struct RadiusStepper: View {
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
struct SelectedNearbyCard: View {
    let result: LandmarkResult
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        MapCalloutCard(
            title: result.title,
            summary: result.summary,
            articleImageData: result.articleImageData,
            articleImageURL: result.articleImageURL,
            onDismiss: onDismiss,
            detail: {
                Button(action: onView) {
                    Label("View details", systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandBrown"))
                .controlSize(.small)
                .buttonBorderShape(.roundedRectangle(radius: 8))
            },
            wrap: { content in
                Button(action: onView) { content }
            }
        )
    }
}
