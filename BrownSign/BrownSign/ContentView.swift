//
//  ContentView.swift
//  BrownSign
//
//  Main scan tab: capture a photo (or type), OCR + Apple Intelligence
//  normalize, run searchLandmark, show a result card with a "View full
//  details" sheet and a "Read full article" Safari sheet.
//

import SwiftUI
import SwiftData
import UIKit
import CoreLocation
import StoreKit

struct ContentView: View {
    @State private var signText = ""
    @State private var showCamera = false
    @State private var capturedImage: UIImage?
    @State private var isProcessing = false
    @State private var isSearching = false
    @State private var result: LandmarkResult?
    @State private var savedLookup: LandmarkLookup?
    @State private var candidates: [LandmarkResult] = []
    @State private var showSafari = false
    /// Drives the detail sheet. Using an optional LandmarkLookup with
    /// `.sheet(item:)` instead of a separate `isPresented` + optional
    /// pair avoids the race where the sheet was sometimes evaluated
    /// before `savedLookup` had propagated, producing a blank sheet.
    @State private var presentedLookup: LandmarkLookup?
    @State private var showMapsDialog = false
    @State private var statusMessage = ""

    /// Cached decoded UIImage for the current result's article image.
    /// Prevents re-decoding the JPEG on every view re-render.
    @State private var resultArticleImage: UIImage?

    @State private var isSignTextFocused = false

    /// Per-session dismiss for the "Turn on location" banner. Flips back
    /// to false every cold launch, so a user who taps the X still sees
    /// it next time they open the app — but we don't nag them during
    /// the current session.
    @State private var locationBannerDismissed = false

    // Review prompt: count successful lookups, request a rating
    // after the user has had a few good experiences with the app.
    @AppStorage("successfulLookupCount") private var successfulLookupCount = 0

    private let locationManager = LocationManager.shared

    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    /// Recent lookups for the empty-state "Recent finds" preview.
    /// Same sort order as HistoryView, so the top rows match.
    @Query(sort: \LandmarkLookup.date, order: .reverse)
    private var recentLookups: [LandmarkLookup]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        // Brown sign hero anchored at the top whenever
                        // we're in a "fresh" state (no result, not
                        // mid-search). Disappears once a result lands
                        // so the result card has the full viewport.
                        if result == nil && !isSearching {
                            brownSignHero
                        }

