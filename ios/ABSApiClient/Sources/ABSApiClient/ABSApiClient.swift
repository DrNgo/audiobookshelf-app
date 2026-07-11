//
//  ABSApiClient.swift
//  Convenience entry point for the generated Audiobookshelf API client.
//
//  The `Client`, `APIProtocol`, and `Components` types referenced here are generated
//  at build time by the swift-openapi-generator plugin from `openapi.yaml`.
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

public enum ABSApiClient {
  /// Create a ready-to-use Audiobookshelf API client.
  ///
  /// - Parameters:
  ///   - serverURL: The base URL of the Audiobookshelf server (e.g. `https://abs.example.com`).
  ///   - accessToken: Optional bearer access token. When provided, an `Authorization:
  ///     Bearer <token>` header is added to every request.
  /// - Returns: A generated `Client` backed by `URLSessionTransport`.
  public static func makeClient(serverURL: URL, accessToken: String? = nil) -> Client {
    var middlewares: [any ClientMiddleware] = []
    if let accessToken {
      middlewares.append(BearerAuthMiddleware(accessToken: accessToken))
    }
    return Client(
      serverURL: serverURL,
      transport: URLSessionTransport(),
      middlewares: middlewares
    )
  }
}

/// Injects a bearer access token into every outgoing request.
///
/// The generated operations that use the spec's `BearerAuth` security scheme expect the
/// token on the `Authorization` header; this middleware supplies it centrally so callers
/// don't have to thread the token through each call.
struct BearerAuthMiddleware: ClientMiddleware {
  let accessToken: String

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var request = request
    request.headerFields[.authorization] = "Bearer \(accessToken)"
    return try await next(request, body, baseURL)
  }
}
