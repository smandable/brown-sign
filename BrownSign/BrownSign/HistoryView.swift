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
//
// `LandmarkDisplayMode` and `DisplayModeSegmentedPicker` are shared with
// the Nearby tab and now live in Components.swift.

struct HistoryView: View {
    @Query(sort: \LandmarkLookup.date, order: .reverse)
    private var lookups: [LandmarkLookup]

    @Environment(\.modelContext) private var modelContext
    @State private var editMode: EditMode = .inactive
    @State private var showDeleteAllConfirmation = false
    @State private var displayMode: LandmarkDisplayMode = .list
    @State private var searchText: String = ""

    /// Lookups narrowed by the live search field. Partial substring match
    /// against the resolved title via localizedStandardContains — the
    /// system-recommended user-search comparison (case-, diacritic-, and
    /// width-insensitive), so typing "chateau" matches "Château".
    private var filteredLookups: [LandmarkLookup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return lookups }
        return lookups.filter { $0.resolvedTitle.localizedStandardContains(q) }
    }


    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chrome above the list (picker, search field). Shown
                // even when History is empty so the List/Map switcher
                // and search stay available before the first lookup —
                // Map then shows where you are, mirroring how Nearby
                // keeps its switcher live in the empty state. Only
                // hidden in edit mode (row-selection makes browse/search
                // controls noise); edit mode is unreachable while empty
                // anyway since EditButton is gated on a non-empty list.
                if !editMode.isEditing {
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
                        // No saved lookups yet. List mode explains how to
                        // start; Map mode shows where the user is, so the
                        // List/Map switcher stays meaningful before the
                        // first lookup — mirroring how Nearby keeps its
                        // switcher live in the empty state.
                        switch displayMode {
                        case .list:
                            emptyHistoryView
                        case .map:
                            EmptyHistoryMapView()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                                .padding(.top, 16)
                                .padding(.bottom, 16)
                        }
                    } else {
                        switch displayMode {
                        case .list:
                            if filteredLookups.isEmpty {
                                // Search yielded nothing — render the
                                // empty-state on its own instead of
                                // overlaying it on the List, which
                                // would centre the "No results" copy
                                // right on top of the "Recently viewed
                                // landmarks" header row. "No results"
                                // (not "No matches") and "finds" (not
                                // "lookups"): the same terms Nearby's
                                // empty search and Scan's section header
                                // use for the identical interaction.
                                BrandEmptyState(
                                    systemImage: "magnifyingglass",
                                    title: "No results",
                                    message: "No saved finds match \"\(searchText)\"."
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
                // ^[…](inflect: true) grammar-agrees the noun phrase with
                // the count, so one entry reads "all 1 saved find", not
                // "all 1 saved lookups". "Finds" matches Scan's term.
                Text("This will remove ^[all \(lookups.count) saved finds](inflect: true). This cannot be undone.")
            }
        }
    }

    /// Empty-state shown in List mode when there are no saved lookups —
    /// brown signpost + helper copy, mirroring Scan's `howItWorksSteps`
    /// layout (signpost left, title + helper copy stacked right,
    /// vertically centred so the emptiness still reads as "centred").
    /// Map mode shows `EmptyHistoryMapView` instead (a map of where the
    /// user is) so the List/Map switcher stays meaningful even before
    /// the first lookup is saved.
    private var emptyHistoryView: some View {
        // Shared house-style empty state (see BrandEmptyState) — the same
        // layout Nearby's empty/offline states now use, so the two tabs read
        // identically.
        BrandEmptyState(
            systemImage: "signpost.right.and.left",
            title: "No finds yet",
            message: "Snap a landmark sign to get started."
        )
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

// MARK: - EmptyHistoryMapView

/// Map shown on the History tab's Map toggle when there are no saved
/// lookups yet. Centres on the user at a ~5-mile radius (mirroring the
/// Nearby tab's "within 5 miles" framing) so the empty Map view shows
/// where you are rather than a blank panel. Uses the shared
/// `LocationManager` (same instance as Nearby/Scan, so its cache +
/// interim-fix seed make the fix near-instant when warm); falls back to
/// a continental-US default if location is denied or unavailable.
private struct EmptyHistoryMapView: View {
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(continentalUSRegion)
    )
    private let locationManager = LocationManager.shared

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .task {
            // `.userLocation` already centres on the dot at MapKit's
            // default zoom the moment a fix is available; refine that to
            // a ~5-mile radius. Keeps the US-default fallback the camera
            // started with if location is denied/unavailable.
            guard await locationManager.ensurePermission(),
                  let loc = await locationManager.currentLocation(
                      withTimeout: LocationManager.nearbyTimeout
                  ) else { return }
            cameraPosition = .region(MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 16_093,   // ~5-mile radius (10 mi across)
                longitudinalMeters: 16_093
            ))
        }
        // Liquid Glass tab bars are translucent; force a visible
        // background so map tiles don't show through (matches
        // HistoryMapView / NearbyMapView).
        .toolbarBackground(.visible, for: .tabBar)
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
            BrandEmptyState(
                systemImage: "mappin.slash",
                title: "No mapped landmarks",
                message: "Finds with coordinates will appear here on a map."
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
                            // Plain BrandBrown by Sean's call (see the Nearby
                            // map's Marker for the dark-mode trade-off note).
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
        return fittingRegion(for: coords, singlePointSpan: 0.05, padding: 1.4)
    }
}

