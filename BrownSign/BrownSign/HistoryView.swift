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

/// Custom segmented selector that mirrors the textfield height (40pt)
/// and 12pt corner radius used across the rest of the UI. SwiftUI's
/// native `.pickerStyle(.segmented)` keeps its inner control at a fixed
/// ~32pt regardless of any outer `.frame(height:)`, so growing the
/// wrapper just adds padding above/below the segments. This rebuilds
/// the same two-option UX with full control over height and corners.
struct DisplayModeSegmentedPicker: View {
    @Binding var selection: LandmarkDisplayMode

    /// White in light mode, mid-dark grey in dark mode — chosen so the
    /// selected segment reads as visibly lighter than the outer
    /// `.tertiarySystemFill` in both modes. Pure `.systemBackground`
    /// reads correctly in light (white over light-grey) but inverts in
    /// dark (black sits darker than the surrounding fill instead of
    /// floating above it).
    private static let selectedSegmentFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGray3
            : UIColor.systemBackground
    })

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LandmarkDisplayMode.allCases) { mode in
                let isSelected = selection == mode
                Button {
                    if !isSelected {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection = mode
                        }
                    }
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Self.selectedSegmentFill : Color.clear)
                        .shadow(
                            color: isSelected ? .black.opacity(0.12) : .clear,
                            radius: 2, y: 1
                        )
                        .padding(2)
                )
            }
        }
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }
}

struct HistoryView: View {
    @Query(sort: \LandmarkLookup.date, order: .reverse)
    private var lookups: [LandmarkLookup]

    @Environment(\.modelContext) private var modelContext
    @State private var editMode: EditMode = .inactive
    @State private var showDeleteAllConfirmation = false
    @State private var displayMode: LandmarkDisplayMode = .list
    @State private var searchText: String = ""

