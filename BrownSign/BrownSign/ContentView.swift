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
    @ScaledMetric(relativeTo: .body) private var recentRowHeight: CGFloat = 96

    /// Per-session dismiss for the "Turn on location" banner. Flips back
    /// to false every cold launch, so a user who taps the X still sees
    /// it next time they open the app — but we don't nag them during
    /// the current session.
    @State private var locationBannerDismissed = false

    /// Drives the brand bar's info button → a "how it works" sheet.
    @State private var showInfo = false

    /// The inline live viewfinder's capture session. Held here (not inside
    /// the tile) so it survives the tile showing/hiding across the scan→
    /// result→scan cycle and reuses one configured session.
    @State private var cameraController = ScanCameraController()

    // Review prompt: count successful lookups, request a rating
    // after the user has had a few good experiences with the app.
    @AppStorage("successfulLookupCount") private var successfulLookupCount = 0

    private let locationManager = LocationManager.shared
    private let router = AppRouter.shared

    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview
    /// Pauses the inline viewfinder when the app isn't frontmost (so its
    /// session never runs in the background).
    @Environment(\.scenePhase) private var scenePhase

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
                        brandBar

                        // Camera-first: the live viewfinder leads the screen in
                        // the fresh state (nothing captured, no result, not
                        // searching). A landed result / captured photo takes the
                        // slot instead — the same rhythm the brand hero had.
                        if result == nil && !isSearching && capturedImage == nil {
                            cameraTile
                        }

                        if let image = capturedImage {
                            // Same 260 footprint + 14 radius as the viewfinder
                            // it replaces, so the captured shot doesn't appear
                            // to shrink after the shutter.
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 260)
                                .clipped()
                                .contentShape(Rectangle())
                                .clipShape(RoundedRectangle(cornerRadius: 14))
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

                        searchField

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

                        if let result {
                            resultCard(for: result)
                                .id("resultCard")
                            alternativesSection
                        } else {
                            // Recents/how-it-works show whenever there's no
                            // result — idle AND while a capture is being
                            // processed. The status text lives inside the search
                            // field now (not a separate line above), so it never
                            // pushes this list down and back up.
                            // The empty-state body is just the
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
            // The bottom "Look it up" bar is gone — the redesign moves that
            // action onto the search field's own circular submit arrow
            // (see `searchField`). Keyboard toolbar is built into
            // LandmarkTextField's inputAccessoryView (dismiss ⌨↓ + search 🔍).
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
            .sheet(isPresented: $showInfo) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 28) {
                        howItWorksSteps
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .navigationTitle("How it works")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showInfo = false }
                        }
                    }
                }
                .presentationDetents([.medium])
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

    // MARK: - Brand bar

    /// Compact brand bar at the top of Scan: a 32pt BrandBrown rounded-square
    /// mark with the signpost glyph + the "Brown Sign" wordmark, and a
    /// trailing info button (the "how it works" sheet). Replaces the
    /// oversized brown hero so the live viewfinder leads the screen.
    private var brandBar: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandBrown"))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "signpost.right.and.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            Text("Brown Sign")
                .font(.system(size: 18, weight: .heavy))
            Spacer(minLength: 0)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How Brown Sign works")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Camera tile

    /// True when the inline viewfinder should run its session: the app is
    /// frontmost and nothing (the full-screen camera, the detail/info sheet,
    /// the photo picker) is covering the Scan tab. The tile itself only
    /// renders in the fresh state, so this is the additional "not obscured"
    /// gate that keeps the inline session from ever running alongside the
    /// full-screen camera.
    private var viewfinderActive: Bool {
        scenePhase == .active
            && !showCamera
            && presentedLookup == nil
            && !showInfo
            && !photoPickerPresented
    }

    /// The live camera-first viewfinder (the redesign's centerpiece). The
    /// gallery thumb opens the library picker; the shutter captures from the
    /// inline feed; the expand button opens the full-screen CameraView
    /// (pinch-zoom / focus for a distant sign). Library import lives here —
    /// the safe road-trip flow is "passenger photographs the sign, looks it
    /// up at the next stop" — and routes through the same ingest pipeline.
    private var cameraTile: some View {
        ScanViewfinder(
            controller: cameraController,
            active: viewfinderActive,
            onPickPhoto: { photoPickerPresented = true },
            onExpand: { showCamera = true },
            onCapture: { ingestPhoto(data: $0) }
        )
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

    // MARK: - Search field

    /// Magnifier + text field + a circular submit arrow — the redesign's
    /// replacement for the separate bottom "Look it up" bar. The arrow is
    /// dimmed + disabled when empty, green when there's text; tapping it runs
    /// the same lookUp() the keyboard Search key does.
    private var searchField: some View {
        let trimmed = signText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSubmit = !trimmed.isEmpty && !isProcessing && !isSearching
        let processing = isProcessing || isSearching
        return HStack(spacing: 8) {
            if !statusMessage.isEmpty {
                // Status ("Identifying landmark…", or a terminal error) shows
                // INSIDE the field so it never inserts a separate line that
                // pushes the recents list down and back up. A spinner stands in
                // for the magnifier while working; a terminal error gets a
                // dismiss X (the typed query stays in place behind it).
                if processing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(statusMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    // 1 line while working keeps the field height fixed (so the
                    // list never moves); a terminal error may wrap to 2 but it's
                    // a stable end state, not a transient push.
                    .lineLimit(processing ? 1 : 2)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                if !processing {
                    Button {
                        statusMessage = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                LandmarkTextField(
                    text: $signText,
                    isFocused: $isSignTextFocused,
                    onSearch: {
                        // Mirror the submit arrow's guard so the keyboard Search
                        // key can't launch an overlapping lookUp() (which would
                        // double the review-prompt counter and race the result/
                        // savedLookup writes) or run a no-op pipeline on empty text.
                        guard canSubmit else { return }
                        Task { await lookUp() }
                    }
                )
                .frame(minHeight: 28)
                // Reset/"scan again": with the viewfinder tile hidden once a
                // result is showing, this is the way back to the camera. Shown
                // whenever there's anything to clear (typed text, a result, a
                // captured photo).
                if !signText.isEmpty || result != nil || capturedImage != nil {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
                Button {
                    guard canSubmit else { return }
                    isSignTextFocused = false
                    Task { await lookUp() }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color("AccentButton")))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                // Green even when empty (per the mock); just dimmed when there's
                // nothing to look up yet.
                .opacity(canSubmit ? 1 : 0.5)
                .accessibilityLabel("Look up landmark")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .onTapGesture { isSignTextFocused = true }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSignTextFocused ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: isSignTextFocused ? 2 : 1
                )
        )
        .id("textField")
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

    /// Three-step "how it works" guide shown on first launch (when
    /// the user has no saved lookups). Compact so it doesn't push
    /// the Look It Up bar off small screens.
    private var howItWorksSteps: some View {
        // Foreground brown (the lighter dark-mode variant), matching the
        // empty-state glyphs — the brand value is too dark on the dark
        // background. Plain BrandBrown stays for fills under white text.
        let brown = Color("BrandBrownForeground")
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
                            .font(.system(size: 21, weight: .heavy))
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
                Image(systemName: "flag.fill")
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
                        HStack(spacing: 12) {
                            LandmarkThumbnail(
                                articleImageData: lookup.articleImageData,
                                articleImageURL: lookup.articleImageURL,
                                capturedImageData: lookup.imageData,
                                size: 54
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lookup.resolvedTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                // Meta line: a green distance pill (when we can
                                // measure one from the current location) + a
                                // relative "2h ago" timestamp, per the redesign.
                                HStack(spacing: 8) {
                                    DistanceChip(meters: recentDistanceMeters(lookup))
                                    Text(relativeFindTimestamp(lookup.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
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

    /// Distance from the user's current location to a saved find, for the
    /// recents row's green pill. Best-effort: nil (no chip) when the find has
    /// no coordinates or we don't have a location fix yet.
    private func recentDistanceMeters(_ lookup: LandmarkLookup) -> CLLocationDistance? {
        guard let lat = lookup.latitude, let lon = lookup.longitude,
              let reference = locationManager.lastLocation else { return nil }
        return reference.distance(from: CLLocation(latitude: lat, longitude: lon))
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
