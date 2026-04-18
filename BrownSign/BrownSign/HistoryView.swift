//
//  HistoryView.swift
//  BrownSign
//
//  History tab — list of past lookups sorted newest first. Tap a row
//  to push a LandmarkDetailView showing the full raw summary and
//  enrichment metadata.
//

import SwiftUI
import SwiftData
import UIKit
import MapKit
import CoreLocation

// MARK: - HistoryView

enum LandmarkDisplayMode: String, CaseIterable, Identifiable {
    case list, map
    var id: String { rawValue }
    var label: String { self == .list ? "List" : "Map" }
    var icon: String { self == .list ? "list.bullet" : "map" }
}

struct HistoryView: View {
    @Query(sort: \LandmarkLookup.date, order: .reverse)
    private var lookups: [LandmarkLookup]

    @Environment(\.modelContext) private var modelContext
    @State private var editMode: EditMode = .inactive
    @State private var showDeleteAllConfirmation = false
    @State private var displayMode: LandmarkDisplayMode = .list

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !lookups.isEmpty {
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
                    if lookups.isEmpty {
                        ContentUnavailableView(
                            "No lookups yet",
                            systemImage: "signpost.right.and.left",
                            description: Text("Snap a landmark sign to get started.")
                        )
                    } else {
                        switch displayMode {
                        case .list:
                            List {
                                ForEach(lookups) { lookup in
                                    NavigationLink(value: lookup) {
                                        HistoryRow(lookup: lookup)
                                    }
                                }
                                .onDelete(perform: deleteLookups)
                            }
                            .environment(\.editMode, $editMode)
                        case .map:
                            HistoryMapView(lookups: lookups)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: LandmarkLookup.self) { lookup in
                LandmarkDetailView(lookup: lookup)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if displayMode == .list && editMode.isEditing && !lookups.isEmpty {
                        Button("Delete All", role: .destructive) {
                            showDeleteAllConfirmation = true
                        }
                        .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if displayMode == .list && !lookups.isEmpty {
                        EditButton()
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: displayMode) { _, newMode in
                // Exiting edit mode cleanly when switching to map.
                if newMode == .map { editMode = .inactive }
            }
            .confirmationDialog(
                "Delete all history?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all \(lookups.count) saved lookups. This cannot be undone.")
            }
        }
    }

    private func deleteLookups(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(lookups[index])
        }
    }

    private func deleteAll() {
        for lookup in lookups {
            modelContext.delete(lookup)
        }
        editMode = .inactive
    }
}

// MARK: - HistoryMapView

/// Map-based alternative to the history list. Shows every saved lookup
/// that has coordinates as a brown signpost pin. Tap a pin to reveal a
/// compact card that links into the full detail view.
struct HistoryMapView: View {
    let lookups: [LandmarkLookup]

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selection: LandmarkLookup?

    private var mapped: [LandmarkLookup] {
        lookups.filter { $0.hasCoordinates }
    }

