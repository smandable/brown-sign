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
import PhotosUI

/// Descriptor for the Scan tab's "Recent finds" preview: newest 3 only.
/// Without the fetchLimit, the @Query on the launch tab materialized and
/// observation-tracked the user's ENTIRE history — inline image blobs
/// included — to show three rows.
private let recentFindsDescriptor: FetchDescriptor<LandmarkLookup> = {
    var d = FetchDescriptor<LandmarkLookup>(
        sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    d.fetchLimit = 3
    return d
}()

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

    @State private var isSignTextFocused = false

    /// In-flight photo-ingest pipeline (downsample → thumbnail → OCR →
    /// normalize) for the MOST RECENT photo. Tracked so a retake or a new
    /// library pick cancels the previous photo's pipeline: two concurrent
    /// runs raced, and the SLOWER (stale) one could overwrite `signText`
    /// with the older photo's text after the newer photo had landed.
    @State private var processTask: Task<Void, Never>?

    /// Library photo selected via the "Choose a photo" picker; routed
    /// through the same ingest pipeline as a camera capture, then reset.
    @State private var photoPickerItem: PhotosPickerItem?

    /// Presentation flag for the library picker. The modifier form
    /// (`.photosPicker(isPresented:)`) is used instead of the
    /// `PhotosPicker` button so launcher-driven camera opens can
    /// dismiss the picker programmatically — without it, a Siri or
    /// Control Center scan fired mid-pick would silently fail to
    /// present the camera and wedge `showCamera` true.
    @State private var photoPickerPresented = false

    /// Per-row height for the non-scrolling "Recent finds" List, which can't
    /// self-size inside the outer ScrollView. Scales with Dynamic Type, with
    /// a little headroom so large text sizes don't clip; the per-row
    /// parchment hides any slack.
    @ScaledMetric(relativeTo: .body) private var recentRowHeight: CGFloat = 116

    /// Per-session dismiss for the "Turn on location" banner. Flips back
    /// to false every cold launch, so a user who taps the X still sees
    /// it next time they open the app — but we don't nag them during
    /// the current session.
    @State private var locationBannerDismissed = false

    // Review prompt: count successful lookups, request a rating
    // after the user has had a few good experiences with the app.
    @AppStorage("successfulLookupCount") private var successfulLookupCount = 0

    private let locationManager = LocationManager.shared
    private let router = AppRouter.shared

    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    /// Recent lookups for the empty-state "Recent finds" preview.
    /// Same sort order as HistoryView, so the top rows match; capped at
    /// 3 by `recentFindsDescriptor` since only 3 are ever shown.
    @Query(recentFindsDescriptor)
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
                                        // Cancel any in-flight OCR for this
                                        // photo too — its text landing after
                                        // the photo was removed reads as a
                                        // ghost.
                                        processTask?.cancel()
                                        isProcessing = false
                                        statusMessage = ""
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

                        photoInputRow

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            LandmarkTextField(
                                text: $signText,
                                isFocused: $isSignTextFocused,
                                onSearch: {
                                    // Mirror the "Look it up" button's guard so
                                    // the keyboard Search key can't launch an
                                    // overlapping lookUp() (which would double
                                    // the review-prompt counter and race the
                                    // result/savedLookup writes) or run a no-op
                                    // pipeline on empty text.
                                    let trimmed = signText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty, !isProcessing, !isSearching else { return }
                                    Task { await lookUp() }
                                }
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
                            // Faded while the keyboard is up — but opacity 0
                            // alone still hit-tests, leaving an invisible
                            // "Open Settings" that could yank a blind tap
                            // into the Settings app. Disable hits and hide
                            // from VoiceOver while faded.
                            locationDeniedBanner
                                .opacity(isSignTextFocused ? 0 : 1)
                                .allowsHitTesting(!isSignTextFocused)
                                .accessibilityHidden(isSignTextFocused)
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
                            // Same ghost-tap guard as the banner: invisible
                            // recent-find rows must not open a detail sheet
                            // from under the keyboard.
                            .allowsHitTesting(!isSignTextFocused)
                            .accessibilityHidden(isSignTextFocused)
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
                // Dim via opacity, NOT `.disabled`: `.disabled` greys a
                // bordered-prominent button's fill, which stacked with this
                // opacity to near-invisible. The action already guards on
                // `lookUpDisabled`, so taps stay no-ops when there's nothing
                // to look up.
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
                    onCapture: { data in
                        // Dismiss immediately; the heavy decode runs in
                        // ingestPhoto off the main actor (synchronously
                        // downsampling an up-to-48MP frame here stuttered
                        // the camera-dismissal transition).
                        showCamera = false
                        ingestPhoto(data: data)
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSafari) {
                // isSafariPresentableURL: SFSafariViewController crashes on
                // non-http(s) schemes, and pageURL comes from remote data.
                if let url = result?.pageURL, isSafariPresentableURL(url) {
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
            // Launcher-driven camera open: onAppear covers cold launch
            // (the trigger fired before this view existed and parked
            // the action on the router), onChange covers warm launch.
            .onAppear {
                consumeLaunchAction()
            }
            .onChange(of: router.pendingAction) {
                consumeLaunchAction()
            }
        }
    }

    /// Consumes a parked `.scanCamera` launcher request (Siri, the
    /// Control Center button, the Home Screen quick action). The
    /// window's presentation slot must actually be free before the
    /// camera is raised: a fullScreenCover presented while ANY modal
    /// is up — including sheets owned by other tabs, which survive
    /// the programmatic tab switch — or in the first frame at cold
    /// launch is silently dropped, leaving `showCamera` wedged true.
    /// So this clears the slot at the UIKit level (one place covers
    /// every sheet/dialog owner, present and future), polls until
    /// it's free, and recovers a wedged flag by toggling it.
    private func consumeLaunchAction() {
        guard router.pendingAction == .scanCamera else { return }
        router.pendingAction = nil
        // Scan's own modals still clear via their bindings so SwiftUI
        // state agrees with the UIKit dismissal below.
        showSafari = false
        showMapsDialog = false
        photoPickerPresented = false
        presentedLookup = nil
        Task { @MainActor in
            await Self.clearPresentedModals()
            if showCamera {
                // A previously dropped presentation left the flag
                // true with no cover on screen; true-over-true is not
                // a state change, so dip through false to re-present.
                showCamera = false
                try? await Task.sleep(for: .milliseconds(75))
            }
            showCamera = true
        }
    }

    /// Dismisses whatever the key window is presenting and waits for
    /// the presentation slot to free up (capped at ~2s), so the
    /// camera cover that follows is never dropped.
    @MainActor
    private static func clearPresentedModals() async {
        // One frame-ish beat first: at cold launch the request is
        // consumed in the root view's onAppear, before the window
        // hierarchy can host a presentation.
        try? await Task.sleep(for: .milliseconds(75))
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController
        else { return }
        guard root.presentedViewController != nil else { return }
        root.dismiss(animated: true)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if root.presentedViewController == nil { return }
        }
    }

    // MARK: - Photo input row

    /// The camera button plus the library picker (extracted from `body` to
    /// keep the type checker happy). Library import sits beside the camera
    /// because the safe road-trip flow is "passenger photographs the sign,
    /// identifies it at the next stop" — that photo lives in the library,
    /// not the live camera. Both route through the same ingest pipeline.
    private var photoInputRow: some View {
        HStack(spacing: 8) {
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

            // Icon-only width matches the Share button on the result card.
            Button {
                photoPickerPresented = true
            } label: {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
                    .labelStyle(.iconOnly)
                    .frame(width: 44)
                    .frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("AccentButton"))
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .accessibilityLabel("Choose a photo")
        }
        .photosPicker(
            isPresented: $photoPickerPresented,
            selection: $photoPickerItem,
            matching: .images
        )
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            // Reset so re-picking the same photo re-fires.
            photoPickerItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    statusMessage = "Couldn't load that photo. Try a different one."
                    return
                }
                ingestPhoto(data: data)
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
                // Blue by Sean's call: text links should look like the
                // links they are, not blend into the accent palette.
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

            // A non-scrolling List, so swipe-to-delete works (.swipeActions
            // only exists on List). List can't self-size inside the outer
            // ScrollView, so the height is `recentRowHeight` per row, scaled
            // with Dynamic Type. The per-row parchment makes any slack
            // invisible, so this errs generous rather than clipping.
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
                    // Per-row parchment with rounded outer corners only on
                    // the first and last rows, matching the Nearby/History
                    // card look.
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
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparatorTint(Color.secondary.opacity(0.2))
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(rows.count) * recentRowHeight)
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

            // Content runs to the card edge by design (Sean's call —
            // matches the detail view, where everything shares one
            // margin). Don't add internal horizontal padding here.
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

            buttonStack(for: result)
        }
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        )
    }

    @ViewBuilder
    private func buttonStack(for result: LandmarkResult) -> some View {
        VStack(spacing: 8) {
                Button {
                    presentedLookup = savedLookup
                } label: {
                    Label("View full details", systemImage: "text.alignleft")
                        .fontWeight(.regular)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("AccentButton"))
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
                    .tint(Color("AccentButton"))
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(!isSafariPresentableURL(result.pageURL))

                    ShareLink(item: result.pageURL,
                              subject: Text(result.title),
                              message: Text(result.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("AccentButton"))
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }
            }
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

                // The SAME row component and parchment card the Nearby,
                // History, and Recent-finds lists use (Sean's call) — not a
                // hand-rolled lookalike with its own thumbnail size and
                // paddings. Alternatives are LandmarkResults, which is
                // exactly what NearbyRow renders; 12/6 padding mirrors the
                // lists' row insets, and the divider's 80pt leading inset
                // (12 inset + 56 thumbnail + 12 gap) matches where List
                // separators start.
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.pageURL) { idx, alt in
                        Button {
                            switchTo(alt)
                        } label: {
                            NearbyRow(
                                result: alt,
                                referenceLocation: locationManager.lastLocation
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if idx < others.count - 1 {
                            Divider().padding(.leading, 80)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color("CardBackground"))
                )
            }
        }
    }

    @ViewBuilder
    private func metadataChips(for result: LandmarkResult) -> some View {
        let lowConfidence = (result.onDeviceMatchScore ?? 1) < LowConfidenceMatchNote.threshold
        let hasAny = result.coordinates != nil
            || result.inceptionYear != nil
            || result.wikidataType != nil
            || lowConfidence

        if hasAny {
            VStack(alignment: .leading, spacing: 4) {
                if lowConfidence {
                    LowConfidenceMatchNote()
                }
                if let coord = result.coordinates {
                    Label(String(format: "%.4f, %.4f", coord.latitude, coord.longitude),
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
                if let year = result.inceptionYear {
                    // Negative = BCE (parseClaimYear preserves the sign), so
                    // a 500 BC site reads "Est. 500 BC", not "Est. 500".
                    Label(year < 0 ? "Est. \(String(-year)) BC" : "Est. \(String(year))",
                          systemImage: "calendar")
                        .font(.caption)
                        // VoiceOver reads the bare "Est." abbreviation
                        // oddly; spell it out.
                        .accessibilityLabel(year < 0
                            ? "Established \(String(-year)) BC"
                            : "Established \(String(year))")
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

    /// Shared photo-ingest pipeline for the camera capture AND the library
    /// picker: downsample to the 1600px OCR sink and encode the 112px
    /// history thumbnail off the main actor, then OCR + normalize. Cancels
    /// any previous photo's pipeline first so a retake (or rapid
    /// double-shutter) can't have the slower, stale run overwrite the newer
    /// photo's state.
    private func ingestPhoto(data: Data) {
        processTask?.cancel()
        processTask = Task {
            // 1600px keeps distant-sign text legible for OCR while staying
            // light; high-res capture means a zoomed crop is still sharp at
            // that size. ImageIO decodes straight to the target size, so a
            // full-resolution frame is never fully decoded into memory.
            let scaled = await Task.detached(priority: .userInitiated) {
                UIImage.downsampled(from: data, maxDimension: 1600)
            }.value
            guard let scaled, !Task.isCancelled else { return }
            // Encode the history thumbnail once here instead of re-deriving
            // it in each lookup path.
            let thumb = await Task.detached(priority: .userInitiated) {
                scaled.resized(to: CGSize(width: 112, height: 112))
                    .jpegData(compressionQuality: 0.7)
            }.value
            guard !Task.isCancelled else { return }
            capturedImage = scaled
            capturedThumbnailData = thumb
            await processImage(scaled)
        }
    }

    private func processImage(_ image: UIImage) async {
        isProcessing = true
        statusMessage = "Reading sign…"
        announceForAccessibility("Reading sign")
        let lines = await recognizeText(from: image)
        // Superseded by a retake/new pick: the successor pipeline owns the
        // isProcessing/status state now, so bail without touching it.
        guard !Task.isCancelled else { return }
        statusMessage = "Identifying landmark…"
        let normalized = await normalizeLandmarkName(fromLines: lines)
        guard !Task.isCancelled else { return }
        let cleaned = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            // Nothing readable in the photo (blur, glare, not a sign).
            // Ending silently left an empty field with no explanation;
            // say what happened and what to do. Typing clears this via
            // the field's onChange, like the other statuses.
            signText = ""
            statusMessage = "Couldn't read any text in that photo. Try getting closer or holding steady."
            announceForAccessibility(statusMessage)
        } else {
            signText = cleaned
            statusMessage = ""
        }
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
        let outcome = await searchLandmarkCandidates(
            query: trimmed,
            userLocation: userLocation
        )
        candidates = outcome.candidates

        guard let first = outcome.candidates.first else {
            // Two different situations used to collapse into one bare
            // "No results": being offline (every source transport-failed,
            // which told the user there's no such landmark — wrong
            // information) and a genuine no-match (which offered no next
            // step). Say which one it is, with what to do about it.
            statusMessage = outcome.transportFailed
                ? "Couldn't reach the landmark services. Check your connection, then try again."
                : "No matches for \"\(trimmed)\". Check the sign text, or try fewer words."
            isSearching = false
            announceForAccessibility(statusMessage)
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
        announceForAccessibility("Found \(first.title)")
        let thumb: Data? = capturedThumbnailData
        savedLookup = LandmarkLookup.upsert(
            result: first, in: modelContext, rawSignText: trimmed, capturedThumb: thumb
        )
        maybeRequestReview()
        Task { await selectCandidate(first, query: trimmed) }
    }

    /// Prompts for an App Store rating after the user has had a few
    /// successful lookups (Nearby detail opens count too, via the shared
    /// counter — Nearby-first users otherwise never got asked). Apple
    /// throttles review requests to at most 3 per year per user, so
    /// calling this more often than that is fine — the system simply
    /// ignores extra calls. We also skip the first few lookups to avoid
    /// prompting during initial exploration.
    private func maybeRequestReview() {
        successfulLookupCount += 1
        guard shouldRequestReview(afterSuccessCount: successfulLookupCount) else { return }
        // Defer past the result card landing: requesting synchronously
        // popped the system rating alert over the result the user just
        // asked for, mid-read — the worst possible moment to interrupt.
        Task {
            try? await Task.sleep(for: .seconds(2.5))
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
        // Cancel any in-flight OCR/normalize pipeline first: without this,
        // clearing during (or just after) a photo's processing let the
        // pipeline land late and refill `signText` — the X appeared to do
        // nothing.
        processTask?.cancel()
        isProcessing = false
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
