//
//  Components.swift
//  BrownSign
//
//  Small UI pieces shared across more than one tab. These used to live
//  inside whichever view first needed them (the display-mode picker in
//  HistoryView, a copy of the thumbnail in every row/card, a copy of
//  the distance formatter in Scan and Nearby); collecting them here
//  keeps the one definition honest and lets all the tabs read from it.
//

import SwiftUI
import CoreLocation
import MapKit
import UIKit
import Accessibility

// MARK: - List / Map display mode

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
        // The custom segments are plain Buttons, so VoiceOver heard "List,
        // button / Map, button" with no hint of which was selected. Present
        // a native segmented Picker to assistive tech instead — selected
        // state, "1 of 2" semantics, and adjustability for free — while the
        // visuals above stay exactly as designed.
        .accessibilityRepresentation {
            Picker("Display mode", selection: $selection) {
                ForEach(LandmarkDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Landmark thumbnail

/// The square landmark thumbnail used by every list row and map callout.
/// Preference order: persisted article-image bytes (instant) → remote
/// article-image URL via `AsyncImage` → the user's captured sign photo →
/// a brown-signpost placeholder. Collapses the near-identical copies
/// that previously lived in NearbyRow, HistoryRow, both map cards, the
/// Hidden-landmarks row, and the Scan "Other matches" row.
struct LandmarkThumbnail: View {
    /// Persisted article-image JPEG bytes — preferred because it's
    /// instant and needs no network.
    var articleImageData: Data? = nil
    /// Remote article-image URL, loaded via `AsyncImage` when there are
    /// no local bytes yet.
    var articleImageURL: URL? = nil
    /// The user's captured sign photo — a last resort before the
    /// placeholder. Only saved lookups (History, map cards) carry one.
    var capturedImageData: Data? = nil
    var size: CGFloat = 56
    /// 10, splitting the difference between the rows' 12 and the original 8.
    /// Equal ABSOLUTE radii don't look equal: 12pt on a 56pt tile spans a
    /// fifth of its edge and reads far rounder than 12pt on a screen-wide
    /// card (Sean confirmed on-device). 10 is where the perceived curvature
    /// matches the rows'.
    var cornerRadius: CGFloat = 10

    /// This instance's freshly-decoded image, tagged with the key it was
    /// decoded for so a recycled row never renders a stale image. Backed by a
    /// process-wide `cache` so a row that scrolls back re-shows instantly
    /// without re-decoding off the main actor.
    @State private var decoded: Decoded?
    /// Set when inline bytes are present but fail to decode, so `content`
    /// degrades to the URL / captured photo / placeholder instead of parking
    /// on a permanent neutral tile.
    @State private var decodeFailed = false
    /// Key already given its one cache-bypassing retry, so a failing URL
    /// doesn't loop the network.
    @State private var retriedKey: String?
    @Environment(\.colorScheme) private var colorScheme

    private struct Decoded { let key: String; let image: UIImage }

    /// Process-wide decoded-thumbnail cache, keyed by `cacheKey`, so a given
    /// (bytes, size) is only ImageIO-decoded once and recycled List rows
    /// re-show instantly with no flash.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 250
        return c
    }()

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // Decorative: the row/card title already names the landmark, so
            // the thumbnail is a redundant VoiceOver stop.
            .accessibilityHidden(true)
            // Fade a freshly-decoded image in instead of popping it — most
            // visible on the map callout, which slides up for 200ms while
            // its thumbnail finishes decoding. Cache hits don't animate:
            // `currentImage` reads the cache synchronously in body, so a
            // scrolled-back row still shows its image in the first frame.
            .animation(.easeInOut(duration: 0.15), value: decoded?.key)
            .task(id: cacheKey) { await loadThumbnail() }
    }

    /// Decode the inline bytes off the main actor (ImageIO, at ~3x the display
    /// size) and cache the result, so a populated List never re-decodes the
    /// persisted ~800px JPEG on the main thread. Reuses a cache hit, hands a
    /// superseded decode back to the live key, and flags an undecodable blob so
    /// `content` can fall through gracefully.
    private func loadThumbnail() async {
        let key = cacheKey
        decodeFailed = false
        guard let bytes = inlineBytes else { decoded = nil; return }
        // Cache hit: mirror it into the observed `decoded` for THIS key. The
        // bare cache read in `currentImage` isn't a SwiftUI dependency, so a
        // sibling row that populated the cache after our first render leaves us
        // parked on the neutral tile until an observed write lands — this is it.
        if let cached = Self.cache.object(forKey: key as NSString) {
            decoded = Decoded(key: key, image: cached)
            return
        }
        let target = size * 3
        let image = await Task.detached(priority: .utility) {
            UIImage.downsampled(from: bytes, maxDimension: target)
        }.value
        // The cache is keyed by content, not by this view's identity, so always
        // bank a good decode even if a recycle moved us on — the row that now
        // owns this key gets an instant hit.
        if let image { Self.cache.setObject(image, forKey: key as NSString) }
        // A row recycle (or in-place byte change) superseded this decode while
        // it was off-actor: don't stamp a stale image onto the live key. Instead
        // re-seed `decoded` from whatever the CURRENT key now holds (commonly a
        // sibling's cached decode), so the settled key always reaches an
        // observed write rather than silently bailing onto a permanent tile.
        guard key == cacheKey else {
            if let live = Self.cache.object(forKey: cacheKey as NSString) {
                decoded = Decoded(key: cacheKey, image: live)
            }
            return
        }
        if let image {
            decoded = Decoded(key: key, image: image)
        } else {
            decodeFailed = true
        }
    }

    /// One cache-bypassing download for a URL whose `AsyncImage` load
    /// failed. Replaces whatever poisoned entry the shared URLCache held
    /// (the fresh 200 is cached normally), downsamples off-main, and
    /// banks the result exactly like the inline-bytes path so `content`
    /// renders it via `currentImage`.
    private func retryRemoteImageBypassingCache() async {
        let key = cacheKey
        guard retriedKey != key, let url = articleImageURL else { return }
        retriedKey = key
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let target = size * 3
        let image = await Task.detached(priority: .utility) {
            UIImage.downsampled(from: data, maxDimension: target)
        }.value
        guard let image else { return }
        Self.cache.setObject(image, forKey: key as NSString)
        // Same supersession rule as loadThumbnail: never stamp a stale
        // key's image onto a recycled row.
        if key == cacheKey {
            decoded = Decoded(key: key, image: image)
        }
    }

    /// The image to show for the CURRENT key: this instance's freshly-decoded
    /// image if it still matches, else a process-wide cache hit. Read in `body`
    /// so a recycled row that scrolls back re-shows instantly (no re-decode, no
    /// neutral-tile flash) and never shows a previous row's image.
    private var currentImage: UIImage? {
        if let decoded, decoded.key == cacheKey { return decoded.image }
        return Self.cache.object(forKey: cacheKey as NSString)
    }

    /// The bytes (if any) decoded inline. Prefers the persisted article
    /// image; the remote-URL case is handled by `AsyncImage` instead (so it
    /// contributes no inline bytes); the captured photo is the last resort
    /// before the placeholder.
    private var inlineBytes: Data? {
        if let articleImageData { return articleImageData }
        if articleImageURL != nil { return nil }
        return capturedImageData
    }

    /// Cheap, stable identity for `.task(id:)` and the cache so SwiftUI doesn't
    /// compare whole Data blobs each update; byte counts change whenever the
    /// underlying image does in practice.
    private var cacheKey: String {
        "\(articleImageData?.count ?? -1)|\(capturedImageData?.count ?? -1)|\(articleImageURL?.absoluteString ?? "")|\(size)"
    }

    @ViewBuilder
    private var content: some View {
        if let image = currentImage {
            Image(uiImage: image).resizable().scaledToFill()
        } else if (articleImageData == nil || decodeFailed), let articleImageURL {
            // No inline bytes, or they failed to decode: try the remote URL
            // before degrading to the captured photo / placeholder. The
            // transaction animates the phase swap so the downloaded image
            // fades in over the neutral tile instead of popping — the pop
            // was glaring on the map callout's slide-up.
            AsyncImage(
                url: articleImageURL,
                transaction: Transaction(animation: .easeInOut(duration: 0.2))
            ) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                        .transition(.opacity)
                case .empty:
                    Color.secondary.opacity(0.1)
                case .failure:
                    // AsyncImage failures are sticky: it never retries,
                    // and it reads the shared URLCache, so a corrupt or
                    // error response cached once keeps "failing" from
                    // disk on every launch even while the URL serves
                    // fine (Seth Wetmore House was stuck like this for
                    // weeks). One fresh attempt that bypasses the cache;
                    // success lands in `decoded`/the NSCache, which
                    // `content` prefers over this whole branch.
                    capturedOrPlaceholder
                        .task { await retryRemoteImageBypassingCache() }
                default:
                    capturedOrPlaceholder
                }
            }
        } else if inlineBytes != nil, !decodeFailed {
            // Bytes present, decode in flight: a neutral tile (not a flash of
            // the placeholder) for the brief first-frame window.
            Color.secondary.opacity(0.1)
        } else {
            capturedOrPlaceholder
        }
    }

    @ViewBuilder
    private var capturedOrPlaceholder: some View {
        if let capturedImageData, let image = UIImage(data: capturedImageData) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            // Placeholder tile (Sean's call, 2026-06-10): solid
            // lightened-brown ground (BrandBrownForeground, the color
            // the map pins wore briefly in 1.8.0) with the signpost in
            // plain BrandBrown — brown-on-brown like a real roadside
            // sign. (A green AccentButton glyph was tried and rejected.)
            Color("BrandBrownForeground")
                .overlay {
                    Image(systemName: "signpost.right.fill")
                        .font(.title2)
                        .foregroundStyle(Color("BrandBrown"))
                }
        }
    }
}