    /// Lookups narrowed by the live search field. Partial, case-
    /// insensitive substring match against the resolved title.
    private var filteredLookups: [LandmarkLookup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return lookups }
        return lookups.filter { $0.resolvedTitle.lowercased().contains(q) }
    }


    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chrome above the list (picker, search field) hides in
                // edit mode — when the user is selecting rows to delete,
                // the browse/search controls are noise.
                if !lookups.isEmpty && !editMode.isEditing {
                    DisplayModeSegmentedPicker(selection: $displayMode)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // 16pt below the picker — matches the VStack(spacing: 16)
                    // gap between the "Snap a landmark sign" button and the
                    // text field on the Scan card.
                    SearchField(
                        text: $searchText,
                        placeholder: "Search history"
                    )
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 2)
                }

                Group {
                    if lookups.isEmpty {
                        // Mirror Scan's `howItWorksSteps` layout:
                        // brown signpost on the left, title + helper
                        // copy stacked on the right. Vertically
                        // centred in the remaining space so the
                        // overall emptiness still reads as "centred"
                        // even though the row itself is left-aligned.
                        VStack {
                            Spacer()
                            HStack(spacing: 16) {
                                Image(systemName: "signpost.right.and.left")
                                    .font(.system(size: 40, weight: .semibold))
                                    .foregroundStyle(Color("BrandBrown"))
                                    .frame(width: 54)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No lookups yet")
                                        .font(.title.weight(.bold))
                                    Text("Snap a landmark sign to get started.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch displayMode {
                        case .list:
                            if filteredLookups.isEmpty {
                                // Search yielded nothing — render the
                                // empty-state on its own instead of
                                // overlaying it on the List, which
                                // would centre the "No matches" copy
                                // right on top of the "Recently viewed
                                // landmarks" header row.
                                ContentUnavailableView(
                                    "No matches",
                                    systemImage: "magnifyingglass",
                                    description: Text("No saved lookups match \"\(searchText)\".")
                                )
                            } else {
                                // Header lives OUTSIDE the List so it
                                // doesn't steal the inset-grouped
                                // section's rounded top corners from
                                // the first landmark row. Inside the
                                // List with a clear background, the
                                // List still treats it as row 0 and
                                // applies the top-rounded corners
                                // there — making the first visible row
                                // look chopped. As a sibling above the
                                // List, we control its spacing with
                                // simple padding and the List's first
                                // row keeps its native rounded cap.
                                VStack(spacing: 0) {
                                    if !editMode.isEditing {
                                        HStack(spacing: 6) {
                                            Image(systemName: "clock.fill")
                                            Text("Recently viewed landmarks")
                                        }
                                        // Match the "Recent finds"
                                        // section header on Scan
                                        // (subheadline + semibold) so
                                        // the three list-section
                                        // labels read consistently
                                        // across tabs. Bottom padding
                                        // matches Scan's 8pt VStack
                                        // spacing between header and
                                        // list; top stays at 16 for
                                        // breathing room between the
                                        // search field above and the
                                        // section header.
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 16)
                                        .padding(.bottom, 8)
                                    }

                                    List {
                                        ForEach(Array(filteredLookups.enumerated()), id: \.element.id) { index, lookup in
                                            NavigationLink(value: lookup) {
                                                HistoryRow(lookup: lookup)
                                            }
                                            // Parchment lives per-row,
                                            // not on the whole list.
                                            // Only the first row gets
                                            // rounded top corners and
                                            // only the last row gets
                                            // rounded bottoms — the
                                            // visual "card" is
                                            // composed of abutted
                                            // rows, so the parchment
                                            // ends exactly with the
                                            // last row regardless of
                                            // how short the list is.
                                            .listRowBackground(
                                                UnevenRoundedRectangle(
                                                    cornerRadii: .init(
                                                        topLeading: index == 0 ? 12 : 0,
                                                        bottomLeading: index == filteredLookups.count - 1 ? 12 : 0,
                                                        bottomTrailing: index == filteredLookups.count - 1 ? 12 : 0,
                                                        topTrailing: index == 0 ? 12 : 0
                                                    )
                                                )
                                                .fill(Color("CardBackground"))
                                            )
                                            // 6pt top/bottom matches the Scan
                                            // recents card so the same
                                            // landmark row looks the same
                                            // size in both places — Sean
                                            // noticed History rows reading
                                            // taller because they were 8/8.
                                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                        }
                                        .onDelete(perform: deleteFilteredLookups)
                                    }
                                    // Plain style so rows extend
                                    // full-width within the padded
                                    // frame; inset-grouped doubles
                                    // up margins with .padding.
                                    .listStyle(.plain)
                                    .environment(\.editMode, $editMode)
                                    .scrollDismissesKeyboard(.immediately)
                                    // No list-level background — per-row
                                    // backgrounds carry the parchment so
                                    // it ends exactly at the last row.
                                    .scrollContentBackground(.hidden)
                                    // Round the viewport edges so the
                                    // top corners stay rounded as the
                                    // first row scrolls out of view.
                                    // Without this clip, the per-row
                                    // rounded corners leave the screen
                                    // with row 1 and the visible top
                                    // becomes square mid-scroll.
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    // Match the picker/search field's
                                    // horizontal margin so the list
                                    // lines up with the chrome above
                                    // it.
                                    .padding(.horizontal)
                                }
                                // Match the map case's bottom padding so
                                // the parchment list card sits the same
                                // distance above the tab bar as the map.
                                .padding(.bottom, 16)
                            }
                        case .map:
                            HistoryMapView(lookups: filteredLookups)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                                .padding(.top, 16)
                                .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LandmarkLookup.self) { lookup in
                LandmarkDetailView(lookup: lookup)
            }
            .toolbar {
                // Custom principal title — system inline title is
                // ~17pt; 21pt is ~25% larger as Sean asked for.
                ToolbarItem(placement: .principal) {
                    Text("History")
                        .font(.system(size: 21, weight: .semibold))
                }
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
            // Hide the tab bar while editing so the user is focused on
            // the row-selection workflow — matches Mail/Notes editing
            // UX. Also gate on `!lookups.isEmpty` so an empty list
            // always shows the tab bar: deleting the last row removes
            // the EditButton (gated on the same condition), and the
            // user has no other way to exit edit mode.
            .toolbar(
                (editMode.isEditing && !lookups.isEmpty) ? .hidden : .visible,
                for: .tabBar
            )
            .onChange(of: displayMode) { _, newMode in
                // Exiting edit mode cleanly when switching to map.
                if newMode == .map { editMode = .inactive }
            }
            .onChange(of: lookups.isEmpty) { _, isEmpty in
                // List drained (delete-all or swipe-delete-last) —
                // ensure editMode resets so the next session starts
                // clean.
                if isEmpty { editMode = .inactive }
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

    /// Swipe-delete handler for the displayed (filtered) list. Index
    /// offsets are relative to `filteredLookups`, not the full `lookups`
    /// query, so we resolve through the filtered array first.
    private func deleteFilteredLookups(at offsets: IndexSet) {
        let items = filteredLookups
        for index in offsets {
            modelContext.delete(items[index])
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
                            .tint(Color("BrandBrown"))
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
            RoundedRectangle(cornerRadius: 12)
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
                .tint(Color("BrandBrown"))
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
                .fill(Color("BrandBrown").opacity(0.18))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "signpost.right.fill")
                        .font(.title2)
                        .foregroundStyle(Color("BrandBrown").opacity(0.55))
                }
        }
    }
}

// MARK: - HistoryRow

struct HistoryRow: View {
    let lookup: LandmarkLookup
    /// Verb that prefaces the date on the row's caption line. Defaults
    /// to "Viewed" (History tab); Scan's recents preview passes
    /// "Found" so the same row reads as "this is when I scanned it".
    var datePrefix: String = "Viewed"

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
                Text("\(datePrefix) \(lookup.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        //   1. Persisted Wikipedia article image bytes (instant)
        //   2. AsyncImage from the article URL — covers the brief
        //      window after a Nearby tap where the lookup exists but
        //      its bytes are still downloading. The detail view just
        //      fetched the same URL, so NSURLCache typically returns
        //      it instantly and the row never flashes the placeholder.
        //   3. User's captured sign photo
        //   4. Brown signpost placeholder
        if let data = lookup.articleImageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let url = lookup.articleImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallbackThumbnail
                }
            }
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
                .fill(Color("BrandBrown").opacity(0.18))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "signpost.right.fill")
                        .font(.title2)
                        .foregroundStyle(Color("BrandBrown").opacity(0.55))
                }
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

    /// Slides assembled for the image carousel. Slot 0 is always
    /// reserved as `id: "primary"` whenever we know about an article
    /// image — either the persisted JPEG bytes (instant) or, while
    /// those are still downloading, the article-image URL rendered
    /// through `AsyncImage`. Reserving the slot with a stable id is
    /// what keeps the TabView from "jumping": when the Nearby flow
    /// opens the detail view, `additionalImageURLs` arrives before
    /// `articleImageData` finishes downloading, and without a
    /// pre-reserved primary slot the selection settles on the first
    /// extra and then snaps when the persistent bytes land.
    private var imageSlides: [DetailImageSlide] {
        var slides: [DetailImageSlide] = []
        if let data = lookup.articleImageData, let image = UIImage(data: data) {
            slides.append(DetailImageSlide(id: "primary", kind: .local(image)))
        } else if let urlString = lookup.articleImageURLString,
                  !urlString.isEmpty,
                  let url = URL(string: urlString) {
            slides.append(DetailImageSlide(id: "primary", kind: .remote(url)))
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

                metadataBlock

                if !lookup.rawSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.justify")
                            Text("Full description")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
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
                    .tint(Color("BrandBrown"))
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(lookup.pageURL == nil)

                    if let url = lookup.pageURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("BrandBrown"))
                        .buttonBorderShape(.roundedRectangle(radius: 12))
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
            HStack(spacing: 3) {
                Image(systemName: "leaf.fill")
                Text("NPS")
            }
            .font(.caption)
            .foregroundStyle(.green)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "globe")
                Text("Wikipedia")
            }
            .font(.caption)
            .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var metadataBlock: some View {
        // Source badge + saved date now live INSIDE the block, so
        // every detail view gets a metadata card (no more "if hasAny"
        // gating — even an entry with no Wikidata enrichment shows
        // its source and date in the parchment box).
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same warm parchment surface as the list rows and the
        // Scan recents card, so the detail view's metadata reads
        // as another card from the same family.
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color("CardBackground"))
        )
    }

}
