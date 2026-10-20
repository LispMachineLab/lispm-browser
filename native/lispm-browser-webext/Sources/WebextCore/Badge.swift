// The colours of an extension's badge, as the browser draws it.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: GPL-3.0-or-later
//
// chrome.action.setBadgeBackgroundColor and setBadgeTextColor take a
// colour as four numbers, [r, g, b, a], or as a CSS colour string.  WebKit
// keeps them to itself, so the shim tells the browser, which keeps them as
// "#rrggbb" for Emacs, whose faces and SVG both read that.

import Foundation

public enum Badge {
    /// Chrome's badge when an extension sets no colour: white on red.
    public static let defaultBackground = "#D93025"
    public static let defaultText = "#FFFFFF"

    /// `value` as "#rrggbb", or nil when it names no colour: [r, g, b, a]
    /// numbers, "#rgb", "#rrggbb", "#rrggbbaa", or rgb() and rgba().  A
    /// colour as good as transparent is no colour.
    public static func hex(_ value: Any) -> String? {
        if let list = value as? [Any] {
            let numbers = list.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count >= 3, numbers.count == list.count else { return nil }
            if numbers.count >= 4, numbers[3] < 1 { return nil }
            return format(numbers[0], numbers[1], numbers[2])
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") {
            let digits = Array(text.dropFirst())
            guard digits.allSatisfy(\.isHexDigit) else { return nil }
            switch digits.count {
            case 3, 4:
                if digits.count == 4, digits[3] == "0" { return nil }
                return "#" + digits.prefix(3).map { "\($0)\($0)" }.joined().uppercased()
            case 6, 8:
                if digits.count == 8, String(digits[6...7]) == "00" { return nil }
                return "#" + String(digits.prefix(6)).uppercased()
            default:
                return nil
            }
        }
        if text.hasPrefix("rgb(") || text.hasPrefix("rgba("), text.hasSuffix(")"),
           let open = text.firstIndex(of: "(") {
            let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { String($0) }.filter { !$0.isEmpty }
            let numbers = parts.compactMap { part -> Double? in
                part.hasSuffix("%") ? Double(part.dropLast()).map { $0 * 2.55 } : Double(part)
            }
            guard numbers.count == parts.count, numbers.count == 3 || numbers.count == 4 else { return nil }
            if numbers.count == 4, numbers[3] == 0 { return nil }
            return format(numbers[0], numbers[1], numbers[2])
        }
        return nil
    }

    /// "#rrggbb" as Chrome hands a colour back, [r, g, b, 255].
    public static func rgba(_ hex: String) -> [Int] {
        let digits = Array(hex.dropFirst())
        guard hex.hasPrefix("#"), digits.count == 6,
              let value = Int(String(digits), radix: 16) else { return [0, 0, 0, 255] }
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, 255]
    }

    private static func format(_ r: Double, _ g: Double, _ b: Double) -> String {
        let clamp = { (x: Double) in Int(max(0, min(255, x.rounded()))) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
