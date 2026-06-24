//
//  BrownSignApp.swift
//  BrownSign
//

import SwiftUI
import SwiftData
import UIKit

/// Rasterizes an SF Symbol into a plain template bitmap for a tab bar icon.
/// iOS 26's tab bar force-fills SF Symbol tab items (it substitutes the
/// `.fill` variant no matter what symbol name or `.symbolVariant` we pass),
/// so to keep INACTIVE tabs outline we strip the symbol metadata by drawing
/// the glyph into a bitmap — a bitmap has no variant to substitute.
/// `.alwaysTemplate` keeps it tinted by the tab bar (accent when selected,
/// secondary otherwise). Pass the `.fill` name for the active tab, the
/// outline name for the rest.
private func tabBarIcon(_ systemName: String) -> Image {
    let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    let symbol = UIImage(systemName: systemName, withConfiguration: config) ?? UIImage()
    let rendered = UIGraphicsImageRenderer(size: symbol.size).image { _ in
        symbol.draw(in: CGRect(origin: .zero, size: symbol.size))
    }.withRenderingMode(.alwaysTemplate)
    return Image(uiImage: rendered)
}

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
                // Selected tab = filled glyph, others = outline (per the mock).
                // Rasterized via tabBarIcon() so iOS 26's tab bar can't
                // force-fill the inactive ones; the icon is recomputed from
                // router.selectedTab so it swaps as you change tabs.
                Tab(value: AppTab.scan) {
                    ContentView()
                } label: {
                    Label {
                        Text("Scan")
                    } icon: {
                        tabBarIcon(router.selectedTab == .scan ? "camera.fill" : "camera")
                    }
                }
                Tab(value: AppTab.nearby) {
                    NearMeView()
                } label: {
                    Label {
                        Text("Nearby")
                    } icon: {
                        tabBarIcon(router.selectedTab == .nearby ? "map.fill" : "map")
                    }
                }
                Tab(value: AppTab.history) {
                    HistoryView()
                } label: {
                    Label {
                        Text("History")
                    } icon: {
                        tabBarIcon(router.selectedTab == .history ? "clock.fill" : "clock")
                    }
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
