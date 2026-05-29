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
import UIKit

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
    var cornerRadius: CGFloat = 8

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private var content: some View {
        if let articleImageData, let image = UIImage(data: articleImageData) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let articleImageURL {
            AsyncImage(url: articleImageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Color.secondary.opacity(0.1)
                default:
                    capturedOrPlaceholder
                }
            }
        } else {
            capturedOrPlaceholder
        }
    }

    @ViewBuilder
    private var capturedOrPlaceholder: some View {
        if let capturedImageData, let image = UIImage(data: capturedImageData) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color("BrandBrown").opacity(0.18)
                .overlay {
                    Image(systemName: "signpost.right.fill")
                        .font(.title2)
                        .foregroundStyle(Color("BrandBrown").opacity(0.55))
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