// MARK: - Distance formatting

/// Locale-aware short distance string — imperial for US-style locales,
/// metric elsewhere. Shared by the Nearby rows and the Scan result's
/// "Other matches" list so the two read identically.
func formatLandmarkDistance(_ meters: CLLocationDistance) -> String {
    let usesMetric = Locale.current.measurementSystem == .metric
    if usesMetric {
        if meters < 1_000 { return "\(Int(meters)) m" }
        return String(format: "%.1f km", meters / 1_000)
    } else {
        let miles = meters / 1609.344
        if miles < 0.1 {
            let feet = meters / 0.3048
            return "\(Int(feet)) ft"
        }
        if miles < 10 { return String(format: "%.1f mi", miles) }
        return "\(Int(miles)) mi"
    }
}

/// The prominent green distance pill the redesign puts on Nearby rows and
/// the Scan recents/result rows: a location arrow + short distance on a
/// translucent green capsule (`DistanceChipFill`) in `DistanceChipText`.
/// Best-effort by design — callers pass `nil` when there's no measurable
/// distance (a typed / NPS / pre-enrichment save with no coordinates, or
/// location denied) and the chip renders nothing rather than a placeholder,
/// so it only ever appears when it can show a real distance. Reusing one
/// view keeps the Nearby and Scan pills identical.
struct DistanceChip: View {
    /// Distance from the reference location, in meters. `nil` → renders nothing.
    let meters: CLLocationDistance?