/// Compact summary card shown over the map when a pin is selected.
/// The whole card body is a NavigationLink to the detail view; the X
/// is a sibling button so dismissing the card doesn't also navigate.
private struct SelectedLookupCard: View {
    let lookup: LandmarkLookup
    let onDismiss: () -> Void

    var body: some View {
        MapCalloutCard(
            title: lookup.resolvedTitle,
            summary: lookup.summary,
            articleImageData: lookup.articleImageData,
            articleImageURL: lookup.articleImageURL,
            capturedImageData: lookup.imageData,
            onDismiss: onDismiss,
            detail: {
                NavigationLink(value: lookup) {
                    Label("View details", systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandBrown"))
                .controlSize(.small)
                .buttonBorderShape(.roundedRectangle(radius: 8))
            },
            wrap: { content in
                NavigationLink(value: lookup) { content }
            }
        )
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
            // Fill in summaries for legacy rows as they appear (logic
            // lives in LandmarkLookup.backfillSummaryIfNeeded).
            await lookup.backfillSummaryIfNeeded()
        }
    }

    // Preference order: persisted article-image bytes (instant) →
    // article-image URL (covers the brief window after a Nearby tap
    // where the lookup exists but its bytes are still downloading;
    // NSURLCache usually returns it instantly) → the user's captured
    // sign photo → brown-signpost placeholder. See `LandmarkThumbnail`.
    private var thumbnail: some View {
        LandmarkThumbnail(
            articleImageData: lookup.articleImageData,
            articleImageURL: lookup.articleImageURL,
            capturedImageData: lookup.imageData
        )
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
                    // Keyed on the full id list rather than `.count`
                    // so future code paths that replace slides with the
                    // same count still trigger the validity check.
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
            // isSafariPresentableURL: SFSafariViewController crashes on
            // non-http(s) schemes, and pageURL comes from remote data.
            if let url = lookup.pageURL, isSafariPresentableURL(url) {
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
            // Safety-net backfill in case the row's task was cancelled
            // mid-fetch (scrolled off) before the user tapped through.
            await lookup.backfillSummaryIfNeeded()
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
            if (lookup.onDeviceMatchScore ?? 1) < LowConfidenceMatchNote.threshold {
                LowConfidenceMatchNote()
            }
            if let lat = lookup.latitude, let lon = lookup.longitude {
                Label(String(format: "%.4f, %.4f", lat, lon),
                      systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .accessibilityLabel("Map coordinates")
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
                // Negative = BCE (parseClaimYear preserves the sign).
                Label(year < 0 ? "Est. \(String(-year)) BC" : "Est. \(String(year))",
                      systemImage: "calendar")
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
