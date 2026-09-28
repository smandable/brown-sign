//
//  ListenIntents.swift
//  BrownSign
//
//  Siri and Shortcuts for Listen: "Play nearby landmarks in Brown Sign",
//  plus switching Narrate as I drive on and off. AudioPlaybackIntent
//  lets them run without opening the app and start audio from the
//  background, which is what makes them work in the car. App target only,
//  like the other App Shortcuts (phrases are read from the app bundle).
//

import AppIntents

struct PlayNearbyLandmarksIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Nearby Landmarks"
    static let description = IntentDescription(
        "Reads the stories of landmarks near you aloud, closest first, and keeps going as you drive."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        switch await LandmarkNarrator.shared.startNearbyForSiri() {
        case .started:
            return .result()
        case .needsLocation:
            throw ListenIntentError.needsLocation
        case .locationUnavailable:
            throw ListenIntentError.locationUnavailable
        case .nothingNearby:
            throw ListenIntentError.nothingNearby
        case .audioUnavailable:
            throw ListenIntentError.audioUnavailable
        }
    }
}

struct NarrateAsIDriveIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Narrate Landmarks as I Drive"
    static let description = IntentDescription(
        "Tells you about each landmark as you approach it, then goes quiet until the next one."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let narrator = LandmarkNarrator.shared
        guard narrator.setAutoNarration(true) else {
            throw ListenIntentError.needsLocation
        }
        // Make sure location is actually flowing before promising anything:
        // from a background launch, iOS won't start updates for a When In
        // Use app, and the mode would otherwise sit silently doing nothing.
        guard await DriveLocationTracker.shared.waitForFreshFix() else {
            narrator.setAutoNarration(false)
            throw ListenIntentError.locationUnavailable
        }
        return .result(dialog: "Okay. Brown Sign will tell you about landmarks as you approach them.")
    }
}

struct StopNarratingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Stop Narrating Landmarks"
    static let description = IntentDescription(
        "Stops Brown Sign's narration and turns off Narrate as I drive."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        LandmarkNarrator.shared.stopEverything()
        return .result()
    }
}

enum ListenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case needsLocation
    case locationUnavailable
    case nothingNearby
    case audioUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .needsLocation:
            "Brown Sign needs your location to find nearby landmarks. You can allow it in the app once you're parked."
        case .locationUnavailable:
            "Brown Sign can't see your location right now. Open Brown Sign on the car screen, then try again."
        case .nothingNearby:
            "There aren't any landmarks near you right now."
        case .audioUnavailable:
            "Brown Sign can't play right now. Try again in a moment."
        }
    }
}