    var body: some View {
        if let meters {
            let text = formatLandmarkDistance(meters)
            // Manual HStack, NOT a Label: Label's default icon/title gap is
            // wide and bloats the pill. Tight 2pt spacing + small padding
            // keeps the arrow and distance close so the whole chip stays
            // compact.
            HStack(spacing: 2) {
                Image(systemName: "location.fill")
                Text(text)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color("DistanceChipText"))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color("DistanceChipFill")))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(text) away")
        }
    }
}

/// Locale-aware search-radius string for the Nearby chrome — the "Within …"
/// list header (spelled out: "2 miles" / "3 km") and the map zoom control's
/// scale cue (`abbreviated`: "2 mi" / "3 km"). Uses the same measurement-
/// system check as `formatLandmarkDistance` so the radius chrome and the
/// per-row distances always agree; the radius LADDER stays defined in miles
/// (2/5/10/25) — only the display converts (→ 3/8/16/40 km).
func formatRadius(miles: Int, abbreviated: Bool = false) -> String {
    let usesMetric = Locale.current.measurementSystem == .metric
    if usesMetric {
        let km = max(1, Int((Double(miles) * 1.609344).rounded()))
        return abbreviated ? "\(km) km" : (km == 1 ? "1 kilometer" : "\(km) kilometers")
    }
    return abbreviated ? "\(miles) mi" : (miles == 1 ? "1 mile" : "\(miles) miles")
}

