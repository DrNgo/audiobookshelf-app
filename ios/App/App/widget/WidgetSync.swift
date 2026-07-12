//
//  WidgetSync.swift
//  App
//
//  App-side bridge: pushes the current server credentials into the shared App Group and nudges
//  WidgetKit to refresh. App-only (reads Store/Realm), so it is kept out of the widget target.
//

import Foundation
import WidgetKit

enum WidgetSync {
    /// Write the active server's URL + token to the App Group and reload widget timelines. Safe to
    /// call whenever credentials may have changed (launch, login, token refresh).
    static func sync() {
        guard let config = Store.serverConfig, !config.address.isEmpty, !config.token.isEmpty else { return }
        WidgetSharedCredentials.save(serverURL: config.address, token: config.token)
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
