// An extension's popup, in a popover of the module's own.
//
// From Search (https://github.com/driceroland/Search) at
// 6294b6aed35299c7ab91399a4b2374dd726b1f39, Sources/Search/ExtensionPopup.swift.
// There it hangs from the extension's button, and so it does here: Emacs
// draws the button and says where it is (Anchor); pressed from a menu or
// with nothing drawn, it hangs from the top right of the page in front.
// As in Chrome, it has no arrow, its right edge is under the button's, and
// it stays inside the window, however wide it grows.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions — but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.  It takes the
// keyboard while it is up, and Escape closes it.
//
// Copyright (c) 2026 Office Commun
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: MIT
// (The license is in LICENSE.Search, beside Package.swift.)

import AppKit
import WebKit
import WebextCore

@MainActor
final class Popup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = Popup()

    private var popover: NSPopover?
    private var web: WKWebView?
    /// The popup as WebKit is told about it: a page it can find, in the
    /// browser's window but not among its tabs, as Chrome has it.
    private var page: PopupPage?
    private var measuring: Timer?
    private(set) var extensionID: String?
    /// The button the popup that is up hangs from, if Emacs said.
    private var button: Anchor?
    /// What the popup that is up hangs under, in the coordinates of the
    /// view it is shown from: kept so that it is placed again as it grows.
    private var placed: (view: NSView, rect: NSRect)?

    /// The popup's web view, while one is up.
    var view: WKWebView? { web }

    /// On screen now.
    var isUp: Bool { popover?.isShown == true }

    /// The popup as its extension's worker finds it in clients.matchAll().
    func client(of id: String) -> [String: Any]? {
        guard extensionID == id, let url = web?.url else { return nil }
        return ["id": "popup", "url": url.absoluteString, "visible": isUp, "focused": isUp && web?.window?.isKeyWindow == true]
    }

    /// Where a popup hangs: under the extension's button, which Emacs draws.
    /// `rect` is the button in the pixels of the Emacs frame showing the page
    /// whose view is at `view`, from the frame's top left.
    struct Anchor {
        let view: Int
        let rect: NSRect

        init(view: Int, rect: NSRect) {
            self.view = view
            self.rect = rect
        }

        /// From Emacs: {"view", "x", "y", "width", "height"}, all numbers.
        init?(json: String) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let view = (object["view"] as? NSNumber)?.intValue else { return nil }
            let number = { (key: String) in (object[key] as? NSNumber)?.doubleValue }
            guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
                  width > 0, height > 0 else { return nil }
            self.init(view: view, rect: NSRect(x: x, y: y, width: width, height: height))
        }
    }

    /// The button's rectangle in the coordinates of the Emacs view the page
    /// at its address is in, and that view; nil when the page is gone.
    private func place(_ anchor: Anchor) -> (NSView, NSRect)? {
        guard let page = Host.shared?.tabs.tab(address: anchor.view)?.view, page.window != nil else { return nil }
        // The frame's own view, which Emacs draws the frame in: the page's
        // view sits inside it, in a view of its own.
        let frameView = NSClassFromString("EmacsView")
        var view: NSView? = page.superview
        while let found = view, let frameView, !found.isKind(of: frameView) { view = found.superview }
        guard let host = view ?? page.window?.contentView else { return nil }
        let r = anchor.rect
        let rect = host.isFlipped ? r : NSRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
        return (host, rect)
    }

    /// The anchor each extension's popup last hung from, for a popup the
    /// extension opens itself (action.openPopup) or that comes back.
    private var anchors: [String: Anchor] = [:]

    /// The extension whose popup the last click outside it closed, and when.
    private var closedByClick: (id: String, at: Date, anchor: Anchor?)?

    /// Whether the mouse just went down on extension `id`'s button and so
    /// closed its popup: the press that click makes once the mouse comes
    /// up must not open it again.
    func closedByItsButton(_ id: String) -> Bool {
        guard let closed = closedByClick, closed.id == id, Date().timeIntervalSince(closed.at) < 2 else { return false }
        closedByClick = nil
        return true
    }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?, at button: Anchor? = nil) {
        close()
        guard let host = Host.shared, let configuration = context.webViewConfiguration else { return }
        let button = button ?? anchors[context.uniqueIdentifier]
        // Sized the way Chrome sizes a popup (see preferred), unseen, while
        // the popover already stands at the size this popup had last time;
        // then shown. It has to be in the window meanwhile: WebKit suspends
        // a page that is in none.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.alphaValue = 0
        web.load(URLRequest(url: url))

        let stage = NSView(frame: NSRect(origin: .zero,
                                         size: Popup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)))
        stage.addSubview(web)
        let controller = NSViewController()
        controller.view = stage
        // The popover takes its size from its view controller: left at zero,
        // it comes in as a sliver and grows to the size it was given,
        // instead of standing at that size from the start.
        controller.preferredContentSize = stage.frame.size
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        let page = PopupPage(web: web)
        self.page = page
        host.controller.didOpenTab(page)

        shown = false
        if let button, let (view, rect) = place(button) {
            // Under the button.
            anchors[context.uniqueIdentifier] = button
            self.button = button
            placed = (view, rect)
        } else if let anchor, anchor.window != nil {
            // The page's top right, a little in.
            let bounds = anchor.bounds
            let top = anchor.isFlipped ? bounds.minY + 4 : bounds.maxY - 5
            placed = (anchor, NSRect(x: bounds.maxX - 8, y: top, width: 1, height: 1))
        } else if let content = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView {
            let bounds = content.bounds, flipped = content.isFlipped
            placed = (content, NSRect(x: bounds.maxX - 8, y: flipped ? bounds.minY + 40 : bounds.maxY - 40,
                                      width: 1, height: 1))
        }
        guard let (view, _) = placed else {
            close()
            return
        }
        // As Chrome's: no arrow, its right edge under the button's, inside
        // the window.  A popover centres itself on what it is shown from,
        // and AppKit keeps it on the screen but not in the window, so it is
        // shown from the point its middle should be under.
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
        popover.show(relativeTo: spot(width: popover.contentSize.width) ?? .zero, of: view,
                     preferredEdge: view.isFlipped ? .maxY : .minY)
        // The keyboard goes to the popup, as a click would give it.
        web.window?.makeKeyAndOrderFront(nil)
        web.window?.makeFirstResponder(web)
        // Its button shows pressed while the popup is up.
        host.changed()
        // Measured when the document is built (see below) or has loaded;
        // a page slow to do either is measured anyway after a moment, and
        // shown regardless a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak popover] in
            MainActor.assumeIsolated {
                guard let self, let popover, popover === self.popover else { return }
                self.firstMeasure()
                self.follow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak popover] in
            MainActor.assumeIsolated {
                guard let self, let popover, popover === self.popover else { return }
                self.reveal()
            }
        }
    }

    /// Each extension's popup size, so the next opening starts there.
    private static var lastSize: [String: NSSize] = [:]
    private var shown = false

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popover?.contentViewController?.view else { return }
        shown = true
        web.frame = NSRect(origin: .zero, size: popover?.contentSize ?? stage.bounds.size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    /// From the page's first load: sized, then followed as it grows — a
    /// list filled in by a reply from the worker — for as long as it's open.
    private func follow() {
        guard measuring == nil else { return }
        if !shown { firstMeasure() }
        ticks = 0
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.grow() }
        }
    }

    /// What the popover is shown from for a popup `width` wide, hanging
    /// under `placed`: a sliver of its height at the middle of where the
    /// popup goes, its right edge at the right edge of what it hangs under,
    /// and wholly in the view, a few points from its edges.
    private func spot(width: CGFloat) -> NSRect? {
        guard let (view, rect) = placed else { return nil }
        let bounds = view.bounds, margin: CGFloat = 4
        var right = min(rect.maxX, bounds.maxX - margin)
        if right - width < bounds.minX + margin { right = min(bounds.maxX - margin, bounds.minX + margin + width) }
        return NSRect(x: (right - width / 2).rounded(), y: rect.minY, width: 1, height: rect.height)
    }

    func close() {
        measuring?.invalidate()
        measuring = nil
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    /// Tells WebKit the popup's tab is gone, and Emacs its button is up again.
    private func forget() {
        let wasUp = popover != nil
        if let page { Host.shared?.controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
        placed = nil
        if wasUp { Host.shared?.changed() }
    }

    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content — what is positioned off
    /// to the side doesn't count), else, for a page with next to no width
    /// of its own, what its content spans; then, laid out at that width,
    /// the height it names or spans. Nothing of it is left on the page.
    static let preferred = """
    () => {
      const d = document.documentElement;
      if (!d) return null;
      const m = window.__lispmSizing || (window.__lispmSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      let w;
      if (Math.abs(box.width - innerWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - innerWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      w = Math.min(800, Math.max(25, Math.ceil(w)));
      d.style.setProperty("width", w + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h)))];
    }
    """

    /// The document is built — DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have. WebKit
    /// tells a navigation delegate that has this method; the configuration
    /// extension pages share can't be given a script of our own.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        firstMeasure()
    }

    /// Measured while still the 25-point square and unseen, then shown at
    /// the size found.
    private func firstMeasure() {
        guard let web, !shown else { return }
        web.evaluateJavaScript("(\(Popup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, !self.shown else { return }
                guard let pair = value as? [Double], pair.count == 2 else { return }
                self.apply(NSSize(width: pair[0], height: pair[1]))
            }
        }
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            // The popover takes its size from its view controller, and goes
            // back to it: both are told.
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
            // Wider, it is placed again, so as to stay in the window.
            if let spot = spot(width: size.width) { popover.positioningRect = spot }
        }
        if let id = extensionID { Popup.lastSize[id] = size }
        reveal()
    }

    /// How far the page reaches, as a function of "width" or "height":
    /// its own width if it names one wider than the view, else its
    /// narrowest, else, for a page that only fills the view and has next to
    /// no width of its own, what its content spans. Height: all it spans.
    static let reach = """
    ((key) => {
      const d = document.documentElement;
      if (!d) return null;
      if (key === "height") return d.scrollHeight;
      const own = d.getBoundingClientRect().width;
      if (own > innerWidth + 1) return own;
      const saved = d.getAttribute("style");
      d.style.setProperty("width", "min-content", "important");
      const narrowest = d.getBoundingClientRect().width;
      saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      return narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
    })
    """

    /// Measured again as the page builds itself, the way Chrome measures on
    /// each layout: for its first two seconds the popup follows it either
    /// way, after that it only grows — so a page that settles doesn't set
    /// it rocking.
    private var ticks = 0
    private func grow() {
        guard shown, let web, let popover else { return }
        ticks += 1
        if ticks <= 8 {
            web.evaluateJavaScript("(\(Popup.preferred))()") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let pair = value as? [Double], pair.count == 2 else { return }
                    let wanted = NSSize(width: pair[0], height: pair[1])
                    let now = popover.contentSize
                    if abs(wanted.width - now.width) > 2 || abs(wanted.height - now.height) > 2 { self.apply(wanted) }
                }
            }
            return
        }
        // After its first six seconds, once a second is enough to follow it.
        if ticks > 24, ticks % 4 != 0 { return }
        // A width the page names for itself, remembered as the first measure
        // does, is followed both ways.
        web.evaluateJavaScript("[\(Popup.reach)('width'), (() => { const d = document.documentElement; return d && d.scrollHeight > d.clientHeight ? d.scrollHeight : 0; })(), (() => { const m = window.__lispmSizing || (window.__lispmSizing = {}), w = document.documentElement.getBoundingClientRect().width; if (Math.abs(w - innerWidth) > 1) return m.w = w; return m.w && Math.abs(m.w - innerWidth) <= 1 ? m.w : 0; })()]") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let pair = value as? [Double], pair.count == 3 else { return }
                let now = popover.contentSize
                let width = pair[2] > 0 ? max(25, pair[2].rounded(.up)) : max(now.width, pair[0])
                let wanted = NSSize(width: min(800, width), height: min(600, max(now.height, pair[1])))
                if wanted != now { self.apply(wanted) }
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The same rule as tabs.create: never a file on this Mac, never javascript:.
        if let url = action.request.url, (try? Rules.mayOpen(url)) != nil {
            Host.shared?.events.send("open", ["url": url.absoluteString, "active": true])
        }
        close()
        return nil
    }

    /// A popover goes as the mouse goes down outside it.  When that was on
    /// the popup's own button, the press the click makes is no press: see
    /// closedByItsButton.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID else { return }
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
              let button, let (view, rect) = place(button), event.window === view.window else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        if rect.insetBy(dx: -2, dy: -2).contains(point) { closedByClick = (id, Date(), button) }
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        measuring?.invalidate()
        measuring = nil
        forget()
    }
}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs — which is where Chrome puts a popup too.
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?

    init(web: WKWebView) { self.web = web }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Host.shared?.tabs.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { Popup.shared.close() }
}
