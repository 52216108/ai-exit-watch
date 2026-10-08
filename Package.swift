// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetworkWatch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NetworkWatch", targets: ["NetworkWatch"]),
        .executable(name: "network-watch-probe", targets: ["Probe"])
    ],
    targets: [
        .target(name: "WatchCore"),
        .executableTarget(name: "NetworkWatch", dependencies: ["WatchCore"]),
        .executableTarget(name: "Probe", dependencies: ["WatchCore"]),
        .testTarget(name: "WatchCoreTests", dependencies: ["WatchCore"], exclude: ["verify_exit_lock.py"])
    ]
)