    var body: some View {
        if mapped.isEmpty {
            ContentUnavailableView(
                "No mapped landmarks",
                systemImage: "mappin.slash",
                description: Text("Lookups with coordinates will appear here on a map.")
            )
        } else {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition, selection: $selection) {
                    UserAnnotation()
                    ForEach(mapped) { lookup in
                        if let lat = lookup.latitude, let lon = lookup.longitude {
                            Marker(
                                lookup.resolvedTitle,
                                systemImage: "signpost.right.fill",
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            )
                            .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                            .tag(lookup)
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onAppear {
                    cameraPosition = .region(regionFittingAll(mapped))
                }
                .onChange(of: mapped.count) { _, _ in
                    cameraPosition = .region(regionFittingAll(mapped))
                }

                if let selected = selection {
                    SelectedLookupCard(lookup: selected, onDismiss: {
                        selection = nil
                    })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selection)
            // iOS 26 Liquid Glass tab bars are translucent by default and
            // let content flow under them. Map tiles showing through is
            // distracting, so force a visible tab-bar background for this
            // view only.
            .toolbarBackground(.visible, for: .tabBar)
        }
    }

    /// Bounding-box region for the given lookups, padded so pins aren't
    /// flush against the edges. Falls back to a default span for a
    /// single point.
    private func regionFittingAll(_ items: [LandmarkLookup]) -> MKCoordinateRegion {
        let coords: [CLLocationCoordinate2D] = items.compactMap {
            guard let lat = $0.latitude, let lon = $0.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard !coords.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 50)
            )
        }
        if coords.count == 1 {
            return MKCoordinateRegion(
                center: coords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.02, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.02, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// Compact summary card shown over the map when a pin is selected.
private struct SelectedLookupCard: View {
    let lookup: LandmarkLookup
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(lookup.resolvedTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(lookup.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                NavigationLink(value: lookup) {
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
        if let data = lookup.articleImageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let data = lookup.imageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
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
}

// MARK: - HistoryRow

struct HistoryRow: View {
    let lookup: LandmarkLookup

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(lookup.resolvedTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(lookup.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    sourceBadge
                    Text(lookup.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        // Preference order:
        //   1. Persisted Wikipedia article image bytes
        //   2. User's captured sign photo
        //   3. Brown signpost placeholder
        if let data = lookup.articleImageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            fallbackThumbnail
        }
    }

    @ViewBuilder
    private var fallbackThumbnail: some View {
        if let data = lookup.imageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
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

    @ViewBuilder
    private var sourceBadge: some View {
        if lookup.source == "nps" {
            Label("NPS", systemImage: "leaf.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Wikipedia", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - LandmarkDetailView

struct LandmarkDetailView: View {
    let lookup: LandmarkLookup

    @State private var showSafari = false
    @State private var showMapsDialog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Persisted Wikipedia article image, if available.
                if let data = lookup.articleImageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipped()
                        .contentShape(Rectangle())
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // The user's captured sign photo (local thumbnail), if any.
                if let data = lookup.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipped()
                        .contentShape(Rectangle())
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                SelectableText(
                    text: lookup.resolvedTitle,
                    font: .preferredFont(forTextStyle: .title2).bold()
                )

                HStack(spacing: 12) {
                    Button {
                        showSafari = true
                    } label: {
                        sourceBadge
                    }
                    .buttonStyle(.plain)
                    Text(lookup.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                metadataBlock

                if !lookup.rawSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full description")
                            .font(.headline)
                        SelectableText(text: lookup.rawSummary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        showSafari = true
                    } label: {
                        Label("Read full article", systemImage: "safari")
                            .fontWeight(.regular)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                    .buttonBorderShape(.roundedRectangle(radius: 0))
                    .disabled(lookup.pageURL == nil)

                    if let url = lookup.pageURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                        .buttonBorderShape(.roundedRectangle(radius: 0))
                    }
                }

                if !lookup.rawSignText.isEmpty {
                    Text("Original sign: \(lookup.rawSignText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        .navigationTitle(lookup.resolvedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSafari) {
            if let url = lookup.pageURL {
                SafariView(url: url)
            }
        }
        .sheet(isPresented: $showMapsDialog) {
            if let lat = lookup.latitude, let lon = lookup.longitude {
                DirectionsSheet(
                    latitude: lat,
                    longitude: lon,
                    name: lookup.resolvedTitle
                )
            }
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if lookup.source == "nps" {
            Label("NPS", systemImage: "leaf.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Wikipedia", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var metadataBlock: some View {
        let hasAny = lookup.hasCoordinates
            || lookup.inceptionYear != nil
            || lookup.wikidataType != nil

        if hasAny {
            VStack(alignment: .leading, spacing: 6) {
                if let lat = lookup.latitude, let lon = lookup.longitude {
                    Label(String(format: "%.4f, %.4f", lat, lon),
                          systemImage: "mappin.and.ellipse")
                        .font(.caption)
                    Button {
                        showMapsDialog = true
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                if let year = lookup.inceptionYear {
                    Label("Est. \(String(year))", systemImage: "calendar")
                        .font(.caption)
                }
                if let type = lookup.wikidataType {
                    Label(type, systemImage: "tag.fill")
                        .font(.caption)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
    }

}
