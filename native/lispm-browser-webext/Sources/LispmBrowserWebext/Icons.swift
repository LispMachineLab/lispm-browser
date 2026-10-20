// Extensions' icons, as PNG for Emacs and for the management page.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: GPL-3.0-or-later
//
// WebKit hands an extension's icon as an NSImage, the best of the sizes
// its manifest lists.  Emacs draws PNG, so the image is drawn into a
// bitmap of the pixels asked for, square, the icon fitted inside it.  The
// list of extensions is read again whenever a button or a badge changes,
// so each icon is drawn again only when WebKit hands another image.

import AppKit

@MainActor
enum Icons {
    /// The last PNG made for each key, with the image it was made from.
    private static var made: [String: (image: NSImage, pixels: Int, png: Data)] = [:]

    /// `image` as PNG, `pixels` square, or nil.  `key` names whose icon it
    /// is, so that the same image is not drawn again.
    static func png(_ image: NSImage?, key: String, pixels: Int) -> Data? {
        guard let image else { return nil }
        if let last = made[key], last.image === image, last.pixels == pixels { return last.png }
        guard let png = draw(image, pixels: pixels) else { return nil }
        made[key] = (image, pixels, png)
        return png
    }

    static func base64(_ image: NSImage?, key: String, pixels: Int) -> String? {
        png(image, key: key, pixels: pixels)?.base64EncodedString()
    }

    static func forget(_ id: String) {
        made = made.filter { !$0.key.hasSuffix(" \(id)") }
    }

    private static func draw(_ image: NSImage, pixels: Int) -> Data? {
        guard pixels > 0, pixels <= 512,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = NSSize(width: pixels, height: pixels)
        let size = image.size
        let side = CGFloat(pixels)
        let scale = size.width > 0 && size.height > 0 ? min(side / size.width, side / size.height) : 1
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        let place = NSRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2,
                           width: fitted.width, height: fitted.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
