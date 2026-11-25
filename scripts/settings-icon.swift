// Draws Suite Settings' icon, Finder's with System Settings' gear in a corner, from this Mac's icons
// (never committed), into an .icns. Compiled, as AppKit needs:
//   swiftc -o build/settings-icon scripts/settings-icon.swift && build/settings-icon <output.icns>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "build/SettingsIcon.icns"
let finder = NSImage(contentsOfFile: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns")!
let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
    .map { NSWorkspace.shared.icon(forFile: $0.path) }
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Settings-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (side, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                     (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    finder.draw(in: rect)
    settings?.draw(in: NSRect(x: rect.width * 0.48, y: rect.height * 0.02, width: rect.width * 0.5, height: rect.height * 0.5))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
