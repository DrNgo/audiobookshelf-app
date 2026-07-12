//
//  ABSClientProvider.swift
//  Audiobookshelf
//
//  Single owner of ABSApiClient configuration. The generated `Client` is constructed inside the
//  ABSApiClient package (so the app never links OpenAPIRuntime symbols directly); this provider
//  vends the inputs that construction needs — the server base URL, a lazy access-token reader,
//  and the shared token refresher — sourced from the active server connection.
//

import Foundation
import ABSApiClient

enum ABSClientProvider {
    /// Stateless refresher; safe to share.
    static let refresher = ABSTokenRefresher()

    /// Reads the current access token at call time so a token refreshed by either client is
    /// always picked up.
    static let accessToken: @Sendable () -> String? = { Store.serverConfig?.token }

    /// Base URL of the active server, or nil if none is configured / the address is invalid.
    static var serverURL: URL? {
        guard let address = Store.serverConfig?.address else { return nil }
        return URL(string: address)
    }
}
