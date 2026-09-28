//
//  LandmarkNarrator.swift
//  BrownSign
//
//  Listen: reads landmark stories aloud with the on-device speech
//  synthesizer. One narrator serves the iPhone (the detail view's Listen
//  button, the Nearby toolbar), CarPlay and Siri. It owns the playback
//  queue, publishes Now Playing info, answers the lock screen, steering
//  wheel and CarPlay controls, and keeps the audio session polite: active
//  only while it has something to say, paused for calls and navigation
//  prompts, and released so the listener's own audio comes back after.
//

import AVFoundation
import CoreLocation
import MediaPlayer
import UIKit

@MainActor
@Observable
final class LandmarkNarrator: NSObject {
    static let shared = LandmarkNarrator()
    /// Posted on every state change, for the CarPlay templates (which
    /// aren't SwiftUI views and can't observe the narrator directly).
    static let didChangeNotification = Notification.Name("LandmarkNarratorDidChange")

    enum Program: Equatable {
        /// Play nearby: after each landmark, the closest one not yet heard,
        /// measured from wherever the listener is by then.
        case nearby
        /// A fixed list in order: History, a panned Nearby area, or one
        /// landmark from its detail view.
        case list(title: String)
        /// One landmark Narrate as I drive picked as the car approached it.
        case approaching
    }

    enum StartResult {
        case started
        /// No location permission.
        case needsLocation
        /// Permission, but no fix to work from.
        case locationUnavailable
        case nothingNearby
        case audioUnavailable
    }

    private(set) var program: Program?
    private(set) var current: NarrationItem?
    /// Speaking right now (false while paused).
    private(set) var isPlaying = false
    private(set) var autoNarrationEnabled = false
    /// What plays after `current`, for CarPlay's Up Next.
    private(set) var upNext: [NarrationItem] = []

    /// A landmark is loaded, playing or paused.
    var isActive: Bool { current != nil }

    /// Pause between landmarks, so one story doesn't run into the next.
    private static let gapBetweenLandmarks: Duration = .seconds(1.2)
    /// Quiet time after an automatic narration before the next may start,
    /// so a dense downtown doesn't become one unbroken lecture.
    private static let automaticCooldown: TimeInterval = 20
    /// Narrate as I drive turns itself off after this long without moving
    /// (the car is parked), so it doesn't hold location from a pocket all day.
    private static let parkedTimeout: TimeInterval = 20 * 60
    /// Default-rate English runs about 15 characters a second; refined per
    /// landmark from the synthesizer's own progress once it's under way.
    private static let defaultCharactersPerSecond = 15.0

    @ObservationIgnored private var synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var listQueue: [NarrationItem] = []
    @ObservationIgnored private var listIndex = 0
    /// Landmarks played in the current program, for Previous.
    @ObservationIgnored private var played: [NarrationItem] = []
    @ObservationIgnored private var heardThisSession: Set<String> = []
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    /// Paused in the gap between landmarks: Resume moves on to the next.
    @ObservationIgnored private var pendingAdvance = false
    @ObservationIgnored private var isStartingAutomatic = false
    @ObservationIgnored private var speakGeneration = 0
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var remoteCommandsRegistered = false
    @ObservationIgnored private var locationObserver: UUID?
    @ObservationIgnored private var lastAutomaticFinish: Date?
    @ObservationIgnored private var autoEnabledAt = Date()
    @ObservationIgnored private var lastMovement: (location: CLLocation, date: Date)?
    @ObservationIgnored private var parkedWatch: Task<Void, Never>?

    // Now Playing bookkeeping.
    @ObservationIgnored private var scriptLength = 1
    @ObservationIgnored private var speakingSince: Date?
    @ObservationIgnored private var spokenTime: TimeInterval = 0
    @ObservationIgnored private var estimatedDuration: TimeInterval = 60
    @ObservationIgnored private var lastProgressPublish = Date.distantPast
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artistLine = ""

    private override init() {
        super.init()
        synthesizer.delegate = self
        observeNotifications()
    }

    // MARK: - Starting

