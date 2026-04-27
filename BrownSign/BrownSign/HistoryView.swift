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
/// The whole card body is a NavigationLink to the detail view; the X
/// is a sibling button so dismissing the card doesn't also navigate.
private struct SelectedLookupCard: View {
    let lookup: LandmarkLookup
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: lookup) {
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

    /// Card content that's the tappable navigation target. "View
    /// details" is a real NavigationLink (nested inside the outer
    /// NavigationLink) so it keeps its press-state feedback as a
    /// distinct button. Both push the same `lookup` value; SwiftUI
    /// routes taps inside the inner link to it and taps elsewhere in
    /// the card to the outer link.
    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(lookup.resolvedTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        .task {
            // Backfill for items saved before the REST summary fallback
            // existed. Runs whenever a row with an empty `summary`
            // appears on screen — no tap required. Wikipedia only (NPS
            // doesn't exhibit the empty-intro failure mode).
            //
            // Guarded on `summary`, not `rawSummary`, because earlier
            // versions of this fix populated only rawSummary — those
            // rows still need their list-row summary filled in, and
            // should reuse the stored extract instead of re-fetching.
            guard lookup.summary.isEmpty,
                  lookup.source == "wikipedia"
            else { return }
            let text: String
            if !lookup.rawSummary.isEmpty {
                text = lookup.rawSummary
            } else if let fetched = await wikipediaRESTSummaryExtract(for: lookup.resolvedTitle) {
                lookup.rawSummary = fetched
                text = fetched
            } else {
                return
            }
            lookup.summary = text
            let polished = await polishSummary(text)
            if polished != text {
                lookup.summary = polished
            }
        }
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

/// One slide in the detail-view image carousel. Two flavors: `local`
/// for the persisted primary thumbnail (already in SwiftData as JPEG
/// bytes), `remote` for additional gallery images that load lazily
/// via AsyncImage when the user swipes to them.
private struct DetailImageSlide: Identifiable {
    let id: String
    let kind: Kind
    enum Kind {
        case local(UIImage)
        case remote(URL)
    }
}

struct LandmarkDetailView: View {
    let lookup: LandmarkLookup

    @State private var showSafari = false
    @State private var showMapsDialog = false
    /// Additional Wikipedia article images beyond the persisted
    /// primary thumbnail. Populated by a background fetch in `.task`
    /// when the detail view appears; each entry loads lazily via
    /// `AsyncImage` only when the user swipes to it. Empty until the
    /// fetch completes (or stays empty if Wikipedia returns no
    /// gallery-worthy extras).
    @State private var additionalImageURLs: [URL] = []
    /// Explicit `TabView` selection so the carousel stays pinned to
    /// the slide the user is on when `imageSlides` changes shape
    /// (extras arriving asynchronously). Without this binding the
    /// TabView's internal index can drift on re-render and visibly
    /// jump between slides without the user swiping.
    @State private var carouselSelection: String = "primary"

    /// Slides assembled for the image carousel: the persisted
    /// primary thumbnail first (if we have it), then any extra
    /// gallery images from Wikipedia. Each slide carries an `id` so
    /// `TabView`'s `ForEach` keys correctly across re-renders.
    private var imageSlides: [DetailImageSlide] {
        var slides: [DetailImageSlide] = []
        if let data = lookup.articleImageData, let image = UIImage(data: data) {
            slides.append(DetailImageSlide(id: "primary", kind: .local(image)))
        }
        for url in additionalImageURLs {
            slides.append(DetailImageSlide(id: url.absoluteString, kind: .remote(url)))
        }
        return slides
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Image carousel: persisted primary + lazy gallery
                // images. Page dots only appear when there's more
                // than one slide.
                if !imageSlides.isEmpty {
                    TabView(selection: $carouselSelection) {
                        ForEach(imageSlides) { slide in
                            slideView(slide)
                                .tag(slide.id)
                        }
                    }
                    .frame(height: 260)
                    .tabViewStyle(
                        .page(indexDisplayMode: imageSlides.count > 1 ? .always : .never)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // If the current selection isn't in the slide
                    // list (e.g. extras arrived but selection somehow
                    // drifted), snap back to the first slide.
                    .onChange(of: imageSlides.map(\.id)) { _, ids in
                        if !ids.contains(carouselSelection),
                           let first = ids.first {
                            carouselSelection = first
                        }
                    }
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
        .task {
            // Safety-net backfill — the same logic lives on HistoryRow
            // and almost always runs first (the row has to appear for
            // the user to tap it). This covers the edge case where the
            // row task was cancelled mid-fetch (row scrolled off) but
            // the user still tapped through.
            guard lookup.summary.isEmpty,
                  lookup.source == "wikipedia"
            else { return }
            let text: String
            if !lookup.rawSummary.isEmpty {
                text = lookup.rawSummary
            } else if let fetched = await wikipediaRESTSummaryExtract(for: lookup.resolvedTitle) {
                lookup.rawSummary = fetched
                text = fetched
            } else {
                return
            }
            lookup.summary = text
            let polished = await polishSummary(text)
            if polished != text {
                lookup.summary = polished
            }
        }
        .task(id: lookup.resolvedTitle) {
            // Fetch extra gallery-worthy article images for the
            // carousel. Wikipedia REST returns only metadata (URLs +
            // dimensions); image bytes don't download until the user
            // swipes to that slide. NPS-sourced lookups skip this —
            // they don't have a Wikipedia article to query.
            guard lookup.source == "wikipedia",
                  additionalImageURLs.isEmpty else { return }
            let primaryURL = lookup.articleImageURLString.flatMap(URL.init(string:))
            let extras = await wikipediaArticleImageURLs(
                for: lookup.resolvedTitle,
                excluding: primaryURL
            )
            if !extras.isEmpty {
                additionalImageURLs = extras
            }
        }
    }

    /// Renders one carousel slide with a stable frame regardless of
    /// load state. Wrapping the image in a fixed-size `Color`-backed
    /// ZStack prevents AsyncImage's empty/failure phases (which have
    /// no intrinsic size) from collapsing the slide and shifting the
    /// layout — the visible "jump" symptom on slow connections.
    @ViewBuilder
    private func slideView(_ slide: DetailImageSlide) -> some View {
        ZStack {
            Color.gray.opacity(0.08)
            switch slide.kind {
            case .local(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .clipped()
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
