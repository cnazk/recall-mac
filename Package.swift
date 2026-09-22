// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Recall",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "recall-app", targets: ["RecallApp"]),
        .executable(name: "recall-otp-service", targets: ["RecallOTPService"]),
        .library(name: "RecallKit", targets: ["RecallCore", "RecallCapture", "RecallStorage", "RecallSecurity"]),
    ],
    targets: [
        .target(name: "RecallCore"),
        .target(
            name: "RecallSecurity",
            dependencies: ["RecallCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "RecallCapture", dependencies: ["RecallCore", "RecallSecurity"]),
        .target(name: "RecallStorage", dependencies: ["RecallCore"]),
        .target(name: "RecallEnrichment", dependencies: ["RecallCore"]),
        .target(name: "RecallIntelligence", dependencies: ["RecallCore", "RecallStorage"]),
        .target(name: "RecallPaste", dependencies: ["RecallCore"]),
        .target(name: "RecallOTP"),
        .target(
            name: "RecallUI",
            dependencies: ["RecallCore", "RecallStorage", "RecallIntelligence", "RecallPaste", "RecallCapture", "RecallEnrichment", "RecallOTP", "RecallSecurity"]
        ),
        .executableTarget(name: "RecallOTPService", dependencies: ["RecallOTP"]),
        .executableTarget(
            name: "RecallApp",
            dependencies: ["RecallUI", "RecallCore", "RecallCapture", "RecallStorage", "RecallSecurity", "RecallIntelligence", "RecallPaste", "RecallEnrichment", "RecallOTP"]
        ),
        .testTarget(name: "RecallCoreTests", dependencies: ["RecallCore"]),
        .testTarget(name: "RecallSecurityTests", dependencies: ["RecallSecurity", "RecallCore"]),
        .testTarget(name: "RecallCaptureTests", dependencies: ["RecallCapture", "RecallCore", "RecallStorage", "RecallPaste"]),
        .testTarget(name: "RecallStorageTests", dependencies: ["RecallStorage", "RecallCore"]),
        .testTarget(name: "RecallPasteTests", dependencies: ["RecallPaste", "RecallCore"]),
        .testTarget(name: "RecallUITests", dependencies: ["RecallUI", "RecallCore"]),
        .testTarget(name: "RecallEnrichmentTests", dependencies: ["RecallEnrichment", "RecallCore"]),
        .testTarget(name: "RecallOTPTests", dependencies: ["RecallOTP"]),
        .testTarget(name: "RecallIntelligenceTests", dependencies: ["RecallIntelligence", "RecallCore", "RecallStorage"]),
    ]
)
