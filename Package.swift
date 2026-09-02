// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snitt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SnittDocument", targets: ["SnittDocument"]),
        .library(name: "SnittCapture", targets: ["SnittCapture"]),
    ],
    targets: [
        .target(name: "SnittDocument"),
        .target(name: "SnittCapture", dependencies: ["SnittDocument"]),
        .executableTarget(
            name: "snitt-probe",
            dependencies: ["SnittCapture", "SnittDocument"],
            path: "Sources/snitt-probe"
        ),
        .testTarget(name: "SnittDocumentTests", dependencies: ["SnittDocument"]),
        .testTarget(name: "SnittCaptureTests", dependencies: ["SnittCapture"]),
        // THROWAWAY SPIKE CODE — spec section 14, S1/S3. Not for production use.
        .executableTarget(name: "S1KeystrokeProbe", path: "Spikes/S1KeystrokeProbe"),
        .executableTarget(name: "S3IPCCaptureProbe", path: "Spikes/S3IPCCaptureProbe"),
    ]
)
