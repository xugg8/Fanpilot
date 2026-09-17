// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanPilot",
    platforms: [.macOS(.v13)],          // SMAppService 需要 13+；SMJobBless 路线可降到 12
    products: [
        .library(name: "FanPilotCore", targets: ["FanPilotCore"]),
        .library(name: "ControlEngine", targets: ["ControlEngine"]),
        .library(name: "SafetyGuard", targets: ["SafetyGuard"]),
        .executable(name: "fanpilot", targets: ["fanpilot-cli"]),
        .executable(name: "fanpilot-helper", targets: ["FanPilotHelper"]),
        .executable(name: "FanPilotMenu", targets: ["FanPilotApp"]),   // 不要叫 FanPilot：大小写不敏感的文件系统会与 CLI 的 fanpilot 冲突
    ],
    targets: [
        .target(name: "FanPilotCore"),
        .target(name: "ControlEngine", dependencies: ["FanPilotCore", "SafetyGuard"]),
        .target(name: "SafetyGuard", dependencies: ["FanPilotCore"]),
        .executableTarget(name: "fanpilot-cli",
                          dependencies: ["FanPilotCore", "ControlEngine", "SafetyGuard"]),
        .executableTarget(name: "FanPilotHelper",
                          dependencies: ["FanPilotCore", "ControlEngine", "SafetyGuard"]),
        .executableTarget(name: "FanPilotApp",
                          dependencies: ["FanPilotCore", "ControlEngine", "SafetyGuard"]),
        .testTarget(name: "FanPilotCoreTests",
                    dependencies: ["FanPilotCore", "ControlEngine", "SafetyGuard"]),
    ]
)
