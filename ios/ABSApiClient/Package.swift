// swift-tools-version:6.0
import PackageDescription

// Local Swift package that generates a typed Audiobookshelf API client from the
// bundled OpenAPI document (Sources/ABSApiClient/openapi.yaml) at build time via
// Apple's swift-openapi-generator build-tool plugin.
//
// This lives inside the app repo intentionally (see README.md). The app target
// consumes it as a local package dependency alongside the existing CocoaPods setup.
let package = Package(
  name: "ABSApiClient",
  platforms: [
    .iOS(.v14),
    .macOS(.v13)
  ],
  products: [
    .library(name: "ABSApiClient", targets: ["ABSApiClient"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.0"),
    // HTTPTypes is imported directly by RefreshAwareAuth.swift (the auth middlewares construct
    // HTTPField.Name / read HTTPResponse.status). It also arrives transitively via the OpenAPI
    // packages, but declaring it explicitly is correct hygiene AND makes it a first-level product
    // in the link closure — required so an app-hosted XCTest target that links ABSApiClient can
    // resolve HTTPTypes symbols (Xcode's implicit link does not pull second-level transitive products).
    .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0")
  ],
  targets: [
    .target(
      name: "ABSApiClient",
      dependencies: [
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
        .product(name: "HTTPTypes", package: "swift-http-types")
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    )
  ]
)
