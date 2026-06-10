//
//  LaunchIntents.swift
//  BrownSign
//
//  The Control Center button's launch intent. Compiled into BOTH the
//  app and the widget extension — required for the control to open
//  the app; the system runs `perform()` in the app process, where
//  AppRouter drives navigation. Intents that DON'T back the control
//  (OpenNearbyIntent) live in the app-only AppShortcuts.swift so the
//  extension doesn't register duplicate discoverable copies.
//

import AppIntents

struct ScanSignIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a Sign"
    static let description = IntentDescription(
        "Opens the camera to scan a roadside landmark sign."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openScanCamera()
        return .result()
    }
}
