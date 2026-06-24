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

    /// One day's worth of History rows. A struct (not a tuple) so `ForEach`
    /// can identify it by `day` — key paths don't work on tuples.
    private struct DayGroup: Identifiable {
        let day: Date
        let header: String
        let items: [LandmarkLookup]
        var id: Date { day }
    }

    /// `filteredLookups` bucketed into day groups for the History list,
    /// newest day first — each with a relative header. `filteredLookups` is
    /// already date-descending, so one pass groups consecutive same-day items.
    private var groupedLookups: [DayGroup] {
        let cal = Calendar.current
        var groups: [(day: Date, items: [LandmarkLookup])] = []
        for lookup in filteredLookups {
            let day = cal.startOfDay(for: lookup.date)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1].items.append(lookup)
            } else {
                groups.append((day: day, items: [lookup]))
            }
        }
        return groups.map { DayGroup(day: $0.day, header: dayHeader(for: $0.day), items: $0.items) }
    }

    /// Relative day-group header: "Today" / "Yesterday", else "EEE, MMM d"
    /// ("Sun, Jun 21"), adding the year only when it isn't the current one.
    /// The header view displays it uppercased.
    private func dayHeader(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        return sameYear
            ? day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
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
                                // Day-grouped list: each day is its own
                                // parchment card under a relative header
                                // ("Today" / "Yesterday" / "Sun, Jun 21") with
                                // a hairline and a per-day count. Replaces the
                                // single "Recently viewed landmarks" header +
                                // flat list (and the per-row "Viewed <date>").
                                List {
                                    ForEach(groupedLookups) { group in
                                        // Header as a plain row on the dark
                                        // background (NOT a Section header,
                                        // which would pin on scroll), above the
                                        // day's card.
                                        dayHeaderRow(group)

                                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, lookup in
                                            NavigationLink(value: lookup) {
                                                HistoryRow(lookup: lookup)
                                            }
                                            // Per-DAY parchment card: rounded
                                            // top on the day's first row, rounded
                                            // bottom on its last, so each day
                                            // reads as its own card.
                                            .listRowBackground(
                                                UnevenRoundedRectangle(
                                                    cornerRadii: .init(
                                                        topLeading: index == 0 ? 12 : 0,
                                                        bottomLeading: index == group.items.count - 1 ? 12 : 0,
                                                        bottomTrailing: index == group.items.count - 1 ? 12 : 0,
                                                        topTrailing: index == 0 ? 12 : 0
                                                    )
                                                )
                                                .fill(Color("CardBackground"))
                                            )
                                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                        }
                                        // Delete by resolving the offset against
                                        // THIS day's items (object identity) —
                                        // per-section IndexSet offsets are NOT
                                        // valid against the flat list, so a flat
                                        // delete here would remove the wrong row.
                                        .onDelete { deleteItems(group.items, at: $0) }
                                    }
                                }
                                .listStyle(.plain)
                                .environment(\.editMode, $editMode)
                                .scrollDismissesKeyboard(.immediately)
                                // No list-level background — per-row backgrounds
                                // carry the parchment so each day's card ends
                                // exactly at its last row.
                                .scrollContentBackground(.hidden)
                                // Match the picker/search field's horizontal
                                // margin so the cards line up with the chrome.
                                .padding(.horizontal)
                                // Match the map case's bottom padding so the
                                // list sits the same distance above the tab bar.
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

    /// Day-group header row: relative label + hairline + per-day count, on the
    /// dark background above the day's card. A plain row (NOT a Section header,
    /// which would pin on scroll) that can't be selected or swiped away.
    @ViewBuilder
    private func dayHeaderRow(_ group: DayGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.header)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            Text("\(group.items.count)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 18, leading: 6, bottom: 6, trailing: 6))
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .deleteDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.header), \(group.items.count) finds")
    }

    /// Swipe/Edit delete handler resolved against a SPECIFIC day's items by
    /// object identity. The IndexSet offsets are relative to that day's rows,
    /// not the flat list — indexing the flat list here would delete the wrong
    /// finds (silent data loss).
    private func deleteItems(_ items: [LandmarkLookup], at offsets: IndexSet) {
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

    @State private var selectedID: String?
    @State private var recenterToken = 0

    private var mapped: [LandmarkLookup] {
        lookups.filter { $0.hasCoordinates }
    }

    private var annotations: [LandmarkAnnotation] {
        mapped.compactMap { lookup in
            guard let lat = lookup.latitude, let lon = lookup.longitude else { return nil }
            return LandmarkAnnotation(
                id: lookup.id.uuidString,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                title: lookup.resolvedTitle
            )
        }
    }

    private var selectedLookup: LandmarkLookup? {
        guard let id = selectedID else { return nil }
        return mapped.first { $0.id.uuidString == id }
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
                // Clustered MKMapView (brown numbered bubbles; tap a cluster to
                // zoom into its members). No pan-refetch — History just browses
                // saved finds — so no onUserPan.
                ClusteredMapView(
                    annotations: annotations,
                    selectedID: $selectedID,
                    initialRegion: regionFittingAll(mapped),
                    recenterToken: recenterToken,
                    recenterRegion: regionFittingAll(mapped),
                    // "Locate me" fits all saved pins.
                    recenterTarget: regionFittingAll(mapped)
                )
                .onChange(of: mapped.count) { _, _ in
                    // Re-fit when the set changes (search filter, deletes).
                    recenterToken += 1
                }

                if let selected = selectedLookup {
                    SelectedLookupCard(lookup: selected, onDismiss: {
                        selectedID = nil
                    })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedID)
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
                .tint(Color("AccentButton"))
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(lookup.resolvedTitle)
                    .font(.headline)
                    .lineLimit(1)
                // No per-row date now — the day-group header carries it,
                // freeing the summary's full two lines.
                Text(lookup.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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

    /// Street-level Look Around scene at the landmark's coordinates.
    /// Stays nil when the lookup has no coordinates or Apple has no
    /// coverage there (common for rural brown-sign territory — and
    /// "no coverage" is a nil scene on success, not an error); the
    /// section hides entirely in both cases.
    @State private var lookAroundScene: MKLookAroundScene?

    /// Badge-free static image of `lookAroundScene`, layered over
    /// the live preview as the tile's visible face (the preview's
    /// binoculars badge has no API to hide it). Nil = the live
    /// preview shows through, badge and all — a graceful fallback.
    @State private var lookAroundSnapshot: UIImage?

    /// The live preview (the tap target under the snapshot) mounts
    /// only AFTER the tile's fade-in completes: opacity-fading the
    /// stack doesn't group-composite the hosted preview, so its
    /// badge bled through the half-transparent snapshot mid-fade.
    @State private var lookAroundPreviewMounted = false

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

                if !lookup.rawSignText.isEmpty {
                    Text("Original sign: \(lookup.rawSignText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        // The action buttons live in a pinned bottom bar, NOT inline in
        // the scroll content. Inline, they scrolled up under the floating
        // tab bar on the History push path and clipped (the reported bug).
        // safeAreaInset floats them above the tab bar and reserves matching
        // bottom space so nothing in the scroll content hides behind them.
        .safeAreaInset(edge: .bottom) {
            detailActionBar
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
        // Keyed on the coordinate values, not the lookup: coords can
        // arrive AFTER the view opens (staged Wikidata enrichment
        // with preserve-on-nil upsert), and the re-keyed task is what
        // picks them up.
        .task(id: "\(lookup.latitude ?? .nan),\(lookup.longitude ?? .nan)") {
            guard let lat = lookup.latitude, let lon = lookup.longitude else { return }
            guard let scene = try? await MKLookAroundSceneRequest(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
            ).scene else { return }
            let options = MKLookAroundSnapshotter.Options()
            options.size = CGSize(width: 104, height: 104)
            let snapshot = try? await MKLookAroundSnapshotter(
                scene: scene, options: options
            ).snapshot.image
            // Publish together AFTER the snapshot resolves: setting
            // the scene first renders the live preview's badge for a
            // beat before the clean snapshot lands over it.
            withAnimation(.easeIn(duration: 0.5)) {
                lookAroundSnapshot = snapshot
                lookAroundScene = scene
            }
            if snapshot == nil {
                // No clean face to hide behind; show the badged
                // preview immediately rather than an empty tile.
                lookAroundPreviewMounted = true
            } else {
                // Slot the tap target in only once the fade is done
                // (it's fully covered by the snapshot, so the swap
                // is invisible).
                try? await Task.sleep(for: .milliseconds(650))
                lookAroundPreviewMounted = true
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

    /// The pinned action bar shown by `safeAreaInset(edge: .bottom)`: a
    /// full-width green "Read full article" CTA plus a 48pt outlined share,
    /// on a frosted `.bar` with a top hairline — the same house treatment
    /// as the Scan "Look it up" bar. The primary action is green
    /// (AccentButton) now, not brown, per the redesign's "green = actions".
    @ViewBuilder
    private var detailActionBar: some View {
        HStack(spacing: 10) {
            Button {
                showSafari = true
            } label: {
                Label("Read full article", systemImage: "safari")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("AccentButton"))
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(lookup.pageURL == nil)

            if let url = lookup.pageURL {
                // Outlined (not filled) so it reads as secondary against the
                // green primary; tinted green so the stroke + glyph match.
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 48, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(Color("AccentButton"))
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        // Same 16pt gap-above-tab-bar the Scan bar uses; kept inside .bar
        // so the frosted material stays flush with the tab bar.
        .padding(.bottom, 16)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

    /// How many rows the metadata text column renders — drives the Look Around
    /// tile height so it doesn't overflow a short card.
    private var metadataRowCount: Int {
        var n = 1  // source badge + saved date
        if (lookup.onDeviceMatchScore ?? 1) < LowConfidenceMatchNote.threshold { n += 1 }
        if lookup.latitude != nil && lookup.longitude != nil { n += 2 }  // coordinates + Directions
        if lookup.inceptionYear != nil { n += 1 }
        if lookup.wikidataType != nil { n += 1 }
        return n
    }

    /// Look Around tile height for the current metadata row count: full size on
    /// a tall card, smaller on a short one so it keeps a comfortable gap to the
    /// card edges either way.
    private var lookAroundTileHeight: CGFloat {
        switch metadataRowCount {
        case 5...: return 104
        case 4: return 88
        default: return 72
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
                // Lat/long stays: tried hiding it (1.9.0 design
                // pass), but the shorter text column read oddly
                // against the Look Around tile.
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
                            // Blue by Sean's call: it's a link, keep it
                            // looking like one.
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                if let year = lookup.inceptionYear {
                    // Negative = BCE (parseClaimYear preserves the sign).
                    Label(year < 0 ? "Est. \(String(-year)) BC" : "Est. \(String(year))",
                          systemImage: "calendar")
                        .font(.caption)
                        // VoiceOver reads the bare "Est." abbreviation oddly.
                        .accessibilityLabel(year < 0
                            ? "Established \(String(-year)) BC"
                            : "Established \(String(year))")
                }
            if let type = lookup.wikidataType {
                Label(type, systemImage: "tag.fill")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The text column ALONE defines the card height: the Look
        // Around tile is an overlay capped to that height, so its
        // async fade-in can never stretch the card. The trailing
        // padding reserves the tile's footprint while it's visible
        // (the metadata rows are short enough not to re-wrap).
        .padding(.trailing, lookAroundScene != nil ? 116 : 0)
        .overlay(alignment: .trailing) {
            // Street-level Look Around teaser, only where Apple has
            // imagery at the landmark. Tap opens the full-screen
            // viewer. Thumbnail-class tile, so 10pt radius per the
            // rows-12/thumbnails-10 ruling.
            if let scene = lookAroundScene {
                ZStack {
                    // The live preview is the tap target (native
                    // full-screen expansion + chrome), but its
                    // binoculars badge can't be hidden at any
                    // size — so a badge-free static snapshot of
                    // the same scene sits on top as the visible
                    // tile, and taps pass through it.
                    if lookAroundPreviewMounted {
                        LookAroundPreview(initialScene: scene)
                    }
                    if let snapshot = lookAroundSnapshot {
                        Image(uiImage: snapshot)
                            .resizable()
                            .scaledToFill()
                            .allowsHitTesting(false)
                    }
                }
                // Height keyed to the number of metadata rows (deterministic,
                // unlike measuring the column in an overlay): a full 104 on a
                // 5+-row card, shorter on a 4-row card so it doesn't overflow
                // and touch the card's top/bottom edges.
                .frame(width: 104, height: lookAroundTileHeight)
                // "Look Around" is Apple's feature name, so it
                // keeps its capitals even in sentence-case land.
                // Frosted-capsule label, the system's own badge
                // treatment, so it reads over any street scene.
                .overlay(alignment: .bottom) {
                    Text("Look Around")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        // 6pt, not the tile's nominal 10: at this
                        // chip height 10 would clamp to a full
                        // capsule; 6 is what reads as the same
                        // corner language as the tile.
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Arrives async (scene + snapshot fetch), so fade in
                // like the list thumbnails do — a hard pop-in reads
                // as a glitch. The insertion is animated from the
                // withAnimation in the fetch task.
                .transition(.opacity)
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
