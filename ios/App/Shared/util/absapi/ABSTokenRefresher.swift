//
//  ABSTokenRefresher.swift
//  Audiobookshelf
//
//  The generated client's ABSTokenRefreshing implementation. Delegates to
//  ABSTokenRefreshCoordinator so refreshes triggered by the generated middleware are
//  single-flighted together with those triggered by the legacy ApiClient — one /auth/refresh
//  round-trip is shared across all concurrent 401s. The coordinator owns the actual refresh +
//  persistence + WebView notification.
//

import Foundation
import ABSApiClient

struct ABSTokenRefresher: ABSTokenRefreshing {
    func refreshAccessToken() async -> String? {
        await ABSTokenRefreshCoordinator.shared.refreshAccessToken()
    }
}
