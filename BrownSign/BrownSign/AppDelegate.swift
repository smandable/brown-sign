//
//  AppDelegate.swift
//  BrownSign
//
//  Routes scenes to their delegates: the iPhone window to SceneDelegate,
//  which exists to receive Home Screen quick-action taps (SwiftUI has no
//  native hook for UIApplicationShortcutItem; SwiftUI still owns the
//  window and this pair only forwards to AppRouter), and the car screen
//  to CarPlaySceneDelegate.
//

import CarPlay
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            // Matches the Info.plist scene manifest entry.
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.sceneClass = CPTemplateApplicationScene.self
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            config.delegateClass = SceneDelegate.self
        }
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch from a quick action: `performActionFor` is NOT
    /// called; the item arrives only in the connection options.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem {
            AppRouter.shared.handle(shortcutItem: item)
        }
    }

    /// Warm launch: the app was running (backgrounded) when the
    /// quick action was tapped.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        AppRouter.shared.handle(shortcutItem: shortcutItem)
        completionHandler(true)
    }
}

extension AppRouter {
    /// Quick-action types are "<bundle id>.<AppTab raw value>"
    /// (declared in Info.plist under UIApplicationShortcutItems).
    func handle(shortcutItem: UIApplicationShortcutItem) {
        guard let suffix = shortcutItem.type.split(separator: ".").last,
              let tab = AppTab(rawValue: String(suffix)) else { return }
        switch tab {
        case .scan:
            openScanCamera()
        case .nearby, .history:
            open(tab)
        }
    }
}
