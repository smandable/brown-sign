//
//  BrownSignApp.swift
//  BrownSign
//

import SwiftUI
import SwiftData

@main
struct BrownSignApp: App {
    /// Installed only to receive Home Screen quick actions (see
    /// AppDelegate.swift); SwiftUI keeps ownership of the scene.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Every launcher surface (Siri/App Shortcuts, the Control Center
    /// scan button, quick actions, brownsign:// URLs) funnels into
    /// the router; the TabView and ContentView observe it.
    private let router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            @Bindable var router = router
            TabView(selection: $router.selectedTab) {
                Tab("Scan", systemImage: "camera.fill", value: AppTab.scan) {
                    ContentView()
                }
                Tab("Nearby", systemImage: "map.fill", value: AppTab.nearby) {
                    NearMeView()
                }
                Tab("History", systemImage: "clock.fill", value: AppTab.history) {
                    HistoryView()
                }
            }
            .onOpenURL { router.handle(url: $0) }
            // Pre-warm the GPS at app launch so the Nearby tab doesn't
            // pay cold-radio first-fix latency (2–10 s on a fresh
            // launch) before the SPARQL fetch can fire. No-op if the
            // user hasn't granted permission yet — the system prompt
            // still appears in-context when they open Nearby.
            .task {
                LocationManager.shared.warmUpIfAuthorized()
            }
        }
        .modelContainer(for: [LandmarkLookup.self, HiddenLandmark.self])
    }
}