// MARK: - Review prompt policy

/// Shared review-prompt policy for Scan and Nearby: both tabs bump the
/// same persistent `successfulLookupCount` and ask at the 3rd, 10th, and
/// 25th success. Apple's own heuristics still throttle whether the alert
/// actually shows (at most 3/year), so over-calling is harmless.
nonisolated func shouldRequestReview(afterSuccessCount count: Int) -> Bool {
    [3, 10, 25].contains(count)
}

// MARK: - Accessibility announcements

/// Post a VoiceOver announcement for an async state change that is otherwise
/// visual-only (results landing, a lookup finishing, an error appearing).
/// Without these, a VoiceOver user who triggers a fetch gets silence until
/// they re-scrub the screen. No-op (and ignored by the system) when VoiceOver
/// isn't running.
func announceForAccessibility(_ message: String) {
    AccessibilityNotification.Announcement(message).post()
}

// MARK: - Map region fitting

/// Default map region when there are no points to fit: the continental US.
let continentalUSRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
    span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 50)
)

/// Builds a map region that fits `coords`:
/// - empty → the continental-US default
/// - one point → a fixed `singlePointSpan`° box around it
/// - otherwise → the bounding box scaled by `padding`, floored at a 0.02° span
///
/// Guards the antimeridian: a raw longitude span over 180° (pins straddling
/// ±180°) would otherwise put the midpoint on the wrong side of the planet and
/// zoom out to the whole globe, so it falls back to a local 0.5° box on the
/// first point. Shared by the Nearby and History maps, which pass their own
/// `singlePointSpan` / `padding` to keep each tab's feel.
func fittingRegion(
    for coords: [CLLocationCoordinate2D],
    singlePointSpan: CLLocationDegrees,
    padding: Double
) -> MKCoordinateRegion {
    guard !coords.isEmpty else { return continentalUSRegion }
    if coords.count == 1 {
        return MKCoordinateRegion(
            center: coords[0],
            span: MKCoordinateSpan(latitudeDelta: singlePointSpan, longitudeDelta: singlePointSpan)
        )
    }
    let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
    let minLat = lats.min()!, maxLat = lats.max()!
    let minLon = lons.min()!, maxLon = lons.max()!
    if maxLon - minLon > 180 {
        return MKCoordinateRegion(
            center: coords[0],
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    }
    let center = CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: (minLon + maxLon) / 2
    )
    let span = MKCoordinateSpan(
        latitudeDelta: max(0.02, (maxLat - minLat) * padding),
        longitudeDelta: max(0.02, (maxLon - minLon) * padding)
    )
    return MKCoordinateRegion(center: center, span: span)
}

// MARK: - Low-confidence match note

/// A plain-language note shown ONLY when the on-device Apple Intelligence
/// match score is low, i.e. the model wasn't confident the resolved landmark
/// is actually the place the user searched for. Above the threshold no note
/// is shown at all (no noise on good results, and no exposing a fuzzy,
/// precise-looking percentage). The copy explains itself because a raw score
/// means nothing to a user; it reads as a gentle "this might be wrong, check
/// the other matches" nudge rather than an alarm.
struct LowConfidenceMatchNote: View {
    /// Show the note only when the on-device match score is below this. The
    /// score is a soft self-estimate from a small on-device model, so the
    /// cutoff is deliberately forgiving to avoid second-guessing decent
    /// matches.
    static let threshold: Double = 0.6

