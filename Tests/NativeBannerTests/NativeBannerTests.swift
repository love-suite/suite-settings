import BarSettings
import Foundation
import Testing
@testable import NativeBanner

@Suite struct NativePaneTests {
    @Test func desktopAndDockIsKnownInEveryLanguageMacOSHas() {
        let titles = NativePane.desktopAndDock.titles
        #expect(titles.contains("Desktop & Dock"))
        if FileManager.default.fileExists(atPath: "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex") {
            #expect(titles.contains("Bureau et Dock"))
        }
    }

    @Test func onlySystemSettingsWindowsMatch() {
        #expect(NativePane.pane(hostBundleID: "com.apple.systempreferences", windowTitle: "Desktop & Dock") == .desktopAndDock)
        #expect(NativePane.pane(hostBundleID: "com.apple.finder", windowTitle: "Desktop & Dock") == nil)
        #expect(NativePane.pane(hostBundleID: "com.apple.systempreferences", windowTitle: "Wi-Fi") == nil)
    }
}

@Suite struct PaneCoversTests {
    @Test func nothingCoveredWithoutASuiteApp() {
        #expect(PaneMarks.covers(for: .desktopAndDock, running: [], native: NativeValues()).isEmpty)
    }

    @Test func barCoversTheDockSections() {
        var bar = BarSettings()
        bar.isShown = true
        let covers = PaneMarks.covers(for: .desktopAndDock, running: [PaneMarks.barID], bar: bar, native: NativeValues())
        #expect(covers.count == 1 && covers[0].extent == .sections && covers[0].tab == "Bar")
        #expect(PaneMarks.covers(for: .desktopAndDock, running: [PaneMarks.barID], bar: BarSettings(),
                                 native: NativeValues()).isEmpty)
    }

    @Test func bureauCoversItsTwoSettings() {
        let covers = PaneMarks.covers(for: .desktopAndDock, running: [PaneMarks.desktopID], native: NativeValues())
        #expect(covers.map(\.anchors) == [["show-items-on-desktop"], ["click-wallpaper-to-reveal-desktop"]])
        #expect(covers.map(\.extent) == [.controls, .fields])
    }

    @Test func clipboardCoversSpotlightsHistory() {
        let covers = PaneMarks.covers(for: .spotlight, running: [PaneMarks.clipboardID], native: NativeValues())
        #expect(covers.map(\.anchors) == [["clipboard-results"]] && covers.first?.tab == "Clipboard")
        #expect(PaneMarks.covers(for: .spotlight, running: [], native: NativeValues()).isEmpty)
        if FileManager.default.fileExists(atPath: "/System/Library/ExtensionKit/Extensions/SpotlightPreferenceExtension.appex") {
            #expect(NativePane.spotlight.titledControls["clipboard-results"]?.contains("Résultats du presse-papiers") == true)
        }
    }

    @Test func nothingCoveredWithStageManager() {
        var native = NativeValues()
        native.stageManager = true
        #expect(PaneMarks.covers(for: .desktopAndDock, running: [PaneMarks.desktopID], native: native).isEmpty)
    }
}

/// Frames as Desktop & Dock gives them on macOS 27 (French).
@Suite struct RowLayoutTests {
    let sliders = CGRect(x: 593, y: 123, width: 554, height: 69)
    let desktop = CGRect(x: 593, y: 568, width: 554, height: 133)

    @Test func twoSlidersShareTheirSectionHalfAndHalf() {
        let fields = RowLayout.fields(section: sliders, controls: [
            .init(key: "slider.0", frame: CGRect(x: 603, y: 132, width: 243, height: 34), isSlider: true),
            .init(key: "slider.1", frame: CGRect(x: 874, y: 132, width: 263, height: 34), isSlider: true),
        ], texts: [])
        #expect(fields["slider.0"]?.frame == CGRect(x: 593, y: 123, width: 267, height: 69))
        #expect(fields["slider.1"]?.frame.maxX == 1147)
    }

    /// Finder's Settings, Advanced (macOS 27, French): checkboxes carrying their labels, a heading above
    /// the search menu.
    @Test func aHeadingGoesWithTheLineBelowIt() {
        let section = CGRect(x: 354, y: 145, width: 369, height: 282)
        let fields = RowLayout.fields(section: section, controls: [
            .init(key: "extensions", frame: CGRect(x: 366, y: 153, width: 270, height: 18)),
            .init(key: "windows", frame: CGRect(x: 388, y: 309, width: 244, height: 18)),
            .init(key: "desktop", frame: CGRect(x: 388, y: 335, width: 104, height: 18)),
            .init(key: nil, frame: CGRect(x: 388, y: 393, width: 299, height: 26)),
        ], texts: [
            CGRect(x: 366, y: 283, width: 177, height: 18),
            CGRect(x: 366, y: 369, width: 182, height: 18),
        ])
        #expect(fields["desktop"]!.frame.maxY < 369)
        #expect(fields["windows"]!.frame.minY < 283)
    }

    @Test func aFieldTakesItsTitleAndCaptionWhole() {
        let fields = RowLayout.fields(section: desktop, controls: [
            .init(key: "show-items-on-desktop", frame: CGRect(x: 872, y: 578, width: 101, height: 16)),
            .init(key: nil, frame: CGRect(x: 989, y: 578, width: 147, height: 16)),
            .init(key: "click-wallpaper", frame: CGRect(x: 887, y: 612, width: 249, height: 24)),
        ], texts: [
            CGRect(x: 603, y: 578, width: 128, height: 16),
            CGRect(x: 603, y: 615, width: 244, height: 32),
            CGRect(x: 603, y: 649, width: 265, height: 42),
        ])
        let wallpaper = fields["click-wallpaper"]!
        #expect(wallpaper.frame.minY < 612 && wallpaper.frame.maxY == 701)
        #expect(wallpaper.texts.count == 2)
        let items = fields["show-items-on-desktop"]!
        #expect(items.frame.maxX < 989)
    }
}
