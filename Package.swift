// swift-tools-version:5.9
import PackageDescription

// The GitHub organization of the suite's repositories: the one name to change should it be renamed (the
// suite repository's scripts/rename-organization.sh does it in every repository).
let organization = "love-suite"

// Suite Settings: the settings of the suite's apps as an app of its own. Each
// app's settings come from that app's repository, as a library of its own.
let suiteCore = Target.Dependency.product(name: "SuiteCore", package: "suite-core")

let package = Package(
    name: "SuiteSettings",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/\(organization)/suite-core", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-explorer", .upToNextMinor(from: "27.1.0-dev.1")),
        // Until feat/dock-parity is merged in suite-bar: its settings, from that branch. Back to
        // .upToNextMinor(from:) once suite-bar has a version with them.
        .package(url: "https://github.com/\(organization)/suite-bar", branch: "feat/dock-parity"),
        .package(url: "https://github.com/\(organization)/suite-clipboard", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-files", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-desktop", .upToNextMinor(from: "27.1.0-dev.1")),
    ],
    targets: [
        // Every app's settings tabs, read and written through each app's settings library.
        .target(
            name: "SettingsUI",
            dependencies: [
                suiteCore,
                .product(name: "ExplorerSettings", package: "suite-explorer"),
                .product(name: "ClipboardSettings", package: "suite-clipboard"),
                .product(name: "BarSettings", package: "suite-bar"),
                .product(name: "SuiteFilesCore", package: "suite-files"),
                .product(name: "DesktopSettings", package: "suite-desktop"),
            ],
            resources: [.process("Resources")]
        ),
        // The banner over macOS's own settings panes where a suite app stands in for macOS: which pane a
        // window shows and what to say there (no UI, unit-tested).
        .target(
            name: "NativeBanner",
            dependencies: [
                .product(name: "BarSettings", package: "suite-bar"),
                .product(name: "DesktopSettings", package: "suite-desktop"),
                .product(name: "SuiteFilesCore", package: "suite-files"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NativeBannerTests", dependencies: ["NativeBanner"]),
        // Suite Settings Agent, embedded in the app as its login item: draws the banner.
        .executableTarget(
            name: "SettingsAgent",
            dependencies: [
                suiteCore, "NativeBanner",
                .product(name: "BarSettings", package: "suite-bar"),
                .product(name: "DesktopSettings", package: "suite-desktop"),
                .product(name: "SuiteFilesCore", package: "suite-files"),
            ]
        ),
        // The app, with its own Dock icon.
        .executableTarget(
            name: "Settings",
            dependencies: [suiteCore, "SettingsUI"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
    ]
)
