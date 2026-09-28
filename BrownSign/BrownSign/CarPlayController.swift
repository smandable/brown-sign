//
//  CarPlayController.swift
//  BrownSign
//
//  Brown Sign in the car, as a CarPlay audio app with two tabs. Nearby
//  lists the closest landmarks under Play nearby and Narrate as I drive;
//  History lists the user's finds. Tapping a landmark reads its story and
//  opens Now Playing. The screens are CarPlay's own templates; this class
//  feeds them data and hands taps to LandmarkNarrator.
//

import CarPlay
import SwiftData

@MainActor
final class CarPlayController: NSObject {
    private let interfaceController: CPInterfaceController
    private let nearbyTemplate: CPListTemplate
    private let historyTemplate: CPListTemplate
    private let tabBar: CPTabBarTemplate
    private var upNextTemplate: CPListTemplate?

    private var notificationTokens: [NSObjectProtocol] = []
    private var locationObserver: UUID?
    private var isVisible = true

    /// Row objects reused across renders so thumbnails don't reload and flash.
    private var rows: [String: CPListItem] = [:]
    private var imageRequests: Set<String> = []
    /// The Nearby rows on screen, for updating distances in place.
    private var nearbyShown: [(item: NarrationItem, row: CPListItem)] = []
    /// Where the Nearby list was last sorted, and where its distances were last measured.
    private var lastSortedFrom: CLLocation?
    private var lastMeasuredFrom: CLLocation?

