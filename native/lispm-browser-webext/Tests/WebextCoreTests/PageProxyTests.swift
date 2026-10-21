// lispm-browser-webext: tests of the proxy the pages load through.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import WebextCore

/// The hosts `proxy` reaches directly, as Network's own object holds them:
/// ProxyConfiguration's `excludedDomains` reads back empty, though it sets
/// them.
private func excluded(_ proxy: ProxyConfiguration) -> [String] {
    var hosts: [String] = []
    nw_proxy_config_enumerate_excluded_domains(proxy._nw) { hosts.append(String(cString: $0)) }
    return hosts
}

final class PageProxyTests: XCTestCase {
    func testAProxyOfEachKind() throws {
        let http = try XCTUnwrap(PageProxy.configuration(kind: "http", host: "127.0.0.1", port: 7890,
                                                         exceptions: "localhost, 127.0.0.1,::1"))
        XCTAssertEqual(excluded(http), ["localhost", "127.0.0.1", "::1"])
        XCTAssertFalse(http.allowFailover)
        let socks = try XCTUnwrap(PageProxy.configuration(kind: "socks5", host: "proxy.example", port: 1080,
                                                          exceptions: ""))
        XCTAssertEqual(excluded(socks), [])
        XCTAssertFalse(socks.allowFailover)
    }

    func testWhatNamesNoProxyIsNone() {
        XCTAssertNil(PageProxy.configuration(kind: "none", host: "", port: 0, exceptions: ""))
        XCTAssertNil(PageProxy.configuration(kind: "none", host: "127.0.0.1", port: 7890, exceptions: ""))
        XCTAssertNil(PageProxy.configuration(kind: "ftp", host: "127.0.0.1", port: 21, exceptions: ""))
        XCTAssertNil(PageProxy.configuration(kind: "http", host: "", port: 7890, exceptions: ""))
        XCTAssertNil(PageProxy.configuration(kind: "http", host: "127.0.0.1", port: 0, exceptions: ""))
        XCTAssertNil(PageProxy.configuration(kind: "socks5", host: "127.0.0.1", port: 70000, exceptions: ""))
    }

    func testHostsSeparatedByCommas() {
        XCTAssertEqual(PageProxy.hosts(" a.example ,, b.example,"), ["a.example", "b.example"])
        XCTAssertEqual(PageProxy.hosts(""), [])
    }
}
