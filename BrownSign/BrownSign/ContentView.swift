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
    /// 112px history thumbnail for `capturedImage`, encoded once when the
    /// photo is captured and reused across every lookup path instead of
    /// re-encoding the JPEG three times per result.
    @State private var capturedThumbnailData: Data?
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

    /// Per-row height for the "Recent finds" list. Scales with Dynamic
    /// Type so the fixed-height List (which can't self-size inside the
    /// outer ScrollView) grows with the user's text size instead of
    /// clipping rows. Over-allocation is harmless: each row carries its
    /// own parchment background, so any unused tail stays transparent.
    @ScaledMetric(relativeTo: .body) private var recentRowHeight: CGFloat = 104

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
                                        capturedThumbnailData = nil
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
                        // Filled buttons use AccentButton instead of
                        // AccentColor — needs more saturation in dark
                        // mode for white-text contrast (4.8:1 vs 3.2:1).
                        .tint(Color("AccentButton"))
                        .buttonBorderShape(.roundedRectangle(radius: 12))

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            LandmarkTextField(
                                text: $signText,
                                isFocused: $isSignTextFocused,
                                onSearch: { Task { await lookUp() } }
                            )
                            .frame(minHeight: 28)
                            .onChange(of: signText) { _, _ in
                                // Clear any stale status (e.g.
                                // "No results" left over from a
                                // previous search) the moment the
                                // user starts a new query — they
                                // shouldn't have to commit a search
                                // just to dismiss old feedback.
                                if !statusMessage.isEmpty {
                                    statusMessage = ""
                                }
                            }

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
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))
                                .onTapGesture { isSignTextFocused = true }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
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
                                .opacity(isSignTextFocused ? 0 : 1)
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
                            // Fades while the keyboard is up — those
                            // rows otherwise sit visibly under the
                            // raised "Look It Up" button and pull the
                            // eye away from the field being typed in.
                            VStack(spacing: 20) {
                                if recentLookups.isEmpty {
                                    howItWorksSteps
                                } else {
                                    recentFindsSection
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .opacity(isSignTextFocused ? 0 : 1)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Brown Sign. Snap a sign or type to look up a landmark.")
                        }
                    }
                    .padding()
                    // Single animation on focus so all the fades happen
                    // together rather than each rebuilding independently.
                    .animation(.easeInOut(duration: 0.2), value: isSignTextFocused)
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
                        .init(color: Color("BrandBrown").opacity(0.12), location: 0),
                        .init(color: Color("BrandBrown").opacity(0.04), location: 0.35),
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
                    Label("Look it up", systemImage: "magnifyingglass")
                        .fontWeight(.regular)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("AccentButton"))
                .buttonBorderShape(.roundedRectangle(radius: 12))
                // `.disabled` gives the real disabled trait (VoiceOver
                // announces it, taps are blocked); the opacity is just the
                // visual dim on top of it.
                .disabled(lookUpDisabled)
                .opacity(lookUpDisabled ? 0.5 : 1)
                .accessibilityHint(lookUpDisabled ? "Enter text to search" : "")
                .padding(.horizontal)
                .padding(.top, 8)
                // 16pt below the button — same gap above the tab bar
                // that the list and map cards leave on Nearby/History.
                // Kept inside .bar so the material stays flush with the
                // tab bar (iOS bottom-action-bar convention) instead of
                // floating with a clear strip below it.
                .padding(.bottom, 16)
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
                        let scaled = image.resized(toMaxDimension: 800)
                        capturedImage = scaled
                        // Encode the history thumbnail once here instead of
                        // re-deriving it in each lookup path.
                        capturedThumbnailData = scaled.resized(to: CGSize(width: 112, height: 112))
                            .jpegData(compressionQuality: 0.7)
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
        HStack(alignment: .top, spacing: 8) {
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Empty state

    /// Stylized brown road-sign illustration — echoes the real-world
    /// UK/US tourist-attraction sign that gives the app its name.
    /// Purely decorative; hidden from VoiceOver since the container
    /// carries the accessibility label.
    private var brownSignHero: some View {
        let signBrown = Color("BrandBrown")
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(signBrown)
            RoundedRectangle(cornerRadius: 7)
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
        let brown = Color("BrandBrown")
        let steps: [(String, String, String)] = [
            ("camera.fill", "Snap", "Point your camera at any landmark sign"),
            ("sparkles", "Identify", "We look up the landmark for you"),
            ("bookmark.fill", "Save", "History keeps every find")
        ]
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(steps, id: \.0) { icon, title, detail in
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(brown)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title2.weight(.bold))
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Last 3 saved lookups, shown on the empty state once the user
    /// has history. Tapping a row opens the same LandmarkDetailView
    /// sheet used by the result card's "View full details" button.
    private var recentFindsSection: some View {
        let rows = Array(recentLookups.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            // Brand-themed icon for the section header — parallels
            // the icon-then-label pattern on History ("clock.fill")
            // and Nearby ("location.fill"). All three use
            // subheadline + semibold + accent color so the section
            // labels read consistently across tabs.
            HStack(spacing: 6) {
                Image(systemName: "signpost.right.fill")
                Text("Recent finds")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)

            // Embedding a List inside the outer ScrollView so we get the
            // native iOS swipe-to-delete gesture — .swipeActions only
            // works on List. scrollDisabled passes the scroll through to
            // the parent; the fixed frame height is needed because List
            // doesn't self-size inside a ScrollView.
            List {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, lookup in
                    let isFirst = index == 0
                    let isLast = index == rows.count - 1
                    Button {
                        // Drive the sheet via a single optional binding
                        // rather than (savedLookup=…, flag=true). The
                        // flag-plus-optional pair race produced blank
                        // sheets when the sheet body evaluated before
                        // the second state update had propagated.
                        presentedLookup = lookup
                    } label: {
                        HStack(spacing: 8) {
                            HistoryRow(lookup: lookup, datePrefix: "Found")
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
                    // Per-row parchment with rounded outer corners
                    // only on the first and last rows — same pattern
                    // Nearby/History use, so the parchment ends
                    // exactly with the last row instead of leaving
                    // dead space below it (the fixed-frame approach
                    // over-allocated by ~12pt per row).
                    .listRowBackground(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(
                                topLeading: isFirst ? 12 : 0,
                                bottomLeading: isLast ? 12 : 0,
                                bottomTrailing: isLast ? 12 : 0,
                                topTrailing: isFirst ? 12 : 0
                            )
                        )
                        .fill(Color("CardBackground"))
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparatorTint(Color.secondary.opacity(0.2))
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            // ~104pt per row at default text size, scaled with Dynamic
            // Type via `recentRowHeight` so large accessibility sizes no
            // longer clip the rows (List can't self-size inside the outer
            // ScrollView, so the height is fixed per render). Per-row
            // parchment keeps any unused tail invisible: the row's
            // parchment ends with the row regardless of frame slack.
            .frame(height: CGFloat(rows.count) * recentRowHeight)
            // Round the viewport edges so they line up with the
            // first/last rows' rounded corners. With per-row
            // backgrounds carrying the parchment, the clipShape's
            // empty-tail corners fall over invisible space.
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                .tint(Color("BrandBrown"))
                .buttonBorderShape(.roundedRectangle(radius: 12))
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
                    .tint(Color("BrandBrown"))
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(result.pageURL.absoluteString.isEmpty)

                    ShareLink(item: result.pageURL,
                              subject: Text(result.title),
                              message: Text(result.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("BrandBrown"))
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }
            }
        }
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 12)
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
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.fill")
                    Text("Other matches")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)

                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.pageURL) { idx, alt in
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
            LandmarkThumbnail(
                articleImageData: alt.articleImageData,
                articleImageURL: alt.articleImageURL,
                size: 44,
                cornerRadius: 6
            )

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
                        Text(formatLandmarkDistance(d))
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
        .padding(12)
        .contentShape(Rectangle())
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same parchment surface as the detail view's metadata
            // block — keeps the Scan result card metadata visually
            // parallel to its History counterpart.
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color("CardBackground"))
            )
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
        // The inflight guard in LocationManager means concurrent callers
        // share one fetch, so this composes safely with the .task priming.
        let userLocation = await locationManager.currentLocation(
            withTimeout: LocationManager.scanHintTimeout
        )

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
        let thumb: Data? = capturedThumbnailData
        savedLookup = LandmarkLookup.upsert(
            result: first, in: modelContext, rawSignText: trimmed, capturedThumb: thumb
        )
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
        let thumb: Data? = capturedThumbnailData
        let saved = LandmarkLookup.upsert(
            result: enriched, in: modelContext, rawSignText: query, capturedThumb: thumb
        )
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
        capturedThumbnailData = nil
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
        let thumb: Data? = capturedThumbnailData
        savedLookup = LandmarkLookup.upsert(
            result: alt, in: modelContext, rawSignText: trimmed, capturedThumb: thumb
        )
        Task { await selectCandidate(alt, query: trimmed) }
    }

}
