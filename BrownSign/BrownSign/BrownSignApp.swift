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
                ContentView()
                    .tabItem {
                        Label("Scan", systemImage: "camera.fill")
                    }

                NearMeView()
                    .tabItem {
                        Label("Nearby", systemImage: "map.fill")
                    }

                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.fill")
                    }
            }
        }
        .modelContainer(for: LandmarkLookup.self)
    }
}
