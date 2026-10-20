// lispm-browser-webext: tests of the badge colours extensions set.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
@testable import WebextCore

final class BadgeTests: XCTestCase {
    func testColoursAsChromeTakesThem() {
        XCTAssertEqual(Badge.hex([255, 0, 0, 255]), "#FF0000")
        XCTAssertEqual(Badge.hex([16, 32, 48]), "#102030")
        XCTAssertEqual(Badge.hex("#0a0"), "#00AA00")
        XCTAssertEqual(Badge.hex("#4688F1"), "#4688F1")
        XCTAssertEqual(Badge.hex("#4688f1cc"), "#4688F1")
        XCTAssertEqual(Badge.hex(" rgb(70, 136, 241) "), "#4688F1")
        XCTAssertEqual(Badge.hex("rgba(0 0 0 / 0.5)"), "#000000")
        XCTAssertEqual(Badge.hex("rgb(100%, 0%, 0%)"), "#FF0000")
    }

    func testWhatNamesNoColourIsNone() {
        XCTAssertNil(Badge.hex([0, 0, 0, 0]))
        XCTAssertNil(Badge.hex("#00000000"))
        XCTAssertNil(Badge.hex("#12"))
        XCTAssertNil(Badge.hex("#zzzzzz"))
        XCTAssertNil(Badge.hex("rgb(1, 2)"))
        XCTAssertNil(Badge.hex(["red"]))
        XCTAssertNil(Badge.hex(""))
        XCTAssertNil(Badge.hex(NSNull()))
    }

    func testColoursHandedBack() {
        XCTAssertEqual(Badge.rgba("#4688F1"), [70, 136, 241, 255])
        XCTAssertEqual(Badge.rgba("nonsense"), [0, 0, 0, 255])
    }
}
