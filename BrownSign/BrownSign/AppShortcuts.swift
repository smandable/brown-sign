//
//  AppShortcuts.swift
//  BrownSign
//
//  Siri / Spotlight / Shortcuts-app surface for the launch intents.
//  App target only: the build extracts phrases from the app bundle,
//  never from extensions. Phrase changes ship only with a new build,
//  and every phrase must contain \(.applicationName) or Siri won't
//  recognize it.
//

import AppIntents

struct OpenNearbyIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Nearby Landmarks"
    static let description = IntentDescription(
        "Shows landmarks around your current location."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.nearby)
        return .result()
    }
}

struct BrownSignShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanSignIntent(),
            phrases: [
                "Scan a sign with \(.applicationName)",
                "Scan a sign in \(.applicationName)",
                "Scan with \(.applicationName)",
                "\(.applicationName) scan",
            ],
            shortTitle: "Scan a Sign",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: OpenNearbyIntent(),
            phrases: [
                "Landmarks near me in \(.applicationName)",
                "Show landmarks near me in \(.applicationName)",
                "What's nearby in \(.applicationName)",
                "Find landmarks with \(.applicationName)",
            ],
            shortTitle: "Nearby Landmarks",
            systemImageName: "map.fill"
        )
    }
}
