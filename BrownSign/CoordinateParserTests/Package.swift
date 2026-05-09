// swift-tools-version: 5.9

// Tiny standalone Swift Package that compiles ONLY the regex parser
// from the iOS app target so we can run unit tests against it via
// `swift test` without modifying the Xcode project (which uses
// PBXFileSystemSynchronizedRootGroup and has no test target).
//
// `Sources/CoordinateParser/CoordinateParser.swift` is a symlink to
// `../../BrownSign/CoordinateParser.swift` — the iOS app's
// pure-logic parser. Single source of truth: editing either path
// edits the same underlying file.
//
// The wrapping `CoordinateFallback.swift` (which depends on the
// project's `Coordinate` type and `httpDataWithRetry`) is
// intentionally NOT part of this package — only the dependency-free
// parser is tested here.
//
// Run from this directory:
//   swift test
// Or from anywhere:
//   swift test --package-path BrownSign/CoordinateParserTests
import PackageDescription

let package = Package(
    name: "CoordinateParserTests",
    targets: [
        .target(name: "CoordinateParser"),
        .testTarget(
            name: "CoordinateParserTests",
            dependencies: ["CoordinateParser"]
        )
    ]
)