    /// Play nearby: `first` (a tapped row) or the closest landmark not yet
    /// heard, then the next closest from wherever the listener is by then.
    @discardableResult
    func playNearby(startingWith first: NarrationItem? = nil) async -> StartResult {
        let tracker = DriveLocationTracker.shared
        guard tracker.isAuthorized else { return .needsLocation }
        retainLocation()
        let item: NarrationItem
        if let first {
            item = first
        } else {
            let station = NearbyStation.shared
            var location = tracker.freshestLocation
            if location == nil {
                location = await LocationManager.shared.currentLocation(withTimeout: LocationManager.nearbyTimeout)
            }
            if let location { await station.refreshIfNeeded(around: location) }
            guard let pick = station.nextForStation(from: location, excluding: heardThisSession) else {
                releaseLocationIfIdle()
                return location == nil ? .locationUnavailable : .nothingNearby
            }
            item = NarrationItem(result: pick)
        }
        return await begin(.nearby, with: item, style: .plain)
    }

    /// Plays `items` in order from `index`: History, a panned Nearby area,
    /// or a single landmark.
    @discardableResult
    func play(_ items: [NarrationItem], startingAt index: Int = 0, title: String) async -> StartResult {
        guard items.indices.contains(index) else { return .nothingNearby }
        listQueue = items
        listIndex = index
        return await begin(.list(title: title), with: items[index], style: .plain)
    }

    /// The detail view's Listen button: start this landmark, or pause and
    /// resume it when it's the one already playing.
    func toggle(_ item: NarrationItem) {
        if current?.id == item.id {
            togglePlayPause()
        } else {
            Task { await play([item], title: item.title) }
        }
    }

    /// Siri's "Play nearby landmarks": resumes Play nearby if it's already
    /// the program, otherwise starts it.
    func startNearbyForSiri() async -> StartResult {
        if program == .nearby, current != nil {
            resume()
            return .started
        }
        return await playNearby()
    }

    /// Narrate as I drive: stay quiet until the car nears a landmark the
    /// listener hasn't heard recently, tell its story, then hand the audio
    /// back. Returns false when location access is missing.
    @discardableResult
    func setAutoNarration(_ enabled: Bool) -> Bool {
        guard enabled != autoNarrationEnabled else { return true }
        if enabled {
            guard DriveLocationTracker.shared.isAuthorized else { return false }
            autoNarrationEnabled = true
            autoEnabledAt = Date()
            lastMovement = nil
            retainLocation()
            watchForParking()
            if let location = DriveLocationTracker.shared.freshestLocation {
                locationChanged(location)
            }
        } else {
            autoNarrationEnabled = false
            parkedWatch?.cancel()
            parkedWatch = nil
            releaseLocationIfIdle()
        }
        postChange()
        return true
    }

    /// Siri's "Stop narrating": everything off.
    func stopEverything() {
        setAutoNarration(false)
        finish()
    }

    /// The car's gone: stop watching for landmarks from a pocket.
    func carPlayDidDisconnect() {
        setAutoNarration(false)
    }

    private func begin(_ program: Program, with item: NarrationItem, style: NarrationScript.LeadStyle) async -> StartResult {
        advanceTask?.cancel()
        advanceTask = nil
        pendingAdvance = false
        if self.program != program { played = [] }
        self.program = program
        guard await speak(item, style: style) else {
            finish()
            return .audioUnavailable
        }
        return .started
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard current != nil, isPlaying else { return }
        if utterance != nil {
            synthesizer.pauseSpeaking(at: .word)
        } else if advanceTask != nil {
            advanceTask?.cancel()
            advanceTask = nil
            pendingAdvance = true
        }
        if let since = speakingSince { spokenTime += Date().timeIntervalSince(since) }
        speakingSince = nil
        isPlaying = false
        publishNowPlaying()
        postChange()
    }

    func resume() {
        guard let current, !isPlaying else { return }
        guard activateSession() else { return }
        isPlaying = true
        if pendingAdvance {
            pendingAdvance = false
            advance(after: .zero)
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            speakingSince = Date()
        } else {
            // The synthesizer lost its place (an interruption can stop it
            // outright): start this landmark over.
            restart(current)
            return
        }
        publishNowPlaying()
        postChange()
    }

    func skipToNext() {
        guard current != nil else { return }
        pendingAdvance = false
        silenceSynthesizer()
        guard activateSession() else { return }
        isPlaying = true
        advance(after: .zero)
        postChange()
    }

