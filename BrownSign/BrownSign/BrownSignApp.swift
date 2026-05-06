//
//  BrownSignApp.swift
//  BrownSign
//

import SwiftUI
import SwiftData

@main
struct BrownSignApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Scan", systemImage: "camera.fill") {
                    ContentView()
                }
                Tab("Nearby", systemImage: "map.fill") {
                    NearMeView()
                }
                Tab("History", systemImage: "clock.fill") {
                    HistoryView()
                }
            }
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
