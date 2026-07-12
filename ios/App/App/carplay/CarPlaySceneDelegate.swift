//
//  CarPlaySceneDelegate.swift
//  App
//
//  Entry point for the CarPlay scene. Owns the CPInterfaceController and the browse manager for
//  the lifetime of the CarPlay connection. The phone app keeps running on its existing
//  AppDelegate window — only CarPlay uses this scene delegate (declared for the CarPlay scene
//  role in Info.plist), so the main app lifecycle is unaffected.
//

import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var manager: CarPlayManager?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let manager = CarPlayManager(interfaceController: interfaceController)
        self.manager = manager
        manager.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.manager = nil
        self.interfaceController = nil
    }
}
