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
    @State private var showDetailSheet = false
    @State private var statusMessage = ""

    @FocusState private var isSignTextFocused: Bool

    private let locationManager = LocationManager.shared

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if let image = capturedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        Button {
                            showCamera = true
                        } label: {
                            Label("Snap a Sign", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brown)
                        .controlSize(.large)

                        TextField(
                            "Landmark text",
                            text: $signText,
                            axis: .vertical
                        )
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSignTextFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)

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
                        }
                    }
                    .padding()
                }
                .onChange(of: result?.pageURL) { _, _ in
                    // When the card content switches to a different
                    // landmark, scroll the card into view so the user
                    // doesn't have to hunt for it.
                    guard result != nil else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo("resultCard", anchor: .top)
                    }
                }
            }
            .navigationTitle("Brown Sign")
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await lookUp() }
                } label: {
                    Label("Look It Up", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
                .disabled(signText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isProcessing
                          || isSearching)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        Task { await lookUp() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .disabled(
                        signText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isProcessing
                        || isSearching
                    )
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(
                    onCapture: { image in
                        capturedImage = image
                        showCamera = false
                        Task { await processImage(image) }
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
            .sheet(isPresented: $showDetailSheet) {
                if let lookup = savedLookup {
                    NavigationStack {
                        LandmarkDetailView(lookup: lookup)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showDetailSheet = false }
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: - Result card

    @ViewBuilder
    private func resultCard(for result: LandmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data = result.articleImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let imageURL = result.articleImageURL {
                // Pre-enrichment fallback: briefly show an AsyncImage
                // until enrichLandmark downloads and caches the bytes.
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
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Text(result.title)
                .font(.title2.bold())

            metadataChips(for: result)

            Text(result.summary)
                .font(.body)
                .lineLimit(6)

            VStack(spacing: 8) {
                Button {
                    showDetailSheet = true
                } label: {
                    Label("View full details", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(savedLookup == nil)

                Button {
                    showSafari = true
                } label: {
                    Label("Read full article", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(result.pageURL.absoluteString.isEmpty)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.1))
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
        let raw = await recognizeText(from: image)
        statusMessage = "Identifying landmark…"
        let normalized = await normalizeLandmarkName(from: raw)
        signText = normalized
        statusMessage = ""
        isProcessing = false
    }

    private func lookUp() async {
        isSignTextFocused = false
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

        // Show the top candidate's raw card immediately, then enrich.
        result = first
        statusMessage = ""
        await selectCandidate(first, query: trimmed)
        isSearching = false
    }

    /// Run phase-2 enrichment for the given candidate, replace the
    /// current `result` with the enriched version, and upsert it into
    /// SwiftData history. Used both from initial lookup and from tapping
    /// an alternative in the "Other matches" list.
    private func selectCandidate(_ candidate: LandmarkResult, query: String) async {
        let enriched = await enrichLandmark(candidate, query: query)
        // Only replace if we're still on the same candidate (user may
        // have tapped a different one in the meantime).
        if result?.pageURL == candidate.pageURL {
            result = enriched
        } else {
            // User switched — still upsert the enriched value so it
            // lands in history even if they moved on.
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

    /// Called when the user taps an alternative in the "Other matches"
    /// list on the result card.
    private func switchTo(_ alt: LandmarkResult) {
        // Show the alternative immediately (with its raw summary) while
        // we enrich in the background.
        result = alt
        savedLookup = nil
        statusMessage = ""
        let trimmed = signText.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
