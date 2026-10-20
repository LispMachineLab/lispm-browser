// The browser's own pages, at lispm://, and the button the Chrome Web Store
// is given.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// lispm://extensions is the browser's page of extensions, as Chrome's
// chrome://extensions: a card for each, to turn it on and off, see what it
// may do, reload and remove it.  WebKit shows it in a tab like any page,
// from this handler of the lispm: scheme, which every page view Emacs makes
// is given (Host.prepare).  It talks to the browser through a script
// message handler that answers lispm: pages alone, in the main frame:
//
//   page --{kind: "list"}--> the extensions, as Emacs lists them, and more
//   page --{kind: "command", command, id}--> (lispm-browser-webext--event
//        "command" …), which runs what M-x would
//
// The Chrome Web Store's own "Add to Chrome" works in Chrome alone.  On its
// pages a script, in a content world of the browser's own that the store's
// scripts never see, puts "Add to LispM" in its place, which asks the same
// handler to add the extension the page is about; which one that is, is
// read from the page's address, never from the message.

import AppKit
import WebKit
import WebextCore

@MainActor
final class BrowserPages: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    static let shared = BrowserPages()
    static let scheme = "lispm"
    static let handlerName = "lispmBrowser"
    static let storeHost = "chromewebstore.google.com"
    /// Where the store's button runs: apart from the store's own scripts.
    static let storeWorld = WKContentWorld.world(name: "lispm-browser-store")

    /// The page views Emacs made, each given the scheme and the handler once.
    private let given = NSHashTable<WKUserContentController>.weakObjects()
    /// Views showing a page of the browser's or a store page with its button:
    /// told when the extensions change.
    private let showing = NSHashTable<WKWebView>.weakObjects()
    /// Loads of icons still running, which WebKit may stop.
    private var running: Set<ObjectIdentifier> = []

    /// Gives a page view's configuration the lispm: scheme, which WebKit
    /// takes only before the view is made.
    func prepare(_ configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: Self.scheme) == nil {
            configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        }
    }

    /// Gives a page view Emacs has made the line to the browser and the
    /// store's button.  Emacs gives each view a script controller of its
    /// own as it makes it, so they go to that one, once.
    func adopt(_ view: WKWebView) {
        let controller = view.configuration.userContentController
        guard !given.contains(controller) else { return }
        given.add(controller)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        controller.addScriptMessageHandler(self, contentWorld: Self.storeWorld, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.storeScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.storeWorld))
    }

    /// Whether `url` is one of the browser's own pages.
    static func isOwn(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme
    }

    /// The extensions changed: the pages showing them are told.
    func changed() {
        for view in showing.allObjects {
            guard let url = view.url else { continue }
            if Self.isOwn(url) {
                view.evaluateJavaScript("window.lispmChanged && window.lispmChanged()", completionHandler: nil)
            } else if url.host()?.lowercased() == Self.storeHost {
                view.evaluateJavaScript("window.lispmChanged && window.lispmChanged()", in: nil,
                                        in: Self.storeWorld, completionHandler: nil)
            }
        }
    }

    // MARK: - the scheme

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host()?.lowercased() == "extensions" else {
            fail(task, code: NSURLErrorFileDoesNotExist)
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count == 2, parts[0] == "icon" {
            icon(of: parts[1], for: task)
            return
        }
        guard parts.isEmpty else {
            fail(task, code: NSURLErrorFileDoesNotExist)
            return
        }
        showing.add(webView)
        respond(task, Data(Self.extensionsPage.utf8), type: "text/html")
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// An extension's icon, 96 pixels square, for the page's 48-point cards
    /// on a Retina screen; a grey puzzle piece for one without.
    private func icon(of id: String, for task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        running.insert(key)
        Task { @MainActor in
            let found = await Host.shared?.manifest(id)
            guard running.remove(key) != nil else { return }
            let png = Icons.png(found?.icon(for: NSSize(width: 48, height: 48)), key: "page \(id)", pixels: 96)
            if let png {
                respond(task, png, type: "image/png")
            } else {
                respond(task, Data(Self.puzzle.utf8), type: "image/svg+xml")
            }
        }
    }

    private func respond(_ task: any WKURLSchemeTask, _ data: Data, type: String) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store",
                // The page's own script and style, and nothing from elsewhere.
                "Content-Security-Policy": "default-src 'none'; img-src lispm: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
              ]) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    // MARK: - the line to the browser

    /// What a lispm: page may have Emacs do.
    static let commands: Set<String> = [
        "enable", "disable", "remove", "reload", "options", "pin", "unpin",
        "load-unpacked", "store", "store-page", "press",
    ]

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let view = message.webView, let host = Host.shared,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "Not a message for the browser")
            return
        }
        let origin = message.frameInfo.securityOrigin
        // The page's own world has no name; the store's button runs in ours.
        if message.world.name == nil, origin.protocol.lowercased() == Self.scheme, Self.isOwn(view.url) {
            showing.add(view)
            ownPage(kind, body, host: host, reply: replyHandler)
        } else if message.world.name == Self.storeWorld.name, origin.protocol.lowercased() == "https",
                  origin.host.lowercased() == Self.storeHost, let url = view.url, let id = Crx.storeID(of: url) {
            showing.add(view)
            storePage(kind, id: id, host: host, reply: replyHandler)
        } else {
            replyHandler(nil, "Not a page of the browser's")
        }
    }

    private func ownPage(_ kind: String, _ body: [String: Any], host: Host,
                         reply: @escaping @MainActor (Any?, String?) -> Void) {
        switch kind {
        case "list":
            Task { @MainActor in
                // Those not running are read from their folders, for their
                // descriptions and what they may do.
                for item in host.installed { _ = await host.manifest(item.id) }
                reply(host.list(details: true), nil)
            }
        case "command":
            guard let command = body["command"] as? String, Self.commands.contains(command) else {
                reply(nil, "No such command")
                return
            }
            let id = body["id"] as? String
            if let id, !host.installed.contains(where: { $0.id == id }) {
                reply(nil, "No such extension")
                return
            }
            host.events.send("command", ["command": command, "id": id.map { $0 as Any } ?? NSNull()])
            reply(true, nil)
        default:
            reply(nil, "No such message")
        }
    }

    private func storePage(_ kind: String, id: String, host: Host,
                           reply: @escaping @MainActor (Any?, String?) -> Void) {
        let installed = host.installed.contains { $0.id == id }
        switch kind {
        case "state":
            reply(["installed": installed], nil)
        case "add":
            // Removing from the store's page asks first, in Emacs.
            host.events.send("command", ["command": installed ? "ask-remove" : "install", "id": id])
            reply(true, nil)
        default:
            reply(nil, "No such message")
        }
    }

    // MARK: - what they show

    /// A puzzle piece, the extensions' sign, as the page's icon and for an
    /// extension without one.
    static let puzzle = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#80868B" \
        d="M4 7H8.2A2.6 2.6 0 1 1 12.8 7H17V11.2A2.6 2.6 0 1 1 17 15.8V20H4Z"/></svg>
        """

    /// The Chrome Web Store's button, in the browser's own content world:
    /// "Add to LispM" where the store's "Add to Chrome" stood, or at the top
    /// right of the page when the store's button is not found.  It says
    /// "Remove from LispM" once the extension is in.
    static let storeScript = #"""
    (() => {
      if (location.hostname !== "chromewebstore.google.com" || window.top !== window) return;
      const bridge = (body) => window.webkit.messageHandlers.lispmBrowser.postMessage(body);
      const detail = /\/detail\/(?:[^/?#]+\/)?([a-p]{32})(?:[/?#]|$)/;
      let shownFor = null, installed = false, busy = false;
      const style = document.createElement("style");
      style.textContent = `
        #lispm-add { font: 500 14px/20px "Google Sans", system-ui, sans-serif; color: #fff; background: #0b57d0;
          border: 0; border-radius: 20px; padding: 10px 24px; cursor: pointer; white-space: nowrap; }
        #lispm-add:hover { background: #0842a0; }
        #lispm-add.lispm-installed { color: #0b57d0; background: transparent; box-shadow: inset 0 0 0 1px #747775; }
        #lispm-add.lispm-floating { position: fixed; top: 76px; right: 24px; z-index: 2147483647;
          box-shadow: 0 1px 3px rgba(0,0,0,.3); }
        .lispm-hidden { display: none !important; }`;
      const theirs = () => Array.from(document.querySelectorAll("button")).find((b) =>
        b.id !== "lispm-add" && /\b(Add to|Remove from|Switch to) Chrome\b/i.test(b.textContent || ""));
      const label = (button) => {
        button.textContent = installed ? "Remove from LispM" : "Add to LispM";
        button.classList.toggle("lispm-installed", installed);
      };
      const place = () => {
        const match = location.pathname.match(detail);
        let ours = document.getElementById("lispm-add");
        if (!match) { if (ours) ours.remove(); shownFor = null; return; }
        if (!style.isConnected) document.head.appendChild(style);
        const store = theirs();
        if (ours && shownFor === match[1] && ours.isConnected
            && (store ? ours.nextSibling === store : ours.classList.contains("lispm-floating"))) return;
        if (!ours) {
          ours = document.createElement("button");
          ours.id = "lispm-add";
          ours.type = "button";
          ours.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            if (!busy) { busy = true; bridge({ kind: "add" }).finally(() => { busy = false; }); }
          }, true);
        }
        if (shownFor !== match[1]) { shownFor = match[1]; installed = false; refresh(); }
        label(ours);
        if (store) {
          ours.classList.remove("lispm-floating");
          store.classList.add("lispm-hidden");
          store.parentNode.insertBefore(ours, store);
        } else {
          ours.classList.add("lispm-floating");
          if (ours.parentNode !== document.body) document.body.appendChild(ours);
        }
      };
      const refresh = () => bridge({ kind: "state" }).then((state) => {
        installed = !!(state && state.installed);
        const ours = document.getElementById("lispm-add");
        if (ours) label(ours);
      }, () => {});
      window.lispmChanged = refresh;
      let pending = false;
      new MutationObserver(() => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; place(); });
      }).observe(document.documentElement, { childList: true, subtree: true });
      place();
    })();
    """#
}
