//
//  ABSTokenRefresher.swift
//  Audiobookshelf
//
//  App-side implementation of ABSApiClient's ABSTokenRefreshing. Replicates
//  ApiClient.handleTokenRefresh EXACTLY so the generated client and the legacy Alamofire client
//  behave identically during the migration:
//    401 -> POST /auth/refresh with the stored x-refresh-token
//        -> persist new access token to the server connection config (Database) and the new
//           refresh token to SecureStorage
//        -> fire AbsDatabase.tokenRefreshCallback("onTokenRefresh") so the Capacitor WebView
//           stays authenticated  (THE highest-risk parity detail)
//        -> retry the original request (handled by the middleware).
//  On failure it clears the session and notifies the WebView, mirroring handleRefreshFailure.
//

import Foundation
import ABSApiClient

struct ABSTokenRefresher: ABSTokenRefreshing {
    func refreshAccessToken() async -> String? {
        let secureStorage = SecureStorage()

        guard let serverConfig = Store.serverConfig else {
            AbsLogger.error(message: "ABSTokenRefresher: No server config available")
            return nil
        }
        // Capture value copies before any await — never hold a Realm object across a suspension.
        let configId = serverConfig.id
        let configName = serverConfig.name
        guard let serverURL = URL(string: serverConfig.address) else {
            AbsLogger.error(message: "ABSTokenRefresher: Invalid server address for \(configName)")
            return nil
        }

        guard let refreshToken = secureStorage.getRefreshToken(serverConnectionConfigId: configId) else {
            AbsLogger.error(message: "ABSTokenRefresher: No refresh token available for server \(configName)")
            handleRefreshFailure(serverConfigId: configId)
            return nil
        }

        AbsLogger.info(message: "ABSTokenRefresher: Refreshing access token for server \(configName)")

        guard let tokens = await ABSApiClient.performTokenRefresh(serverURL: serverURL, refreshToken: refreshToken) else {
            AbsLogger.error(message: "ABSTokenRefresher: Refresh request failed for server \(configName)")
            handleRefreshFailure(serverConfigId: configId)
            return nil
        }

        AbsLogger.info(message: "ABSTokenRefresher: Successfully obtained new access token")
        updateTokens(
            newAccessToken: tokens.accessToken,
            newRefreshToken: tokens.refreshToken ?? refreshToken,
            serverConnectionConfigId: configId
        )
        return tokens.accessToken
    }

    /// Persist the new tokens and notify the WebView. Mirrors ApiClient.updateTokens.
    private func updateTokens(newAccessToken: String, newRefreshToken: String, serverConnectionConfigId: String) {
        let secureStorage = SecureStorage()

        // Only rewrite the refresh token in secure storage if it actually changed.
        if newRefreshToken != secureStorage.getRefreshToken(serverConnectionConfigId: serverConnectionConfigId) {
            let stored = secureStorage.storeRefreshToken(serverConnectionConfigId: serverConnectionConfigId, refreshToken: newRefreshToken)
            AbsLogger.info(message: "ABSTokenRefresher: Updated refresh token in secure storage. Stored=\(stored)")
        }

        Database.shared.updateServerConnectionConfigToken(newToken: newAccessToken)

        // Notify the WebView frontend so the web layer stays authenticated. Missing this silently
        // logs the WebView out — the single most important parity detail in the migration.
        if let callback = AbsDatabase.tokenRefreshCallback {
            callback("onTokenRefresh", ["accessToken": newAccessToken])
        }
    }

    /// Clear the session and notify the WebView. Mirrors ApiClient.handleRefreshFailure.
    private func handleRefreshFailure(serverConfigId: String) {
        AbsLogger.info(message: "ABSTokenRefresher: Token refresh failed, clearing session")

        Store.serverConfig = nil
        // ApiClient.handleRefreshFailure had a latent bug: it read Store.serverConfig AFTER nil'ing
        // it, so the refresh-token removal never ran. We remove it here using the id captured
        // before clearing the session, which is the clearly-intended behavior.
        _ = SecureStorage().removeRefreshToken(serverConnectionConfigId: serverConfigId)

        if let callback = AbsDatabase.tokenRefreshCallback {
            callback("onTokenRefreshFailure", ["error": "Token refresh failed"])
        }
    }
}
