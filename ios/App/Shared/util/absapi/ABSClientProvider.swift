//
//  ABSClientProvider.swift
//  Audiobookshelf
//
//  Single owner of ABSApiClient configuration. Builds a generated `Client` from the active
//  server connection (base URL + access token) wired with refresh-aware authentication.
//  As endpoints migrate off ApiClient (Phases 2–5), callers obtain their client here.
//

import Foundation
import ABSApiClient

enum ABSClientProvider {
    // Stateless refresher; safe to share.
    private static let refresher = ABSTokenRefresher()

    /// A refresh-aware client for the currently-active server, or `nil` if no server is
    /// configured. The access token is read lazily at request time so a token refreshed by
    /// either client (generated or legacy ApiClient) is always picked up.
    static func makeClient() -> Client? {
        guard let serverConfig = Store.serverConfig,
              let serverURL = URL(string: serverConfig.address) else {
            AbsLogger.error(message: "ABSClientProvider: No server configured")
            return nil
        }
        return ABSApiClient.makeRefreshAwareClient(
            serverURL: serverURL,
            accessToken: { Store.serverConfig?.token },
            refresher: refresher
        )
    }
}
