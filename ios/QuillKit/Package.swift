// swift-tools-version:6.0
import PackageDescription

// The iPhone app's pure logic — capture timeline, session metadata, folder
// naming — kept out of the Xcode project so `swift test` runs it on a Mac.
let package = Package(
    name: "QuillKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "QuillKit", targets: ["QuillKit"])
    ],
    targets: [
        .target(name: "QuillKit"),
        .testTarget(name: "QuillKitTests", dependencies: ["QuillKit"]),
    ]
)