    /// Most rows per list: CarPlay's own cap, and enough to scan at a glance.
    private var rowLimit: Int { min(24, Int(CPListTemplate.maximumItemCount)) }
    /// Re-sort the Nearby list after moving this far; in between, only the
    /// distances update, so rows don't reshuffle under the driver's finger.
    private static let resortDistance: CLLocationDistance = 1_500
    private static let remeasureDistance: CLLocationDistance = 300

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        nearbyTemplate = CPListTemplate(title: "Nearby", sections: [])
        nearbyTemplate.tabTitle = "Nearby"
        nearbyTemplate.tabImage = UIImage(systemName: "map")
        historyTemplate = CPListTemplate(title: "History", sections: [])
        historyTemplate.tabTitle = "History"
        historyTemplate.tabImage = UIImage(systemName: "clock")
        tabBar = CPTabBarTemplate(templates: [nearbyTemplate, historyTemplate])
        super.init()
    }

    // MARK: - Lifecycle

    func connect() {
        interfaceController.delegate = self
        tabBar.delegate = self
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.upNextTitle = "Up Next"
        nowPlaying.isUpNextButtonEnabled = !LandmarkNarrator.shared.upNext.isEmpty

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: LandmarkNarrator.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.narratorChanged() }
            },
            center.addObserver(forName: NearbyStation.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderNearby() }
            },
            // A find saved or a landmark hidden on the phone mid-drive.
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.renderHistory()
                    self?.renderNearby()
                }
            },
            // Location allowed (or revoked) on the phone while the car shows Nearby.
            center.addObserver(forName: DriveLocationTracker.authorizationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setVisible(self.isVisible)
                }
            },
        ]

        let tracker = DriveLocationTracker.shared
        locationObserver = tracker.addObserver { [weak self] location in
            self?.locationChanged(location)
        }
        setVisible(true)
        renderNearby()
        renderHistory()
    }

    func disconnect() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens = []
        if let locationObserver {
            DriveLocationTracker.shared.removeObserver(locationObserver)
        }
        locationObserver = nil
        DriveLocationTracker.shared.stop(for: .carPlayList)
        CPNowPlayingTemplate.shared.remove(self)
        LandmarkNarrator.shared.carPlayDidDisconnect()
    }

    /// The car screen shows Brown Sign (true) or another app (false). The
    /// list's own location updates run only while it can be seen.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        let tracker = DriveLocationTracker.shared
        if visible {
            tracker.start(for: .carPlayList)
            if let location = tracker.freshestLocation {
                Task { await NearbyStation.shared.refreshIfNeeded(around: location) }
            }
            renderNearby()
        } else {
            tracker.stop(for: .carPlayList)
        }
    }

    private func locationChanged(_ location: CLLocation) {
        guard isVisible else { return }
        // The pool follows the car; a fresh fetch re-renders via the station.
        Task { await NearbyStation.shared.refreshIfNeeded(around: location) }
        if let sorted = lastSortedFrom, location.distance(from: sorted) < Self.resortDistance {
            if let measured = lastMeasuredFrom, location.distance(from: measured) >= Self.remeasureDistance {
                updateNearbyDistances(from: location)
            }
        } else {
            renderNearby()
        }
    }

    private func narratorChanged() {
        let narrator = LandmarkNarrator.shared
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = !narrator.upNext.isEmpty
        renderNearby()
        renderHistory()
        if let upNextTemplate {
            upNextTemplate.updateSections(upNextSections())
        }
    }

    // MARK: - Nearby

    private func renderNearby() {
        let tracker = DriveLocationTracker.shared
        guard tracker.isAuthorized else {
            nearbyShown = []
            showEmpty(
                nearbyTemplate,
                title: ["Location is off"],
                subtitle: [
                    "Allow location for Brown Sign on your iPhone once you're parked.",
                    "Allow location on your iPhone when parked.",
                ]
            )
            return
        }

        let station = NearbyStation.shared
        let location = tracker.freshestLocation
        let sorted = station.sortedByDistance(from: location)
        let landmarks = Array(sorted.prefix(max(0, rowLimit - 2)))
        lastSortedFrom = location
        lastMeasuredFrom = location

        if landmarks.isEmpty {
            nearbyShown = []
            switch station.status {
            case .idle, .loading:
                showEmpty(nearbyTemplate, title: ["Finding landmarks near you", "Finding landmarks"], spinner: true)
            case .failed:
                nearbyTemplate.updateSections([CPListSection(items: [retryRow()])])
            case .loaded, .empty:
                let none = CPListItem(text: "No landmarks nearby yet", detailText: "Brown Sign keeps looking as you drive.")
                none.isEnabled = false
                nearbyTemplate.updateSections([
                    CPListSection(items: [autoNarrationRow()]),
                    CPListSection(items: [none]),
                ])
            }
            return
        }

        let narrator = LandmarkNarrator.shared
        nearbyShown = landmarks.map { entry in
            let item = NarrationItem(result: entry.result)
            let row = row(for: item, in: .nearby)
            row.setDetailText(nearbyDetail(for: item, meters: entry.meters))
            row.isPlaying = narrator.current?.id == item.id
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    let result = await LandmarkNarrator.shared.playNearby(startingWith: item)
                    completion()
                    self?.handle(result)
                }
            }
            return (item, row)
        }
        nearbyTemplate.updateSections([
            CPListSection(items: [playNearbyRow(), autoNarrationRow()]),
            CPListSection(
                items: nearbyShown.map(\.row),
                header: "Within \(formatRadius(miles: station.radiusMiles))",
                sectionIndexTitle: nil
            ),
        ])
    }

    private func updateNearbyDistances(from location: CLLocation) {
        lastMeasuredFrom = location
        for (item, row) in nearbyShown {
            row.setDetailText(nearbyDetail(for: item, meters: item.location.map { location.distance(from: $0) }))
        }
    }

    private func nearbyDetail(for item: NarrationItem, meters: CLLocationDistance?) -> String? {
        var parts: [String] = []
        if let meters { parts.append(formatLandmarkDistance(meters)) }
        if HeardLandmarks.shared.wasHeardRecently(item.id) { parts.append("Played") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func playNearbyRow() -> CPListItem {
        let narrator = LandmarkNarrator.shared
        let playingNearby = narrator.program == .nearby && narrator.current != nil
        let row = CPListItem(
            text: "Play nearby",
            detailText: playingNearby
                ? "Playing: \(narrator.current?.title ?? "")"
                : "Closest landmarks, one after another",
            image: LandmarkArtwork.actionTile(systemName: "play.fill", size: rowImageSize, scale: displayScale)
        )
        row.isPlaying = playingNearby && narrator.isPlaying
        row.playingIndicatorLocation = .trailing
        row.handler = { [weak self] _, completion in
            Task { @MainActor in
                let narrator = LandmarkNarrator.shared
                if narrator.program == .nearby, narrator.current != nil {
                    narrator.resume()
                    completion()
                    self?.showNowPlaying()
                    return
                }
                let result = await narrator.playNearby()
                completion()
                self?.handle(result)
            }
        }
        return row
    }

    private func autoNarrationRow() -> CPListItem {
        let enabled = LandmarkNarrator.shared.autoNarrationEnabled
        let check = UIImage(systemName: "checkmark.circle.fill")?
            .withTintColor(UIColor(named: "AccentButton") ?? .systemGreen, renderingMode: .alwaysOriginal)
        let row = CPListItem(
            text: "Narrate as I drive",
            detailText: enabled
                ? "On · Hear landmarks as you approach them"
                : "Off · Hear landmarks as you approach them",
            image: LandmarkArtwork.actionTile(systemName: "car.fill", size: rowImageSize, scale: displayScale),
            accessoryImage: enabled ? check : nil,
            accessoryType: .none
        )
        row.handler = { [weak self] _, completion in
            let narrator = LandmarkNarrator.shared
            if !narrator.setAutoNarration(!narrator.autoNarrationEnabled) {
                self?.showAlert([
                    "Brown Sign needs your location for this. Allow it on your iPhone once you're parked.",
                    "Location is off for Brown Sign.",
                ])
            }
            completion()
        }
        return row
    }

    private func retryRow() -> CPListItem {
        let row = CPListItem(
            text: "Try again",
            detailText: "Couldn't reach the landmark service",
            image: LandmarkArtwork.actionTile(systemName: "arrow.clockwise", size: rowImageSize, scale: displayScale)
        )
        row.handler = { _, completion in
            Task { @MainActor in
                if let location = DriveLocationTracker.shared.freshestLocation {
                    await NearbyStation.shared.refreshIfNeeded(around: location, force: true)
                }
                completion()
            }
        }
        return row
    }

    // MARK: - History

    private func renderHistory() {
        var descriptor = FetchDescriptor<LandmarkLookup>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = rowLimit
        let lookups = (try? AppModelContainer.shared.mainContext.fetch(descriptor)) ?? []
        guard !lookups.isEmpty else {
            showEmpty(
                historyTemplate,
                title: ["No finds yet"],
                subtitle: [
                    "Landmarks you scan or open on your iPhone show up here.",
                    "Your finds show up here.",
                ]
            )
            return
        }

        let items = lookups.map(NarrationItem.init(lookup:))
        let here = DriveLocationTracker.shared.freshestLocation
        let narrator = LandmarkNarrator.shared
        let historyRows = zip(lookups, items).enumerated().map { index, pair in
            let (lookup, item) = pair
            let row = row(for: item, in: .history)
            var detail = [relativeFindTimestamp(lookup.date)]
            if let here, let there = item.location {
                detail.append(formatLandmarkDistance(here.distance(from: there)))
            }
            row.setDetailText(detail.joined(separator: " · "))
            row.isPlaying = narrator.current?.id == item.id
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    let result = await LandmarkNarrator.shared.play(items, startingAt: index, title: "History")
                    completion()
                    self?.handle(result)
                }
            }
            return row
        }
        historyTemplate.updateSections([CPListSection(items: historyRows)])
    }

    // MARK: - Up Next

    private func upNextSections() -> [CPListSection] {
        let here = DriveLocationTracker.shared.freshestLocation
        let upNextRows = LandmarkNarrator.shared.upNext.map { item in
            let row = row(for: item, in: .upNext)
            if let here, let there = item.location {
                row.setDetailText(formatLandmarkDistance(here.distance(from: there)))
            } else {
                row.setDetailText(nil)
            }
            row.isPlaying = false
            row.handler = { [weak self] _, completion in
                LandmarkNarrator.shared.jump(to: item)
                completion()
                self?.interfaceController.popTemplate(animated: true, completion: nil)
            }
            return row
        }
        return [CPListSection(items: upNextRows)]
    }

    // MARK: - Shared

    /// The lists a row can belong to. A landmark can sit in Nearby, History
    /// and Up Next at once, and a CarPlay row object must only ever belong
    /// to one template, so each list keeps its own.
    private enum RowList: String {
        case nearby, history, upNext
    }

    /// One reusable row per landmark per list, created with the signpost
    /// placeholder and upgraded to the landmark's photo when it loads.
    private func row(for item: NarrationItem, in list: RowList) -> CPListItem {
        let key = "\(list.rawValue)|\(item.id)"
        if let existing = rows[key] { return existing }
        let row = CPListItem(
            text: item.title,
            detailText: nil,
            image: LandmarkArtwork.placeholder(size: rowImageSize, scale: displayScale)
        )
        row.playingIndicatorLocation = .trailing
        rows[key] = row
        if !imageRequests.contains(key) {
            imageRequests.insert(key)
            let size = rowImageSize
            let scale = displayScale
            Task {
                if let image = await LandmarkArtwork.rowThumbnail(for: item, size: size, scale: scale) {
                    row.setImage(image)
                }
            }
        }
        return row
    }

    private var rowImageSize: CGSize { CPListItem.maximumImageSize }

    private var displayScale: CGFloat {
        max(1, interfaceController.carTraitCollection.displayScale)
    }

    private func showEmpty(_ template: CPListTemplate, title: [String], subtitle: [String] = [], spinner: Bool = false) {
        template.emptyViewTitleVariants = title
        template.emptyViewSubtitleVariants = subtitle
        template.showsSpinnerWhileEmpty = spinner
        template.updateSections([])
    }

    private func handle(_ result: LandmarkNarrator.StartResult) {
        switch result {
        case .started:
            showNowPlaying()
        case .needsLocation:
            showAlert([
                "Brown Sign needs your location to find nearby landmarks. Allow it on your iPhone once you're parked.",
                "Location is off for Brown Sign.",
            ])
        case .locationUnavailable:
            showAlert(["Brown Sign can't find your location right now. Try again in a moment.", "Can't find your location."])
        case .nothingNearby:
            showAlert(["No landmarks nearby yet. Brown Sign keeps looking as you drive.", "No landmarks nearby yet."])
        case .audioUnavailable:
            showAlert(["Brown Sign can't play right now. Try again in a moment.", "Can't play right now."])
        }
    }

    private func showNowPlaying() {
        guard !(interfaceController.topTemplate is CPNowPlayingTemplate) else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func showAlert(_ titleVariants: [String]) {
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(
            CPAlertTemplate(titleVariants: titleVariants, actions: [ok]),
            animated: true,
            completion: nil
        )
    }
}

// MARK: - Template delegates

extension CarPlayController: CPInterfaceControllerDelegate {
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === nearbyTemplate {
            renderNearby()
        } else if aTemplate === historyTemplate {
            renderHistory()
        }
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === upNextTemplate {
            upNextTemplate = nil
        }
    }
}

extension CarPlayController: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === nearbyTemplate {
            renderNearby()
        } else if selectedTemplate === historyTemplate {
            renderHistory()
        }
    }
}

extension CarPlayController: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let template = CPListTemplate(title: "Up Next", sections: upNextSections())
        upNextTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
}
