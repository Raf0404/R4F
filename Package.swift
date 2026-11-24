// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "livebus",
    platforms: [.macOS(.v13)],
    targets: [
        // Motore real-time in C: niente ARC, niente lock, niente allocazioni nei callback audio.
        .target(
            name: "CLiveBus",
            path: "Sources/CLiveBus",
            cSettings: [.unsafeFlags(["-O3", "-fno-math-errno"])],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // CLI di controllo: dispositivi, configurazione, OSC, tono di prova, selftest.
        .executableTarget(
            name: "livebus",
            dependencies: ["CLiveBus"],
            path: "Sources/livebus",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
    ]
)
