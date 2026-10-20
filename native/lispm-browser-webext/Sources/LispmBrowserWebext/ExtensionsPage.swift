// lispm://extensions, the browser's page of extensions.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Laid out as Chrome's chrome://extensions: a bar with the page's name and
// the ways to add one, then a card for each extension, its icon, name,
// version and description, an on/off switch, Details and Remove, and Reload
// for one loaded from a folder.  Details (lispm://extensions/?id=…) shows
// what it may do, where it came from, its errors and its options.  Removing
// asks first, in the page, as Chrome does.  Everything is a button, so the
// browser's hints (f) reach it from the keyboard.  The page reads the
// extensions from the browser and has Emacs act on them (BrowserPages), and
// is told when they change.

extension BrowserPages {
    static let extensionsPage = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src lispm: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
    <meta name="color-scheme" content="light dark">
    <title>Extensions</title>
    <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%235F6368' d='M4 7H8.2A2.6 2.6 0 1 1 12.8 7H17V11.2A2.6 2.6 0 1 1 17 15.8V20H4Z'/%3E%3C/svg%3E">
    <style>
      :root {
        --bg: #f8fafd; --surface: #ffffff; --text: #1f1f1f; --muted: #5e5e5e; --line: #e3e3e3;
        --accent: #0b57d0; --accent-text: #ffffff; --accent-soft: #d3e3fd; --danger: #b3261e;
        --track: #e1e3e1; --thumb: #747775; --shadow: 0 1px 2px rgba(0,0,0,.12), 0 1px 3px 1px rgba(0,0,0,.06);
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1f1f1f; --surface: #2b2b2b; --text: #e3e3e3; --muted: #a8a8a8; --line: #444746;
          --accent: #a8c7fa; --accent-text: #062e6f; --accent-soft: #0842a0; --danger: #f2b8b5;
          --track: #444746; --thumb: #8e918f; --shadow: 0 1px 2px rgba(0,0,0,.4), 0 1px 3px 1px rgba(0,0,0,.25);
        }
      }
      * { box-sizing: border-box; }
      html, body { margin: 0; background: var(--bg); color: var(--text);
        font: 13px/20px system-ui, -apple-system, "Helvetica Neue", sans-serif; }
      header { position: sticky; top: 0; z-index: 2; display: flex; align-items: center; gap: 12px;
        height: 56px; padding: 0 16px 0 20px; background: var(--bg); border-bottom: 1px solid var(--line); }
      header h1 { margin: 0; font-size: 22px; line-height: 28px; font-weight: 400; flex: 1;
        display: flex; align-items: center; gap: 12px; }
      header h1 svg { width: 24px; height: 24px; fill: var(--muted); }
      main { max-width: 1200px; margin: 0 auto; padding: 24px; }
      button { font: inherit; font-weight: 500; color: var(--accent); background: transparent;
        border: 1px solid var(--line); border-radius: 18px; padding: 6px 16px; cursor: pointer; }
      button:hover { background: var(--accent-soft); }
      button.filled { color: var(--accent-text); background: var(--accent); border-color: var(--accent); }
      button.filled:hover { filter: brightness(1.08); }
      button.danger { color: var(--danger); }
      button.icon { border: 0; border-radius: 50%; width: 36px; height: 36px; padding: 0;
        display: inline-flex; align-items: center; justify-content: center; }
      button.icon svg { width: 20px; height: 20px; fill: var(--muted); }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); gap: 12px; }
      .card { display: flex; flex-direction: column; min-height: 160px; background: var(--surface);
        border-radius: 8px; box-shadow: var(--shadow); }
      .card .top { display: flex; gap: 20px; padding: 16px 20px 0; flex: 1; }
      .card img, .details img { width: 48px; height: 48px; flex: none; }
      .card .name { font-size: 15px; font-weight: 500; }
      .card .version { color: var(--muted); margin-left: 8px; font-weight: 400; font-size: 13px; }
      .card .description { color: var(--muted); margin-top: 4px; overflow: hidden; display: -webkit-box;
        -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
      .card .note { color: var(--danger); margin-top: 4px; }
      .card .bottom { display: flex; align-items: center; gap: 8px; padding: 12px 20px 16px; }
      .card .bottom .space { flex: 1; }
      .off .top { opacity: .6; }
      .switch { position: relative; width: 36px; height: 20px; padding: 0; border: 0; border-radius: 10px;
        background: var(--track); flex: none; }
      .switch::after { content: ""; position: absolute; top: 4px; left: 4px; width: 12px; height: 12px;
        border-radius: 50%; background: var(--thumb); transition: transform .15s, width .15s, height .15s, top .15s; }
      .switch[aria-checked="true"] { background: var(--accent); }
      .switch[aria-checked="true"]::after { transform: translateX(16px); top: 2px; left: 2px;
        width: 16px; height: 16px; background: var(--accent-text); }
      .switch:hover { background: var(--track); filter: brightness(.95); }
      .switch[aria-checked="true"]:hover { background: var(--accent); filter: brightness(1.08); }
      .empty { text-align: center; color: var(--muted); padding: 64px 0; font-size: 15px; }
      .details { background: var(--surface); border-radius: 8px; box-shadow: var(--shadow); max-width: 680px; margin: 0 auto; }
      .details .head { display: flex; align-items: center; gap: 12px; padding: 8px 16px 8px 8px;
        border-bottom: 1px solid var(--line); }
      .details .head h2 { margin: 0; font-size: 15px; font-weight: 500; flex: 1; }
      .details .row { display: flex; align-items: center; gap: 16px; padding: 14px 20px; border-bottom: 1px solid var(--line); }
      .details .row:last-child { border-bottom: 0; }
      .details .row .what { flex: 1; }
      .details .row .label { font-weight: 500; }
      .details .row .value { color: var(--muted); word-break: break-all; }
      .details ul { margin: 4px 0 0; padding-left: 20px; color: var(--muted); }
      .details .errors li { color: var(--danger); word-break: break-word; }
      dialog { border: 0; border-radius: 28px; padding: 24px; background: var(--surface); color: var(--text);
        box-shadow: 0 4px 8px 3px rgba(0,0,0,.15), 0 1px 3px rgba(0,0,0,.3); max-width: 400px; }
      dialog::backdrop { background: rgba(0,0,0,.32); }
      dialog h3 { margin: 0 0 12px; font-size: 22px; font-weight: 400; line-height: 28px; }
      dialog p { margin: 0 0 24px; color: var(--muted); }
      dialog .buttons { display: flex; justify-content: flex-end; gap: 8px; }
    </style>
    </head>
    <body>
    <header>
      <h1><svg viewBox="0 0 24 24"><path d="M4 7H8.2A2.6 2.6 0 1 1 12.8 7H17V11.2A2.6 2.6 0 1 1 17 15.8V20H4Z"/></svg>Extensions</h1>
      <button id="load-unpacked">Load unpacked</button>
      <button id="store" class="filled">Open Chrome Web Store</button>
    </header>
    <main id="main"></main>
    <dialog id="confirm">
      <h3 id="confirm-title"></h3>
      <p>It is removed with everything it kept: its settings and what it stored.</p>
      <div class="buttons"><button id="confirm-cancel">Cancel</button><button id="confirm-remove" class="filled">Remove</button></div>
    </dialog>
    <script>
    "use strict";
    const bridge = (body) => window.webkit.messageHandlers.lispmBrowser.postMessage(body);
    const run = (command, id) => bridge({ kind: "command", command, id: id || null });
    const icons = {
      back: "M19 11H8.4l4.3-4.3-1.4-1.4L4.6 12l6.7 6.7 1.4-1.4L8.4 13H19z",
      reload: "M12 5a7 7 0 1 0 6.9 8.2h-2.1A5 5 0 1 1 12 7c1.4 0 2.6.6 3.5 1.5L13 11h6V5l-2.1 2.1A7 7 0 0 0 12 5z",
    };
    const el = (tag, props = {}, ...children) => {
      const node = document.createElement(tag);
      for (const [key, value] of Object.entries(props)) {
        if (key === "class") node.className = value;
        else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
        else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value === true ? "" : value);
      }
      for (const child of children.flat()) if (child !== null && child !== undefined && child !== false)
        node.append(child instanceof Node ? child : document.createTextNode(String(child)));
      return node;
    };
    const svg = (path) => {
      const ns = "http://www.w3.org/2000/svg";
      const s = document.createElementNS(ns, "svg");
      s.setAttribute("viewBox", "0 0 24 24");
      const p = document.createElementNS(ns, "path");
      p.setAttribute("d", path);
      s.append(p);
      return s;
    };
    const iconOf = (x) => el("img", { src: `lispm://extensions/icon/${x.id}?v=${encodeURIComponent(x.version)}`, alt: "" });
    const toggle = (x) => el("button", {
      class: "switch", role: "switch", "aria-checked": x.enabled ? "true" : "false",
      title: x.enabled ? "Turn off" : "Turn on", "aria-label": x.enabled ? "Turn off" : "Turn on",
      onclick: () => run(x.enabled ? "disable" : "enable", x.id),
    });
    const state = (x) => x.enabled && !x.loaded ? "Could not start: see Details" : null;
    let extensions = [];
    const shown = () => new URLSearchParams(location.search).get("id");
    const go = (id) => {
      history.pushState(null, "", id ? `lispm://extensions/?id=${encodeURIComponent(id)}` : "lispm://extensions/");
      render();
      window.scrollTo(0, 0);
    };
    const confirmRemove = (x) => {
      const dialog = document.getElementById("confirm");
      document.getElementById("confirm-title").textContent = `Remove “${x.name}”?`;
      document.getElementById("confirm-remove").onclick = () => { dialog.close(); run("remove", x.id); if (shown()) go(null); };
      document.getElementById("confirm-cancel").onclick = () => dialog.close();
      dialog.showModal();
    };
    const card = (x) => el("div", { class: "card" + (x.enabled ? "" : " off") },
      el("div", { class: "top" }, iconOf(x),
        el("div", {},
          el("div", { class: "name" }, x.name, el("span", { class: "version" }, x.version)),
          el("div", { class: "description" }, x.description || ""),
          state(x) && el("div", { class: "note" }, state(x)),
          x.errors && x.errors.length ? el("div", { class: "note" }, x.errors.length === 1 ? "1 error" : `${x.errors.length} errors`) : null)),
      el("div", { class: "bottom" },
        el("button", { onclick: () => go(x.id) }, "Details"),
        el("button", { onclick: () => confirmRemove(x) }, "Remove"),
        el("span", { class: "space" }),
        x.source ? el("button", { class: "icon", title: "Reload", "aria-label": "Reload", onclick: () => run("reload", x.id) }, svg(icons.reload)) : null,
        toggle(x)));
    const row = (label, value, ...end) => el("div", { class: "row" },
      el("div", { class: "what" }, el("div", { class: "label" }, label), value), ...end);
    const details = (x) => el("div", { class: "details" },
      el("div", { class: "head" },
        el("button", { class: "icon", title: "Back", "aria-label": "Back", onclick: () => go(null) }, svg(icons.back)),
        iconOf(x), el("h2", {}, x.name)),
      row(x.enabled ? "On" : "Off", state(x) ? el("div", { class: "value" }, state(x)) : null, toggle(x)),
      x.description ? row("Description", el("div", { class: "value" }, x.description)) : null,
      row("Version", el("div", { class: "value" }, x.version)),
      row("ID", el("div", { class: "value" }, x.id)),
      row("Permissions", x.wants && x.wants.length
        ? el("ul", {}, x.wants.map((w) => el("li", {}, w)))
        : el("div", { class: "value" }, "It asks for nothing special.")),
      row("Pin to toolbar", el("div", { class: "value" }, "Its button shows on the toolbar."),
        el("button", { class: "switch", role: "switch", "aria-checked": x.pinned ? "true" : "false",
          "aria-label": "Pin to toolbar", onclick: () => run(x.pinned ? "unpin" : "pin", x.id) })),
      x.options ? row("Extension options", null, el("button", { onclick: () => run("options", x.id) }, "Open")) : null,
      x.fromStore
        ? row("Source", el("div", { class: "value" }, "Chrome Web Store"),
            el("button", { onclick: () => run("store-page", x.id) }, "View in Chrome Web Store"))
        : row("Source", el("div", { class: "value" }, `Unpacked, from ${x.source || "a folder"}`),
            el("button", { onclick: () => run("reload", x.id) }, "Reload")),
      x.errors && x.errors.length
        ? row("Errors", el("ul", { class: "errors" }, x.errors.slice(-20).map((e) => el("li", {}, e))))
        : null,
      row("Remove extension", null, el("button", { class: "danger", onclick: () => confirmRemove(x) }, "Remove")));
    const render = () => {
      const main = document.getElementById("main");
      const id = shown();
      const x = id && extensions.find((e) => e.id === id);
      document.title = x ? `${x.name} – Extensions` : "Extensions";
      if (x) main.replaceChildren(details(x));
      else if (extensions.length) main.replaceChildren(el("div", { class: "grid" }, extensions.map(card)));
      else main.replaceChildren(el("div", { class: "empty" },
        el("p", {}, "No extensions yet. Add one from the Chrome Web Store, or load one from a folder.")));
    };
    const load = () => bridge({ kind: "list" }).then((list) => { extensions = list || []; render(); }, () => {});
    window.lispmChanged = load;
    window.addEventListener("popstate", render);
    document.getElementById("load-unpacked").onclick = () => run("load-unpacked");
    document.getElementById("store").onclick = () => run("store");
    load();
    </script>
    </body>
    </html>
    """#
}
