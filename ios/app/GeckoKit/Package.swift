// swift-tools-version: 5.10
// GeckoKit holds the app's pure, dependency-free helpers (no SwiftUI / UIKit /
// bridge) so they can be unit-tested with `swift test` on the host. The very
// same source files are compiled straight into the Gecko app by build-app.sh
// (it globs GeckoKit/Sources/GeckoKit/*.swift alongside Sources/*.swift), so
// there is one source of truth — the tests exercise exactly what ships.
import PackageDescription

let package = Package(
    name: "GeckoKit",
    // AttributedString needs macOS 12+ / iOS 15+; the host build (swift test)
    // uses the macOS floor.
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        .target(name: "GeckoKit"),
        .testTarget(name: "GeckoKitTests", dependencies: ["GeckoKit"]),
    ]
)
