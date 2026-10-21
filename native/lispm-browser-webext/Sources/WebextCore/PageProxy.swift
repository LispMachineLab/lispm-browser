// The proxy the browser's pages load through, as WebKit takes it.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// WebKit takes proxies per website data store since macOS 14, as Network's
// ProxyConfiguration: an HTTP proxy is used with CONNECT, for http: pages
// too, and a SOCKS5 proxy looks the names up itself.  Emacs names the proxy
// by its kind, host and port, and the hosts reached directly as one string,
// separated by commas.

import Foundation
import Network

public enum PageProxy {
    /// The proxy of `kind`, "http" or "socks5", at `host` and `port`, the
    /// hosts of `exceptions` reached directly; nil for none, as for the
    /// kind "none", no host or a port out of range.
    public static func configuration(kind: String, host: String, port: Int,
                                     exceptions: String) -> ProxyConfiguration? {
        guard !host.isEmpty, let number = UInt16(exactly: port), number > 0,
              let port = NWEndpoint.Port(rawValue: number) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var proxy: ProxyConfiguration
        switch kind {
        case "http": proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case "socks5": proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        default: return nil
        }
        proxy.excludedDomains = hosts(exceptions)
        // A proxy that cannot be reached fails the page, rather than the
        // page loading around it.
        proxy.allowFailover = false
        return proxy
    }

    /// The hosts `text` names, separated by commas.
    public static func hosts(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
