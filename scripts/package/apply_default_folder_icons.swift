import AppKit
import Foundation

// Usage: swift apply_default_folder_icons.swift <folder> <symbol> [<folder> <symbol> ...]
guard CommandLine.arguments.count >= 3, (CommandLine.arguments.count - 1) % 2 == 0 else {
    fputs("Expected folder and SF Symbols name pairs.\n", stderr)
    exit(2)
}

let palettes: [String: [NSColor]] = [
    "Customization": [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)],
    "assets": [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)],
    "License": [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)],
    "Plugins": [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)],
    "PluginDependencies": [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)]
]

for index in stride(from: 1, to: CommandLine.arguments.count, by: 2) {
    let folder = CommandLine.arguments[index]
    let symbolName = CommandLine.arguments[index + 1]
    guard FileManager.default.fileExists(atPath: folder) else { continue }
    let name = URL(fileURLWithPath: folder).lastPathComponent
    let palette = palettes[name] ?? [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)]
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.lockFocus()

    if symbolName.hasPrefix("image:") {
        let iconPath = String(symbolName.dropFirst("image:".count))
        if let sourceIcon = NSImage(contentsOfFile: iconPath) {
            drawBrandedFolder(sourceIcon)
        } else {
            fputs("Could not load custom folder mark at \(iconPath); using the standard folder icon.\n", stderr)
            drawDefaultFolder(symbol: "shippingbox", name: name, palette: palette)
        }
    } else {
        drawDefaultFolder(symbol: symbolName, name: name, palette: palette)
    }

    image.unlockFocus()
    if !NSWorkspace.shared.setIcon(image, forFile: folder, options: []) {
        fputs("Could not set the default icon for \(name).\n", stderr)
        exit(1)
    }
}

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
}

func folderShape(_ palette: [NSColor]) {
    // One restrained folder silhouette is shared across project materials.
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 36, y: 78))
    back.line(to: NSPoint(x: 36, y: 336))
    back.curve(to: NSPoint(x: 70, y: 370), controlPoint1: NSPoint(x: 36, y: 354), controlPoint2: NSPoint(x: 50, y: 370))
    back.line(to: NSPoint(x: 165, y: 370))
    back.curve(to: NSPoint(x: 198, y: 354), controlPoint1: NSPoint(x: 184, y: 370), controlPoint2: NSPoint(x: 188, y: 363))
    back.line(to: NSPoint(x: 222, y: 326))
    back.line(to: NSPoint(x: 434, y: 326))
    back.curve(to: NSPoint(x: 476, y: 284), controlPoint1: NSPoint(x: 476, y: 326), controlPoint2: NSPoint(x: 476, y: 308))
    back.line(to: NSPoint(x: 476, y: 118))
    back.curve(to: NSPoint(x: 444, y: 86), controlPoint1: NSPoint(x: 476, y: 100), controlPoint2: NSPoint(x: 462, y: 86))
    back.line(to: NSPoint(x: 70, y: 86))
    back.curve(to: NSPoint(x: 36, y: 78), controlPoint1: NSPoint(x: 52, y: 86), controlPoint2: NSPoint(x: 36, y: 82))
    back.close()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.10, alpha: 0.18)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.set()
    NSGradient(colors: palette)?.draw(in: back, angle: 90)
    NSShadow().set()

    let face = NSBezierPath(roundedRect: NSRect(x: 36, y: 48, width: 440, height: 284), xRadius: 30, yRadius: 30)
    NSGradient(colors: [palette[0].blended(withFraction: 0.12, of: .white) ?? palette[0], palette[1]])?.draw(in: face, angle: 90)
    NSColor.white.withAlphaComponent(0.26).setStroke()
    face.lineWidth = 2
    face.stroke()

    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: 65, y: 311))
    highlight.line(to: NSPoint(x: 446, y: 311))
    highlight.lineWidth = 2
    NSColor.white.withAlphaComponent(0.24).setStroke()
    highlight.stroke()
}

func drawBrandedFolder(_ logo: NSImage) {
    let palette = [rgb(0.40, 0.63, 0.88), rgb(0.22, 0.45, 0.75)]
    folderShape(palette)

    // Print the supplied full-colour mark directly onto the folder face. Its
    // transparent canvas leaves generous margins and avoids a badge/sticker.
    logo.draw(in: NSRect(x: 182, y: 127, width: 148, height: 148),
              from: .zero, operation: .sourceOver, fraction: 1,
              respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

func drawDefaultFolder(symbol symbolName: String, name: String, palette: [NSColor]) {
    folderShape(palette)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: name) else {
        fputs("System icon \(symbolName) is unavailable for \(name).\n", stderr)
        return
    }

    // Low-contrast glyphs sit directly on the folder surface like fine etching.
    let etchedTone = NSColor(calibratedWhite: 1, alpha: 0.68)
    let configuration = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [etchedTone]))
    symbol.withSymbolConfiguration(configuration)?.draw(in: NSRect(x: 194, y: 132, width: 124, height: 124))
}