    /// Like a music player: back to the start of this landmark, or to the
    /// previous one when pressed within the first few seconds.
    func skipToPrevious() {
        guard let current else { return }
        var target = current
        if currentElapsed < 4, played.count >= 2 {
            played.removeLast()
            target = played.removeLast()
            if case .list = program, listIndex > 0 { listIndex -= 1 }
        }
        restart(target)
    }

    /// Up Next selection: play `item` now, keeping the program.
    func jump(to item: NarrationItem) {
        if case .list = program, let index = listQueue.firstIndex(where: { $0.id == item.id }) {
            listIndex = index
        }
        restart(item)
    }

    func stop() {
        finish()
    }

    private func restart(_ item: NarrationItem) {
        advanceTask?.cancel()
        advanceTask = nil
        pendingAdvance = false
        let style: NarrationScript.LeadStyle = program == .approaching ? .approaching : .plain
        Task {
            if !(await speak(item, style: style)) { finish() }
        }
    }

    // MARK: - Speaking

    private func speak(_ original: NarrationItem, style: NarrationScript.LeadStyle) async -> Bool {
        speakGeneration += 1
        let generation = speakGeneration
        var item = original
        // Legacy History rows can predate the summary fallback.
        if item.summary.isEmpty, let fetched = await wikipediaRESTSummaryExtract(for: item.title), !fetched.isEmpty {
            item = item.withSummary(fetched)
        }
        // A newer request (another tap, Next) arrived during the fetch; it wins.
        guard generation == speakGeneration else { return true }
        guard activateSession() else { return false }
        registerRemoteCommands()
        silenceSynthesizer()

        let text = NarrationScript.script(for: item, from: DriveLocationTracker.shared.freshestLocation, style: style)
        let next = AVSpeechUtterance(string: text)
        next.voice = NarrationVoice.preferred
        utterance = next
        scriptLength = max(1, (text as NSString).length)
        spokenTime = 0
        speakingSince = Date()
        estimatedDuration = Double(scriptLength) / Self.defaultCharactersPerSecond
        current = item
        if played.last?.id != item.id { played.append(item) }
        heardThisSession.insert(item.id)
        HeardLandmarks.shared.markHeard(item.id)
        isPlaying = true
        artistLine = makeArtistLine(for: item)
        artwork = nil
        synthesizer.speak(next)
        refreshUpNext()
        publishNowPlaying()
        postChange()
        loadArtwork(for: item)
        return true
    }

