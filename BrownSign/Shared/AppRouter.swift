//
//  AppRouter.swift
//  BrownSign
//
//  Compiled into BOTH the app and the widget extension (the Shared
//  folder is a member of each target): the Control Center button's
//  intent must exist in both bundles for the system to open the app,
//  and that intent routes through this type.
//

import Foundation
import Observation

/// Tab identity for the root TabView. Raw values double as the
/// deep-link path (`brownsign://scan`) and the Home Screen
/// quick-action type suffix (`com.seanmandable.brownsign.scan`).
enum AppTab: String, Hashable {
    case scan
    case nearby
    case history
}

/// A launcher request that needs more than a tab switch.
enum LaunchAction: Equatable {
    /// Select the Scan tab and raise the camera.
    case scanCamera
}

/// Single funnel for every launcher surface: Siri/App Shortcuts, the
/// Control Center scan button, Home Screen quick actions, and
/// brownsign:// URLs all land here, and the view layer observes it.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: AppTab = .scan

    /// Stored rather than fired: at cold launch the trigger (an App
    /// Intent's perform, the quick-action scene callback) runs before
    /// ContentView exists, so anything fire-and-forget would be
    /// dropped. ContentView consumes and clears this from both
    /// `onAppear` (cold launch) and `onChange` (warm launch).
    var pendingAction: LaunchAction?

    func open(_ tab: AppTab) {
        selectedTab = tab
    }

    func openScanCamera() {
        selectedTab = .scan
        pendingAction = .scanCamera
    }

    /// brownsign://scan | brownsign://nearby | brownsign://history.
    /// `scan` opens the camera, not just the tab — every launcher
    /// surface promises "straight into scanning".
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "brownsign" else { return }
        let destination = (url.host() ?? "").lowercased()
        switch AppTab(rawValue: destination) {
        case .scan:
            openScanCamera()
        case .nearby:
            open(.nearby)
        case .history:
            open(.history)
        case nil:
            break
        }
    }
}