                        if let image = capturedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: 180)
                                .clipped()
                                .contentShape(Rectangle())
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        capturedImage = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            // Dual-tone (white glyph
                                            // over translucent black
                                            // disc) stays legible over
                                            // any captured background.
                                            .foregroundStyle(
                                                .white,
                                                .black.opacity(0.55)
                                            )
                                            .padding(8)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove photo")
                                }
                        }

                        Button {
                            showCamera = true
                        } label: {
                            Label("Snap a landmark sign", systemImage: "camera.fill")
                                .fontWeight(.regular)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 0))

                        HStack(spacing: 8) {
                            LandmarkTextField(
                                text: $signText,
                                isFocused: $isSignTextFocused,
                                onSearch: { Task { await lookUp() } }
                            )
                            .frame(minHeight: 28)

                            if !signText.isEmpty {
                                Button {
                                    clearSearch()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.secondarySystemBackground))
                                .onTapGesture { isSignTextFocused = true }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    isSignTextFocused
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.35),
                                    lineWidth: isSignTextFocused ? 2 : 1
                                )
                        )
                        .id("textField")

                        if locationManager.isDenied && !locationBannerDismissed {
                            locationDeniedBanner
                        }

                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let result {
                            resultCard(for: result)
                                .id("resultCard")
                            alternativesSection
                        } else if !isSearching {
                            // Hero moved to the top of the VStack;
                            // the empty-state body is just the
                            // how-it-works guide or recent-finds list.
                            VStack(spacing: 20) {
                                if recentLookups.isEmpty {
                                    howItWorksSteps
                                } else {
                                    recentFindsSection
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Brown Sign — snap a sign or type to look up a landmark")
                        }
                    }
                    .padding()
                }
                .onChange(of: result?.pageURL) { _, _ in
                    guard result != nil else { return }
                    proxy.scrollTo("textField", anchor: .top)
                }
                .onChange(of: result?.articleImageData) { _, newData in
                    // Decode the JPEG bytes once when the result's
                    // image data changes, then reuse the UIImage across
                    // all re-renders of the result card.
                    if let data = newData {
                        resultArticleImage = UIImage(data: data)
                    } else {
                        resultArticleImage = nil
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.38, green: 0.24, blue: 0.10).opacity(0.12), location: 0),
                        .init(color: Color.brown.opacity(0.04), location: 0.35),
                        .init(color: Color.clear, location: 0.7)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) {
                let lookUpDisabled = signText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isProcessing
                    || isSearching
                Button {
                    guard !lookUpDisabled else { return }
                    Task { await lookUp() }
                } label: {
                    Label("Look It Up", systemImage: "magnifyingglass")
                        .fontWeight(.regular)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 0))
                .opacity(lookUpDisabled ? 0.5 : 1)
                .accessibilityHint(lookUpDisabled ? "Enter text to search" : "")
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            // Keyboard toolbar is built into LandmarkTextField's
            // inputAccessoryView (dismiss ⌨↓ + search 🔍).
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(
                    onCapture: { image in
                        // Downscale immediately so we don't hold a
                        // full-resolution ~48MP iPhone photo in memory.
                        // OCR still works great at 800px on the long edge.
                        let scaled = resized(image, toMaxDimension: 800)
                        capturedImage = scaled
                        showCamera = false
                        Task { await processImage(scaled) }
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSafari) {
                if let url = result?.pageURL {
                    SafariView(url: url)
                }
            }
            .task {
                // Prime location permission + initial fix so the very
                // first search already has geographic context.
                _ = await locationManager.currentLocation()
            }
            .sheet(isPresented: $showMapsDialog) {
                if let coord = result?.coordinates {
                    DirectionsSheet(
                        latitude: coord.latitude,
                        longitude: coord.longitude,
                        name: result?.title ?? ""
                    )
                }
            }
            .sheet(item: $presentedLookup) { lookup in
                NavigationStack {
                    LandmarkDetailView(lookup: lookup)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { presentedLookup = nil }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Location denied banner

    /// Inline callout shown on the Scan tab when the user has denied
    /// location access. Location is a silent quality booster here
    /// (nearby-first ranking, 10 km geosearch, distance labels) so
    /// without a visible nudge, users simply get worse results and
    /// never know why. Dismissable per-session via the small X.
    private var locationDeniedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.slash.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn on location")
                    .font(.footnote.weight(.semibold))
                Text("Get nearby-first results and discover landmarks around you in the Nearby tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    LocationManager.openAppSettings()
                } label: {
                    Text("Open Settings")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button {
                locationBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss location tip")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Empty state

    /// Stylized brown road-sign illustration — echoes the real-world
    /// UK/US tourist-attraction sign that gives the app its name.
    /// Purely decorative; hidden from VoiceOver since the container
    /// carries the accessibility label.
    private var brownSignHero: some View {
        let signBrown = Color(red: 0.38, green: 0.24, blue: 0.10)
        return ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(signBrown)
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white, lineWidth: 2)
                .padding(6)
            VStack(spacing: 8) {
                Image(systemName: "signpost.right.and.left.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                Text("BROWN SIGN")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .accessibilityHidden(true)
    }

    /// Three-step "how it works" guide shown on first launch (when
    /// the user has no saved lookups). Compact so it doesn't push
    /// the Look It Up bar off small screens.
    private var howItWorksSteps: some View {
        let brown = Color(red: 0.38, green: 0.24, blue: 0.10)
        let steps: [(String, String, String)] = [
            ("camera.fill", "Snap", "Point your camera at any landmark sign"),
            ("sparkles", "Identify", "We look up the landmark for you"),
            ("bookmark.fill", "Save", "History keeps every find")
        ]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(steps, id: \.0) { icon, title, detail in
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(brown)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Last 3 saved lookups, shown on the empty state once the user
    /// has history. Tapping a row opens the same LandmarkDetailView
    /// sheet used by the result card's "View full details" button.
    private var recentFindsSection: some View {
        let rows = Array(recentLookups.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent finds")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            // Embedding a List inside the outer ScrollView so we get the
            // native iOS swipe-to-delete gesture — .swipeActions only
            // works on List. scrollDisabled passes the scroll through to
            // the parent; the fixed frame height is needed because List
            // doesn't self-size inside a ScrollView.
            List {
                ForEach(rows) { lookup in
                    Button {
                        // Drive the sheet via a single optional binding
                        // rather than (savedLookup=…, flag=true). The
                        // flag-plus-optional pair race produced blank
                        // sheets when the sheet body evaluated before
                        // the second state update had propagated.
                        presentedLookup = lookup
                    } label: {
                        HStack(spacing: 8) {
                            HistoryRow(lookup: lookup)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            modelContext.delete(lookup)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparatorTint(Color.secondary.opacity(0.2))
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(rows.count) * 92)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Result card

    @ViewBuilder
    private func resultCard(for result: LandmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = resultArticleImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .clipped()
                    .contentShape(Rectangle())
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let imageURL = result.articleImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Color.secondary.opacity(0.15)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    case .empty:
                        Color.secondary.opacity(0.1)
                            .overlay { ProgressView() }
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 200)
                .clipped()
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            SelectableText(
                text: result.title,
                font: .preferredFont(forTextStyle: .title2).bold()
            )

            metadataChips(for: result)

            // Tap anywhere on the polished summary to open full details
            // — same action as the "View full details" button below.
            // Trades the UITextView's tap-to-place-cursor selection for
            // a larger tap target; full-text selection still available
            // on the detail view.
            SelectableText(
                text: result.summary,
                lineLimit: 6
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if savedLookup != nil {
                    presentedLookup = savedLookup
                }
            }

            VStack(spacing: 8) {
                Button {
                    presentedLookup = savedLookup
                } label: {
                    Label("View full details", systemImage: "text.alignleft")
                        .fontWeight(.regular)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                .buttonBorderShape(.roundedRectangle(radius: 0))
                .disabled(savedLookup == nil)

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
                    .disabled(result.pageURL.absoluteString.isEmpty)

                    ShareLink(item: result.pageURL,
                              subject: Text(result.title),
                              message: Text(result.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.38, green: 0.24, blue: 0.10))
                    .buttonBorderShape(.roundedRectangle(radius: 0))
                }
            }
        }
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.1))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        )
    }

    /// Alternatives panel — shown below the result card when there's
    /// more than one plausible match.
    @ViewBuilder
    private var alternativesSection: some View {
        let others = candidates.filter { $0.pageURL != result?.pageURL }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other matches")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.offset) { idx, alt in
                        Button {
                            switchTo(alt)
                        } label: {
                            alternativeRow(alt)
                        }
                        .buttonStyle(.plain)
                        if idx < others.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
        }
    }

    @ViewBuilder
    private func alternativeRow(_ alt: LandmarkResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = alt.articleImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipped()
                    .contentShape(Rectangle())
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let imageURL = alt.articleImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 44, height: 44)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.brown.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "signpost.right.fill")
                            .foregroundStyle(.brown)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(alt.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let type = alt.wikidataType {
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let coord = alt.coordinates,
                       let user = locationManager.lastLocation {
                        let d = user.distance(from: CLLocation(
                            latitude: coord.latitude,
                            longitude: coord.longitude
                        ))
                        Text(formatDistance(d))
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
        .padding(10)
        .contentShape(Rectangle())
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        // Use imperial for US-style locales, metric elsewhere.
        let usesMetric = Locale.current.measurementSystem == .metric
        if usesMetric {
            if meters < 1_000 {
                return "\(Int(meters)) m"
            }
            return String(format: "%.1f km", meters / 1_000)
        } else {
            let miles = meters / 1609.344
            if miles < 0.1 {
                let feet = meters / 0.3048
                return "\(Int(feet)) ft"
            }
            if miles < 10 {
                return String(format: "%.1f mi", miles)
            }
            return "\(Int(miles)) mi"
        }
    }

    @ViewBuilder
    private func metadataChips(for result: LandmarkResult) -> some View {
        let hasAny = result.coordinates != nil
            || result.inceptionYear != nil
            || result.wikidataType != nil

        if hasAny {
            VStack(alignment: .leading, spacing: 4) {
                if let coord = result.coordinates {
                    Label(String(format: "%.4f, %.4f", coord.latitude, coord.longitude),
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
                if let year = result.inceptionYear {
                    Label("Est. \(String(year))", systemImage: "calendar")
                        .font(.caption)
                }
                if let type = result.wikidataType {
                    Label(type, systemImage: "tag.fill")
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Pipeline

    private func processImage(_ image: UIImage) async {
        isProcessing = true
        statusMessage = "Reading sign…"
        let lines = await recognizeText(from: image)
        statusMessage = "Identifying landmark…"
        let normalized = await normalizeLandmarkName(fromLines: lines)
        signText = normalized
        statusMessage = ""
        isProcessing = false
    }

    private func lookUp() async {
        // Dismiss keyboard via UIKit responder chain — NOT via the
        // isFocused binding, which would trigger updateUIView to call
        // resignFirstResponder repeatedly during the search's rapid
        // state changes and leave the text field in a stuck state.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        isSearching = true
        statusMessage = "Searching…"
        result = nil
        savedLookup = nil
        candidates = []

        let trimmed = signText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Get the best location we can in up to 3 seconds. The inflight
        // guard in LocationManager means concurrent callers share one
        // fetch, so this composes safely with the .task priming.
        let userLocation = await locationManager.currentLocation(withTimeout: 3)

        // Phase 1: candidate list (fast — Wikipedia + Wikidata only).
        let found = await searchLandmarkCandidates(
            query: trimmed,
            userLocation: userLocation
        )
        candidates = found

        guard let first = found.first else {
            statusMessage = "No results"
            isSearching = false
            return
        }

        // Show the top candidate's raw card immediately. Save the
        // unpolished lookup to SwiftData synchronously so the
        // "View full details" button is enabled from the first frame
        // (otherwise it flashes disabled → enabled when enrichment
        // completes). Enrichment then runs in a detached Task to keep
        // the view immediately interactive.
        result = first
        statusMessage = ""
        isSearching = false
        let thumb: Data? = capturedImage.flatMap { image -> Data? in
            resized(image, to: CGSize(width: 112, height: 112))
                .jpegData(compressionQuality: 0.7)
        }
        savedLookup = upsertLookup(result: first, rawSignText: trimmed, newThumb: thumb)
        maybeRequestReview()
        Task { await selectCandidate(first, query: trimmed) }
    }

    /// Prompts for an App Store rating after the user has had a few
    /// successful lookups. Apple throttles review requests to at most
    /// 3 per year per user, so calling this more often than that is
    /// fine — the system simply ignores extra calls. We also skip the
    /// first few lookups to avoid prompting during initial exploration.
    private func maybeRequestReview() {
        successfulLookupCount += 1
        // Ask after the 3rd, 10th, and 25th successful lookup.
        // Apple's own heuristics decide whether to actually show.
        let triggers: Set<Int> = [3, 10, 25]
        if triggers.contains(successfulLookupCount) {
            requestReview()
        }
    }

    /// Run phase-2 enrichment for the given candidate, replace the
    /// current `result` with the enriched version, and upsert it into
    /// SwiftData history. Used both from initial lookup and from tapping
    /// an alternative in the "Other matches" list.
    private func selectCandidate(_ candidate: LandmarkResult, query: String) async {
        // Caller (lookUp or switchTo) has already set `result` and
        // performed the initial upsert so the card + button are
        // interactive immediately. This function just enriches and
        // re-upserts with the enriched data.
        let enriched = await enrichLandmark(candidate, query: query)
        if result?.pageURL == candidate.pageURL {
            result = enriched
        }
        let thumb: Data? = capturedImage.flatMap { image -> Data? in
            resized(image, to: CGSize(width: 112, height: 112))
                .jpegData(compressionQuality: 0.7)
        }
        let saved = upsertLookup(result: enriched, rawSignText: query, newThumb: thumb)
        if result?.pageURL == enriched.pageURL {
            savedLookup = saved
        }
    }

    /// Reset the search field and any visible result/alternatives so
    /// the user can start a fresh query without backspacing. Leaves
    /// the captured photo alone — if the user wants a new one they
    /// can tap Snap a Sign again.
    private func clearSearch() {
        signText = ""
        result = nil
        savedLookup = nil
        candidates = []
        statusMessage = ""
        capturedImage = nil
    }

    /// Called when the user taps an alternative in the "Other matches"
    /// list on the result card.
    private func switchTo(_ alt: LandmarkResult) {
        // Show the alternative immediately (with its raw summary) and
        // save the unpolished lookup synchronously so "View full
        // details" is enabled from the first frame.
        result = alt
        statusMessage = ""
        let trimmed = signText.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb: Data? = capturedImage.flatMap { image -> Data? in
            resized(image, to: CGSize(width: 112, height: 112))
                .jpegData(compressionQuality: 0.7)
        }
        savedLookup = upsertLookup(result: alt, rawSignText: trimmed, newThumb: thumb)
        Task { await selectCandidate(alt, query: trimmed) }
    }

    // MARK: - Dedupe + upsert

    /// Inserts a new `LandmarkLookup` or updates an existing one keyed on
    /// `pageURLString`. Updating bumps `date` so the row moves back to the
    /// top of the history list. Refreshes the summary/metadata/enrichment
    /// fields to the newest values, but preserves any previously-saved
    /// captured photo if the new search didn't have one.
    private func upsertLookup(
        result res: LandmarkResult,
        rawSignText: String,
        newThumb: Data?
    ) -> LandmarkLookup {
        let key = res.pageURL.absoluteString
        let descriptor = FetchDescriptor<LandmarkLookup>(
            predicate: #Predicate { $0.pageURLString == key }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.rawSignText = rawSignText
            existing.resolvedTitle = res.title
            existing.summary = res.summary
            existing.rawSummary = res.rawSummary
            existing.source = res.source
            existing.articleImageURLString = res.articleImageURL?.absoluteString
            // Overwrite the persisted image bytes only when the fresh
            // search actually fetched new ones — preserve the prior
            // copy if this enrichment pass happened to fail.
            if let newData = res.articleImageData {
                existing.articleImageData = newData
            }
            existing.latitude = res.coordinates?.latitude
            existing.longitude = res.coordinates?.longitude
            existing.inceptionYear = res.inceptionYear
            existing.wikidataType = res.wikidataType
            existing.externalConfidence = res.externalConfidence
            existing.onDeviceMatchScore = res.onDeviceMatchScore
            // Only overwrite the captured photo if we have a new one —
            // preserve the user's earlier capture otherwise.
            if let newThumb {
                existing.imageData = newThumb
            }
            existing.date = Date()
            return existing
        }

        let lookup = LandmarkLookup(
            rawSignText: rawSignText,
            resolvedTitle: res.title,
            summary: res.summary,
            rawSummary: res.rawSummary,
            pageURLString: res.pageURL.absoluteString,
            source: res.source,
            imageData: newThumb,
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

    // MARK: - Thumbnail helper

    private func resized(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Resize an image so its longest edge is `maxDimension`, preserving
    /// aspect ratio. Returns the original image if it's already smaller.
    private func resized(_ image: UIImage, toMaxDimension maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        return resized(image, to: newSize)
    }
}