    /// Stops speech without it counting as a finish: `utterance` is cleared
    /// first, so the delegate's callback for it is ignored.
    private func silenceSynthesizer() {
        utterance = nil
        speakingSince = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func utteranceFinished(_ id: ObjectIdentifier) {
        guard let utterance, ObjectIdentifier(utterance) == id else { return }
        self.utterance = nil
        if let since = speakingSince { spokenTime += Date().timeIntervalSince(since) }
        speakingSince = nil
        advance(after: Self.gapBetweenLandmarks)
    }

    private func advance(after gap: Duration) {
        advanceTask?.cancel()
        switch program {
        case .list:
            let nextIndex = listIndex + 1
            guard listQueue.indices.contains(nextIndex) else {
                finish()
                return
            }
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: gap)
                guard let self, !Task.isCancelled else { return }
                self.listIndex = nextIndex
                if !(await self.speak(self.listQueue[nextIndex], style: .plain)) { self.finish() }
            }
        case .nearby:
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: gap)
                guard let self, !Task.isCancelled else { return }
                let location = DriveLocationTracker.shared.freshestLocation
                let station = NearbyStation.shared
                if let location { await station.refreshIfNeeded(around: location) }
                var pick = station.nextForStation(from: location, excluding: self.heardThisSession)
                if pick == nil, let location {
                    // Ran dry around the last fetch: look again from here.
                    await station.refreshIfNeeded(around: location, force: true)
                    pick = station.nextForStation(from: location, excluding: self.heardThisSession)
                }
                guard !Task.isCancelled else { return }
                guard let pick else {
                    self.finish()
                    return
                }
                if !(await self.speak(NarrationItem(result: pick), style: .plain)) { self.finish() }
            }
        case .approaching, nil:
            finish()
        }
    }

    /// Ends the program: silence, clear Now Playing, and release the audio
    /// session so the listener's own audio resumes.
    private func finish() {
        advanceTask?.cancel()
        advanceTask = nil
        pendingAdvance = false
        silenceSynthesizer()
        if program == .approaching { lastAutomaticFinish = Date() }
        program = nil
        current = nil
        isPlaying = false
        upNext = []
        listQueue = []
        played = []
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        deactivateSession()
        releaseLocationIfIdle()
        postChange()
    }

    private func refreshUpNext() {
        switch program {
        case .list:
            upNext = Array(listQueue.dropFirst(listIndex + 1).prefix(12))
        case .nearby:
            upNext = NearbyStation.shared
                .upcoming(from: DriveLocationTracker.shared.freshestLocation, excluding: heardThisSession, count: 8)
                .map(NarrationItem.init(result:))
        case .approaching, nil:
            upNext = []
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Location

    private func retainLocation() {
        DriveLocationTracker.shared.start(for: .narration)
        guard locationObserver == nil else { return }
        locationObserver = DriveLocationTracker.shared.addObserver { [weak self] location in
            self?.locationChanged(location)
        }
    }

    /// Location keeps running only for Play nearby and Narrate as I drive;
    /// a History or single-landmark program doesn't need it.
    private func releaseLocationIfIdle() {
        guard !autoNarrationEnabled, program != .nearby else { return }
        DriveLocationTracker.shared.stop(for: .narration)
        if let locationObserver {
            DriveLocationTracker.shared.removeObserver(locationObserver)
        }
        locationObserver = nil
    }

    private func locationChanged(_ location: CLLocation) {
        if lastMovement.map({ location.distance(from: $0.location) >= 200 }) ?? true {
            lastMovement = (location, Date())
        }
        guard autoNarrationEnabled || program == .nearby else { return }
        // Keep the pool around the listener as they drive.
        Task { await NearbyStation.shared.refreshIfNeeded(around: location) }

        guard autoNarrationEnabled, current == nil, !isStartingAutomatic else { return }
        if let last = lastAutomaticFinish, Date().timeIntervalSince(last) < Self.automaticCooldown { return }
        guard let pick = NearbyStation.shared.nextApproaching(from: location, excluding: heardThisSession) else { return }
        isStartingAutomatic = true
        Task {
            _ = await begin(.approaching, with: NarrationItem(result: pick), style: .approaching)
            isStartingAutomatic = false
        }
    }

    private func watchForParking() {
        parkedWatch?.cancel()
        parkedWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled, self.autoNarrationEnabled else { return }
                let lastMoved = self.lastMovement?.date ?? self.autoEnabledAt
                if self.current == nil, Date().timeIntervalSince(lastMoved) > Self.parkedTimeout {
                    self.setAutoNarration(false)
                    return
                }
            }
        }
    }

    // MARK: - Audio session

    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // .spokenAudio: navigation prompts pause the story (and it picks
            // back up after) instead of talking over it.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            sessionActive = true
            return true
        } catch {
            return false
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // The synthesizer can still be winding down its audio: try once
            // more shortly, or the listener's music would stay paused.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !self.sessionActive else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: type, optionsRaw: options)
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones out, or the car's gone: pause rather than
                // carry on out of the phone's speaker.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mediaServicesWereReset()
            }
        }
        center.addObserver(forName: NearbyStation.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.program == .nearby else { return }
                self.refreshUpNext()
                self.postChange()
            }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // A call, Siri or a navigation prompt took the audio. Pause, so
            // the story picks up where it left off.
            resumeAfterInterruption = isPlaying
            pause()
            sessionActive = false
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if resumeAfterInterruption, options.contains(.shouldResume) {
                resume()
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    /// Every audio object is invalid after a media-services reset: start clean.
    private func mediaServicesWereReset() {
        finish()
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        sessionActive = false
        remoteCommandsRegistered = false
    }

    // MARK: - Now Playing and remote commands

    private func registerRemoteCommands() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        let handlers: [(MPRemoteCommand, () -> Void)] = [
            (center.playCommand, { [weak self] in self?.resume() }),
            (center.pauseCommand, { [weak self] in self?.pause() }),
            (center.togglePlayPauseCommand, { [weak self] in self?.togglePlayPause() }),
            (center.nextTrackCommand, { [weak self] in self?.skipToNext() }),
            (center.previousTrackCommand, { [weak self] in self?.skipToPrevious() }),
            (center.stopCommand, { [weak self] in self?.stop() }),
        ]
        for (command, action) in handlers {
            command.removeTarget(nil)
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                guard self?.current != nil else { return .noActionableNowPlayingItem }
                action()
                return .success
            }
        }
        // Speech has no meaningful seek or rate controls; hiding them keeps
        // the lock screen and CarPlay to play/pause and next/previous.
        let unsupported: [MPRemoteCommand] = [
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
            center.changeRepeatModeCommand, center.changeShuffleModeCommand,
            center.likeCommand, center.dislikeCommand, center.bookmarkCommand,
        ]
        for command in unsupported {
            command.isEnabled = false
        }
    }

    private var currentElapsed: TimeInterval {
        spokenTime + (speakingSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func publishNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: artistLine,
            MPMediaItemPropertyAlbumTitle: "Brown Sign",
            MPMediaItemPropertyPlaybackDuration: estimatedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(currentElapsed, estimatedDuration),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        if case .list = program, listQueue.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = listIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = listQueue.count
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// "Nearby · 0.8 mi" under the title on the lock screen and in CarPlay.
    private func makeArtistLine(for item: NarrationItem) -> String {
        var parts: [String] = []
        switch program {
        case .nearby:
            parts.append("Nearby")
        case .approaching:
            parts.append("Coming up")
        case .list(let title) where title != item.title:
            parts.append(title)
        default:
            break
        }
        if let here = DriveLocationTracker.shared.freshestLocation, let there = item.location,
           here.distance(from: there) <= NarrationScript.maxSpokenDistance {
            parts.append(formatLandmarkDistance(here.distance(from: there)))
        }
        return parts.isEmpty ? "Brown Sign" : parts.joined(separator: " · ")
    }

    private func loadArtwork(for item: NarrationItem) {
        Task {
            let image = await LandmarkArtwork.image(for: item, maxPixels: 600)
                ?? LandmarkArtwork.placeholder(size: CGSize(width: 300, height: 300), scale: 2)
            guard current?.id == item.id else { return }
            artwork = makeArtwork(image)
            publishNowPlaying()
        }
    }

    private func progressed(_ id: ObjectIdentifier, to location: Int) {
        guard let utterance, ObjectIdentifier(utterance) == id else { return }
        let elapsed = currentElapsed
        // Refine the duration from the actual pace once there's enough to go on.
        if elapsed > 5, location > 60 {
            let pace = Double(location) / elapsed
            estimatedDuration = max(elapsed + 1, Double(scriptLength) / pace)
        }
        if Date().timeIntervalSince(lastProgressPublish) > 5 {
            lastProgressPublish = Date()
            publishNowPlaying()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension LandmarkNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.utteranceFinished(id)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        let location = characterRange.location
        Task { @MainActor in
            self.progressed(id, to: location)
        }
    }
}

/// Built outside the main actor on purpose: MediaPlayer calls the request
/// handler from its own queue, where a main-actor closure would trap.
nonisolated private func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}

/// The narrator's voice: an Enhanced or Premium English voice when the
/// listener has downloaded one (Settings > Accessibility > Spoken Content >
/// Voices), their own region first; otherwise the system's default English
/// voice. Deliberately not "best of whatever's installed": iOS also carries
/// legacy and character voices (Fred, Eloquence's Grandpa) that rank the
/// same "default" quality as Samantha and sound far worse.
@MainActor
enum NarrationVoice {
    private static var cached: AVSpeechSynthesisVoice?
    private static var observer: NSObjectProtocol?

    static var preferred: AVSpeechSynthesisVoice? {
        if let cached { return cached }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { cached = nil }
            }
        }
        let region = Locale.preferredLanguages.first { $0.hasPrefix("en-") } ?? "en-US"
        let downloaded = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en")
                && $0.quality != .default
                && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            let language = voice.language == region ? 2 : (voice.language == "en-US" ? 1 : 0)
            return (language, voice.quality.rawValue)
        }
        cached = downloaded.max { rank($0) < rank($1) }
            ?? AVSpeechSynthesisVoice(language: region)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        return cached
    }
}
