// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snitt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SnittDocument", targets: ["SnittDocument"]),
        .library(name: "SnittCapture", targets: ["SnittCapture"]),
        .library(name: "SnittExport", targets: ["SnittExport"]),
        .library(name: "SnittAutomation", targets: ["SnittAutomation"]),
    ],
    targets: [
        .target(name: "SnittDocument"),
        .target(name: "SnittCapture", dependencies: ["SnittDocument"]),
        .target(name: "SnittExport", dependencies: ["SnittDocument"]),
        // Deliberately depends on NOTHING: §4.9 forbids any frontend from calling
        // ScreenCaptureKit, because macOS attributes the capture grant to the
        // responsible process — a capturing CLI re-prompts for every new parent.
        // It declared SnittCapture and SnittDocument and imported neither, which
        // transitively linked ScreenCaptureKit into snitt-cli and snitt-mcp and
        // left the invariant resting on prose comments. ThinClientConformanceTests
        // is the enforcement; this is the fact it enforces.
        .target(name: "SnittAutomation"),
        .executableTarget(
            name: "snitt-probe",
            dependencies: ["SnittCapture", "SnittDocument"],
            path: "Sources/snitt-probe"
        ),
        .executableTarget(
            name: "SnittApp",
            dependencies: ["SnittCapture", "SnittDocument", "SnittExport", "SnittAutomation"]
        ),
        .executableTarget(name: "snitt-cli",
                          dependencies: ["SnittAutomation"],
                          path: "Sources/snitt-cli"),
        .executableTarget(name: "snitt-mcp",
                          dependencies: ["SnittAutomation"],
                          path: "Sources/snitt-mcp"),
        .testTarget(name: "SnittDocumentTests", dependencies: ["SnittDocument"]),
        .testTarget(name: "SnittCaptureTests", dependencies: ["SnittCapture"]),
        .testTarget(name: "SnittExportTests", dependencies: ["SnittExport"]),
        .testTarget(name: "SnittAutomationTests", dependencies: ["SnittAutomation"]),
        .testTarget(name: "SnittAppTests",
                    dependencies: ["SnittApp", "SnittCapture", "SnittDocument"]),
        // THROWAWAY SPIKE CODE — spec section 14, S1/S3/S4/S5. Not for production use.
        .executableTarget(name: "S1KeystrokeProbe", path: "Spikes/S1KeystrokeProbe"),
        .executableTarget(name: "S3IPCCaptureProbe", path: "Spikes/S3IPCCaptureProbe"),
        .executableTarget(name: "S4NagObservation", path: "Spikes/S4NagObservation"),
        .executableTarget(name: "S5RealTopology", dependencies: ["SnittCapture"], path: "Spikes/S5RealTopology"),
    ]
)
