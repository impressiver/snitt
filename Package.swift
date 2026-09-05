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
    dependencies: [
        // M5b (§13): in-app updates via direct download (§4.3). Only SnittApp
        // may depend on this — see the SnittApp target below.
        // `sparkleNeverLinksIntoThinClients` in BundleLayoutTests.swift runs
        // `otool -L` against the built snitt-cli and snitt-mcp binaries and
        // is the actual enforcement; snitt-cli and snitt-mcp must stay thin
        // (§4.9) and never link Sparkle. (SnittAppTests also depends on the
        // Sparkle product directly, purely to drive Sparkle's own
        // configuration-validation API in tests — that import doesn't
        // relax this rule, which is about the two client executables.)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "SnittDocument"),
        .target(name: "SnittCapture", dependencies: ["SnittDocument"]),
        .target(name: "SnittExport", dependencies: ["SnittDocument"]),
        // Depends on SnittDocument ONLY — never SnittCapture. §4.9 forbids any
        // frontend from calling ScreenCaptureKit, because macOS attributes the
        // capture grant to the responsible process — a capturing CLI
        // re-prompts for every new parent. This target once declared
        // SnittCapture and SnittDocument and imported neither, which
        // transitively linked ScreenCaptureKit into snitt-cli and snitt-mcp
        // and left the invariant resting on prose comments.
        // ThinClientConformanceTests is the enforcement; this is the fact it
        // enforces. SnittDocument itself is safe here: it declares no
        // dependencies and imports only Foundation (needed for
        // AutomationResponse.stopped's CaptureHealth payload).
        .target(name: "SnittAutomation", dependencies: ["SnittDocument"]),
        .executableTarget(
            name: "snitt-probe",
            dependencies: ["SnittCapture", "SnittDocument"],
            path: "Sources/snitt-probe"
        ),
        .executableTarget(
            name: "SnittApp",
            dependencies: [
                "SnittCapture", "SnittDocument", "SnittExport", "SnittAutomation",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // No SnittDocument dependency: the CLI used to read RecordingMetadata
        // back from the bundle it just wrote to report health, but the bundle
        // lives in the APP's output directory — by default `~/Desktop`,
        // gated by the Files-and-Folders TCC service the CLI does not hold —
        // so that read silently failed on every real machine. Health now
        // arrives over the socket in AutomationResponse.stopped, so
        // SnittAutomation alone (which itself depends on SnittDocument, for
        // CaptureHealth) is enough.
        .executableTarget(name: "snitt-cli",
                          dependencies: ["SnittAutomation", "SnittDocument"],
                          path: "Sources/snitt-cli"),
        .executableTarget(name: "snitt-mcp",
                          dependencies: ["SnittAutomation", "SnittDocument"],
                          path: "Sources/snitt-mcp"),
        .testTarget(name: "SnittDocumentTests", dependencies: ["SnittDocument"]),
        .testTarget(name: "SnittCaptureTests", dependencies: ["SnittCapture"]),
        .testTarget(name: "SnittExportTests", dependencies: ["SnittExport"]),
        .testTarget(name: "SnittAutomationTests", dependencies: ["SnittAutomation", "SnittDocument"]),
        .testTarget(name: "SnittAppTests",
                    dependencies: [
                        "SnittApp", "SnittCapture", "SnittDocument", "SnittAutomation", "SnittExport",
                        .product(name: "Sparkle", package: "Sparkle"),
                    ]),
        .testTarget(name: "SnittCLITests",
                    dependencies: ["snitt-cli", "SnittAutomation", "SnittDocument"]),
        .testTarget(name: "SnittMCPTests",
                    dependencies: ["snitt-mcp", "SnittAutomation", "SnittDocument"]),
        // THROWAWAY SPIKE CODE — spec section 14, S1/S3/S4/S5. Not for production use.
        .executableTarget(name: "S1KeystrokeProbe", path: "Spikes/S1KeystrokeProbe"),
        .executableTarget(name: "S3IPCCaptureProbe", path: "Spikes/S3IPCCaptureProbe"),
        .executableTarget(name: "S4NagObservation", path: "Spikes/S4NagObservation"),
        .executableTarget(name: "S5RealTopology", dependencies: ["SnittCapture"], path: "Spikes/S5RealTopology"),
    ]
)