    var body: some View {
        Label(
            "Brown Sign isn't fully sure this is the right landmark",
            systemImage: "questionmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(
            "Uncertain match. Brown Sign isn't fully sure this is the right landmark."
        )
    }
}

/// Branded empty / error state: a brand-brown SF Symbol to the LEFT of a
/// bold title, with a secondary detail line beneath the title and an
/// optional action button under the row. This horizontal icon-left layout
/// is the app's house style for these states — History's "No lookups yet"
/// and the Scan how-it-works steps both use it — so Nearby's empty and
/// offline states read consistently with the rest of the app instead of the
/// centred `ContentUnavailableView` stack.
///
/// Vertically centred in whatever space it's given (Spacers top and bottom),
/// so it drops straight into a tab's content area or below a header.
struct BrandEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    /// Icon tint. Brand brown by default; overridable where another color
    /// carries the screen's theme (Hidden Landmarks passes its restore
    /// green so the empty state matches the sheet's actions).
    let iconColor: Color
    private let actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String,
        iconColor: Color = Color("BrandBrownForeground"),
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.iconColor = iconColor
        self.actions = actions()
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.system(size: 40, weight: .semibold))
                        // Default is BrandBrownForeground, not BrandBrown:
                        // the brand value is ~2.2:1 against the dark
                        // background (the same murky-glyph problem
                        // LandmarkThumbnail's placeholder fixed locally),
                        // so glyphs use the foreground variant that
                        // lightens in dark mode. Fills under white text
                        // keep using BrandBrown.
                        .foregroundStyle(iconColor)
                        .frame(width: 54)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title.weight(.bold))
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                // A default-EmptyView action contributes no layout and no
                // stack spacing, so the no-button case renders identically to
                // a plain icon + title + detail row (e.g. History's empty
                // state).
                actions
            }
            .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Map callout card

/// The compact card shown over a map when a pin is selected: a tappable
/// thumbnail + title + 2-line summary + "View details" affordance, with an X
/// dismiss button beside it on a 12pt card with the standard callout shadow.
/// The Nearby and History maps share this chrome and layout; each injects its
/// own tap primitive (a Button vs a NavigationLink) for both the whole card
/// (`wrap`) and the inner "View details" control (`detail`), so the navigation
/// wiring stays per-tab while the look lives here once.
struct MapCalloutCard<Wrapped: View, Detail: View>: View {
    let title: String
    let summary: String
    var articleImageData: Data? = nil
    var articleImageURL: URL? = nil
    var capturedImageData: Data? = nil
    let onDismiss: () -> Void
    /// The inner "View details" control, fully styled by the caller.
    @ViewBuilder let detail: () -> Detail
    /// Wraps the whole card content as the primary tap target.
    @ViewBuilder let wrap: (AnyView) -> Wrapped

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            LandmarkThumbnail(
                articleImageData: articleImageData,
                articleImageURL: articleImageURL,
                capturedImageData: capturedImageData
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // "View details" is a real control nested inside the outer tap
                // wrapper so it keeps its own press feedback; SwiftUI routes
                // taps inside it to it and taps elsewhere to the outer wrapper.
                // Both go to the same destination.
                detail()
                    .padding(.top, 2)
                    // The whole card is already the tap target (with an "Opens
                    // the full landmark details" hint), so hide this duplicate
                    // control from VoiceOver to avoid two actionable elements
                    // per pin pointing at the same destination.
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            wrap(AnyView(cardContent))
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full landmark details")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    // The bare ~20pt glyph is well under the 44pt HIG
                    // minimum; outset the hit area without growing the card.
                    // The X is the later sibling, so it wins the small
                    // overlap with the card's own (huge) tap target.
                    .contentShape(Rectangle().inset(by: -12))
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
}
