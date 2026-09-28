//
//  CarPlaySceneDelegate.swift
//  BrownSign
//
//  The CarPlay scene. Declared in Info.plist's scene manifest and routed
//  here by AppDelegate; everything the car shows lives in
//  CarPlayController. CarPlay only offers this scene to builds signed
//  with the CarPlay audio entitlement.
//

import CarPlay

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let controller = CarPlayController(interfaceController: interfaceController)
        self.controller = controller
        controller.connect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.disconnect()
        controller = nil
    }

    /// On the car screen (the app counts as in use, so location runs).
    func sceneDidBecomeActive(_ scene: UIScene) {
        controller?.setVisible(true)
    }

    /// Another app took the car screen (Maps, usually).
    func sceneWillResignActive(_ scene: UIScene) {
        controller?.setVisible(false)
    }
}
