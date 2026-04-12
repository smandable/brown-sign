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

// MARK: - HistoryView

struct HistoryView: View {
    @Query(sort: \LandmarkLookup.date, order: .reverse)
    private var lookups: [LandmarkLookup]

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if lookups.isEmpty {
                    ContentUnavailableView(
                        "No lookups yet",
                        systemImage: "signpost.right.fill",
                        description: Text("Snap a brown sign to get started.")
                    )
                } else {
                    List {
                        ForEach(lookups) { lookup in
                            NavigationLink(value: lookup) {
                                HistoryRow(lookup: lookup)
                            }
                        }
                        .onDelete(perform: deleteLookups)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: LandmarkLookup.self) { lookup in
                LandmarkDetailView(lookup: lookup)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }

    private func deleteLookups(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(lookups[index])
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

struct LandmarkDetailView: View {
    let lookup: LandmarkLookup

    @State private var showSafari = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Persisted Wikipedia article image, if available.
                if let data = lookup.articleImageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // The user's captured sign photo (local thumbnail), if any.
                if let data = lookup.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(lookup.resolvedTitle)
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    sourceBadge
                    Text(lookup.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                metadataBlock

                if !lookup.rawSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full description")
                            .font(.headline)
                        Text(lookup.rawSummary)
                            .font(.body)
                    }
                }

                Button {
                    showSafari = true
                } label: {
                    Label("Read full article", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .disabled(lookup.pageURL == nil)

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
            || lookup.externalConfidence != nil
            || lookup.onDeviceMatchScore != nil

        if hasAny {
            VStack(alignment: .leading, spacing: 6) {
                if let lat = lookup.latitude, let lon = lookup.longitude {
                    Label(String(format: "%.4f, %.4f", lat, lon),
                          systemImage: "mappin.and.ellipse")
                        .font(.caption)
                }
                if let year = lookup.inceptionYear {
                    Label("Est. \(String(year))", systemImage: "calendar")
                        .font(.caption)
                }
                if let type = lookup.wikidataType {
                    Label(type, systemImage: "tag.fill")
                        .font(.caption)
                }
                if let ext = lookup.externalConfidence {
                    Label(String(format: "Google: %.0f", ext),
                          systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                if let score = lookup.onDeviceMatchScore {
                    Label("On-device: \(Int(score * 100))%", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.indigo)
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
