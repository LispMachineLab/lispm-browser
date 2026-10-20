;;; lispm-browser-test.el --- Tests for lispm-browser  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-browser
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with `make test'.  Batch Emacs makes no WebKit pages: symbols stand
;; in for xwidgets, and the primitives taking them are stubbed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-browser)
(require 'lispm-browser-places)
(require 'lispm-browser-hints)
(require 'lispm-browser-extensions)

(defvar xwidget-list)

;;;; Addresses, tabs and the chrome

(ert-deftest lispm-browser-test-input-url ()
  "What is typed as an address is visited as one when it names a scheme or
a dotted host, over http for a local host, and searched for otherwise."
  (let ((lispm-browser-search-url "https://search.example/?q=%s"))
    (should (equal (lispm-browser-input-url "localhost:8080/x") "http://localhost:8080/x"))
    (should (equal (lispm-browser-input-url "127.0.0.1") "http://127.0.0.1"))
    (should (equal (lispm-browser-input-url "example.com/a") "https://example.com/a"))
    (should (equal (lispm-browser-input-url "file:///tmp/a.html") "file:///tmp/a.html"))
    (should (equal (lispm-browser-input-url "lisp machines") "https://search.example/?q=lisp%20machines"))))

(ert-deftest lispm-browser-test-tabs-keep-their-order ()
  "A new page joins the tabs at their end, shows them in its tab line until
the chrome says otherwise, and a killed one leaves them."
  (let ((lispm-browser--tab-order nil)
        (lispm-browser-tab-hook (list (lambda () (setq-local header-line-format "chrome"))))
        (a (generate-new-buffer " a"))
        (b (generate-new-buffer " b")))
    (cl-letf (((symbol-function 'run-at-time) #'ignore))
      (unwind-protect
          (progn
            (with-current-buffer a (lispm-browser--setup-tab))
            (with-current-buffer b (lispm-browser--setup-tab))
            (should (equal (lispm-browser-tabs) (list a b)))
            (should (equal (buffer-local-value 'tab-line-format a) '(:eval (lispm-browser-tab-line))))
            (should (equal (buffer-local-value 'header-line-format b) "chrome"))
            (kill-buffer a)
            (should (equal (lispm-browser-tabs) (list b))))
        (mapc #'kill-buffer (seq-filter #'buffer-live-p (list a b)))))))

(ert-deftest lispm-browser-test-plain-tab-line ()
  "The tab line has a tab per page, its own drawn in front, then +."
  (let ((lispm-browser--tab-order nil)
        (a (generate-new-buffer "*xwidget webkit: Alpha*"))
        (b (generate-new-buffer "*xwidget webkit: Beta*")))
    (unwind-protect
        (cl-letf (((symbol-function 'lispm-browser-favicon) #'ignore)
                  ((symbol-function 'lispm-browser-uri) #'ignore))
          (setq lispm-browser--tab-order (list a b))
          (let ((line (with-current-buffer b (lispm-browser-tab-line))))
            (should (equal (substring-no-properties line) " Alpha  Beta  + "))
            (should (eq (get-text-property 1 'face line) 'tab-line-tab-inactive))
            (should (eq (get-text-property 8 'face line) 'tab-line-tab-current))))
      (mapc #'kill-buffer (list a b)))))

(ert-deftest lispm-browser-test-open-url-goes-through-the-chrome ()
  "Opening an address with no page shown shows the browser first, then
visits it in the page shown, and brings the browser in front."
  (let* ((window nil)
         (calls nil)
         (lispm-browser-window-function (lambda () window))
         (lispm-browser-show-function (lambda () (push 'show calls) (setq window (selected-window))))
         (lispm-browser-raise-function (lambda () (push 'raise calls)))
         (lispm-browser-change-hook (list (lambda () (push 'changed calls)))))
    (cl-letf (((symbol-function 'xwidget-at) (lambda (_) 'xwidget))
              ((symbol-function 'xwidget-webkit-goto-uri)
               (lambda (_xwidget url) (push (list 'go url) calls))))
      (lispm-browser-open-url "https://example.org/")
      (should (equal (reverse calls)
                     '(show (go "https://example.org/") changed raise raise))))))

(ert-deftest lispm-browser-test-closing-the-last-tab-quits ()
  "Closing a tab shows the next; closing the last quits the browser.
Quitting tells the chrome before the tabs close and after."
  (let* ((lispm-browser--tab-order nil)
         (a (generate-new-buffer " a"))
         (b (generate-new-buffer " b"))
         (calls nil)
         (lispm-browser-window-function #'selected-window)
         (lispm-browser-before-quit-hook
          (list (lambda () (push (list 'before (length (lispm-browser-tabs))) calls))))
         (lispm-browser-quit-hook
          (list (lambda () (push (list 'after (length (lispm-browser-tabs))) calls)))))
    (unwind-protect
        (save-window-excursion
          (setq lispm-browser--tab-order (list a b))
          (switch-to-buffer a)
          (lispm-browser-close-shown-tab)
          (should (eq (window-buffer) b))
          (should-not calls)
          (lispm-browser-close-shown-tab)
          (should (equal (reverse calls) '((before 0) (after 0))))
          (should-not (lispm-browser-tabs))
          ;; Quitting closes the tabs between the two hooks.
          (setq calls nil
                a (generate-new-buffer " a")
                b (generate-new-buffer " b")
                lispm-browser--tab-order (list a b))
          (lispm-browser-quit)
          (should (equal (reverse calls) '((before 2) (after 0))))
          (should-not (seq-some #'buffer-live-p (list a b))))
      (mapc #'kill-buffer (seq-filter #'buffer-live-p (list a b))))))

;;;; History and bookmarks

(defmacro lispm-browser-test--with-places (&rest body)
  "Run BODY with an empty history and bookmark list, in files of their own."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "lispm-browser-places" t))
          (lispm-browser-history-file (expand-file-name "history.eld" directory))
          (lispm-browser--history nil)
          (lispm-browser--history-loaded nil)
          (lispm-browser--history-timer nil)
          (bookmark-default-file (expand-file-name "bookmarks" directory))
          (bookmark-alist nil)
          (bookmark-bookmarks-timestamp nil)
          (bookmark-save-flag nil))
     (unwind-protect
         (cl-letf (((symbol-function 'run-with-idle-timer) #'ignore))
           ,@body)
       (delete-directory directory t))))

(ert-deftest lispm-browser-test-history-keeps-each-page-once ()
  "A page visited again moves to the top with its visits counted; only web
and file pages are kept, and only so many."
  (lispm-browser-test--with-places
   (let ((lispm-browser-history-size 2))
     (lispm-browser-history-add "https://a.example/" "A")
     (lispm-browser-history-add "about:blank" "")
     (lispm-browser-history-add "https://b.example/" "B")
     (lispm-browser-history-add "https://a.example/" "")
     (should (equal (mapcar #'car lispm-browser--history)
                    '("https://a.example/" "https://b.example/")))
     (should (equal (nth 1 (car lispm-browser--history)) "A"))
     (should (= (nth 3 (car lispm-browser--history)) 2))
     (lispm-browser-history-add "https://c.example/" "C")
     (should (equal (mapcar #'car lispm-browser--history)
                    '("https://c.example/" "https://a.example/"))))))

(ert-deftest lispm-browser-test-history-is-saved-and-read ()
  "The history is written to its file and read back from it."
  (lispm-browser-test--with-places
   (lispm-browser-history-add "https://a.example/" "A")
   (lispm-browser--save-history)
   (setq lispm-browser--history nil
         lispm-browser--history-loaded nil)
   (should (equal (car (car (lispm-browser-history))) "https://a.example/"))))

(ert-deftest lispm-browser-test-history-days ()
  "History is listed under the day of each visit."
  (let ((now (float-time)))
    (should (equal (lispm-browser-history-day now) "Today"))
    (should (equal (lispm-browser-history-day (- now 86400)) "Yesterday"))
    (should (equal (lispm-browser-history-day (- now (* 10 86400))) "Last Week"))
    (should (equal (lispm-browser-history-day (- now (* 40 86400))) "Earlier"))))

(ert-deftest lispm-browser-test-bookmarks-are-emacs-bookmarks ()
  "A page bookmarked is an Emacs bookmark xwidget can open; it is kept
once, and the browser lists only web pages' bookmarks, oldest first."
  (lispm-browser-test--with-places
   (bookmark-store "notes" '((filename . "/tmp/notes.org")) nil)
   (cl-letf (((symbol-function 'lispm-browser-shown-buffer) (lambda () (current-buffer)))
             ((symbol-function 'lispm-browser-title) (lambda (_) "Example"))
             ((symbol-function 'lispm-browser-uri) (lambda (_) "https://example.com/")))
     (lispm-browser-add-bookmark)
     (lispm-browser-add-bookmark))
   (should (equal (lispm-browser-bookmarks) '(("Example" . "https://example.com/"))))
   (should (eq (bookmark-prop-get "Example" 'handler) 'xwidget-webkit-bookmark-jump-handler))
   (should (equal (lispm-browser--bookmark-name "Example") "Example <2>"))
   (lispm-browser-delete-bookmark "Example")
   (should-not (lispm-browser-bookmarks))))

;;;; Page scripts and closed pages

(ert-deftest lispm-browser-test-keeps-script-callbacks ()
  "A script's callback is kept from the garbage collector until WebKit
calls it, and let go then; a script sent without one keeps nothing.  A
symbol stands in for the xwidget, which batch Emacs cannot make, and the
primitive handing scripts to WebKit is stubbed."
  (let ((lispm-browser--script-callbacks nil)
        (xwidget (make-symbol "xwidget"))
        (sent nil)
        (answers nil))
    (cl-letf (((symbol-function 'xwidget-webkit-execute-script)
               (lambda (xwidget script &optional fun) (push (list xwidget script fun) sent))))
      (lispm-browser-run-script xwidget "1 + 1")
      (should (equal sent `((,xwidget "1 + 1" nil))))
      (should-not lispm-browser--script-callbacks)
      (lispm-browser-run-script xwidget "document.title" (lambda (value) (push value answers)))
      (let ((answered (nth 2 (car sent))))
        (should (functionp answered))
        (should (equal (mapcar #'car lispm-browser--script-callbacks) (list answered)))
        (should (eq (nth 1 (car lispm-browser--script-callbacks)) xwidget))
        (funcall answered "Title")
        (should (equal answers '("Title")))
        (should-not lispm-browser--script-callbacks)))))

(ert-deftest lispm-browser-test-prunes-script-callbacks ()
  "Callbacks WebKit never calls are let go as scripts are sent: once a
minute old, those of closed pages all, those of open pages but the
newest few.  Younger ones are all kept, a closed page's too."
  (let* ((open (make-symbol "open"))
         (closed (make-symbol "closed"))
         (xwidget-list (list open))
         (now (float-time))
         (old (- now lispm-browser--script-callback-age 1))
         (young-closed (list 'young-closed closed now))
         (old-open-1 (list 'old-open-1 open old))
         (old-closed (list 'old-closed closed old))
         (old-open-2 (list 'old-open-2 open old))
         (old-open-3 (list 'old-open-3 open old))
         (lispm-browser--script-callbacks
          (list young-closed old-open-1 old-closed old-open-2 old-open-3))
         (lispm-browser--script-callbacks-kept 2))
    (cl-letf (((symbol-function 'xwidget-webkit-execute-script) #'ignore))
      (lispm-browser-run-script open "1 + 1" #'ignore))
    (should (equal (cdr lispm-browser--script-callbacks)
                   (list young-closed old-open-1 old-open-2)))
    (should (eq (nth 1 (car lispm-browser--script-callbacks)) open))))

(ert-deftest lispm-browser-test-script-callers-keep-callbacks ()
  "The favicon lookup and the hints send their scripts through
`lispm-browser-run-script', so the lambdas they pass are kept."
  (require 'lispm-browser-hints)
  (let ((lispm-browser--script-callbacks nil)
        (xwidget (make-symbol "xwidget"))
        (sent nil))
    (cl-letf (((symbol-function 'xwidget-webkit-execute-script)
               (lambda (_xwidget _script &optional fun) (push fun sent)))
              ((symbol-function 'xwidget-at) (lambda (_pos) xwidget))
              ((symbol-function 'lispm-browser--page-xwidget) (lambda () xwidget)))
      (with-temp-buffer
        (lispm-browser--look-up-favicon (current-buffer) "https://example.org/"))
      (lispm-browser-first-field)
      (should (= (length sent) 2))
      (should (seq-every-p #'functionp sent))
      (should (equal (mapcar #'car lispm-browser--script-callbacks) sent)))))

(ert-deftest lispm-browser-test-hint-labels ()
  "Hint labels are distinct and all as long, so none begins another: one
letter each while the letters suffice, two when they do not."
  (require 'lispm-browser-hints)
  (let ((lispm-browser-hint-characters "asd"))
    (should (equal (lispm-browser-hint-labels 3) '("a" "s" "d")))
    (let ((labels (lispm-browser-hint-labels 7)))
      (should (= (length labels) 7))
      (should (= (length (delete-dups (copy-sequence labels))) 7))
      (should (seq-every-p (lambda (label) (= (length label) 2)) labels))
      (should (equal (car labels) "aa")))
    (should-not (lispm-browser-hint-labels 0))))

(ert-deftest lispm-browser-test-drops-events-of-killed-xwidgets ()
  "An xwidget event reaches `xwidget-event-handler' only while its xwidget
is in `xwidget-list'; other events pass.  Symbols stand in for xwidgets,
which batch Emacs cannot make: the guard only compares them."
  (let* ((live (make-symbol "live"))
         (killed (make-symbol "killed"))
         (xwidget-list (list live)))
    (should (lispm-browser--xwidget-event-live-p
             `(xwidget-event load-changed ,live "load-finished")))
    (should-not (lispm-browser--xwidget-event-live-p
                 `(xwidget-event load-changed ,killed "load-finished")))
    (should-not (lispm-browser--xwidget-event-live-p
                 `(xwidget-event javascript-callback ,killed ignore "answer")))
    (let ((last-input-event `(xwidget-event load-changed ,killed "load-started")))
      (should-not (lispm-browser--xwidget-event-live-p)))
    (should (lispm-browser--xwidget-event-live-p ?a))))

(ert-deftest lispm-browser-test-keeps-killed-xwidgets ()
  "A killed buffer's xwidgets are kept from the garbage collector until a
timer lets them go, and a buffer without xwidgets keeps nothing."
  (let ((lispm-browser--killed-xwidgets nil)
        (xwidget (make-symbol "xwidget"))
        (xwidgets nil)
        (timers nil))
    (cl-letf (((symbol-function 'get-buffer-xwidgets) (lambda (_) xwidgets))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args) (push (cons function args) timers))))
      (with-temp-buffer (lispm-browser--keep-killed-xwidgets))
      (should-not lispm-browser--killed-xwidgets)
      (should-not timers)
      (setq xwidgets (list xwidget))
      (with-temp-buffer (lispm-browser--keep-killed-xwidgets))
      (should (equal lispm-browser--killed-xwidgets (list xwidget)))
      (should (= (length timers) 1))
      (apply (caar timers) (cdar timers))
      (should-not lispm-browser--killed-xwidgets))))

;;;; Chrome extensions

(ert-deftest lispm-browser-test-extensions-only-on-a-mac-with-pages ()
  "Pages run extensions only in the Mac build with xwidgets, on macOS 15.4
or later."
  (let ((system-type 'gnu/linux))
    (should-not (lispm-browser-extensions-supported-p)))
  (let ((system-type 'darwin))
    (cl-letf (((symbol-function 'featurep) (lambda (feature &rest _) (memq feature '(ns xwidget-internal)))))
      (let ((lispm-browser-extensions--macos-version "15.3.2"))
        (should-not (lispm-browser-extensions-supported-p)))
      (let ((lispm-browser-extensions--macos-version "15.4"))
        (should (lispm-browser-extensions-supported-p)))
      (let ((lispm-browser-extensions--macos-version "27.0"))
        (should (lispm-browser-extensions-supported-p))))))

(ert-deftest lispm-browser-test-extensions-know-a-page-by-its-view ()
  "A page is named to the module by its view's address, which Emacs prints
with its xwidget; a killed xwidget names none."
  (should (eql (lispm-browser-extensions--address-in "#<xwidget 3 0x600001c2a0f0>")
               #x600001c2a0f0))
  (should-not (lispm-browser-extensions--address-in "#<killed xwidget>"))
  (should-not (lispm-browser-extensions--address-in "#<buffer *scratch*>")))

(ert-deftest lispm-browser-test-extensions-read-store-pages ()
  "The extension of a Chrome Web Store page is read from its address, on the
store itself over HTTPS only."
  (let ((id "ddkjiahejlhfcafbddmgiahcphecmpfh"))
    (should (equal (lispm-browser-extensions--store-id
                    (concat "https://chromewebstore.google.com/detail/ublock-origin-lite/" id))
                   id))
    (should (equal (lispm-browser-extensions--store-id
                    (concat "https://chromewebstore.google.com/detail/" id "?hl=en"))
                   id))
    (should (equal (lispm-browser-extensions--store-id
                    (concat "https://chrome.google.com/webstore/detail/name/" id "/reviews"))
                   id))
    (should-not (lispm-browser-extensions--store-id
                 (concat "http://chromewebstore.google.com/detail/name/" id)))
    (should-not (lispm-browser-extensions--store-id
                 (concat "https://evil.example/detail/name/" id)))
    (should-not (lispm-browser-extensions--store-id
                 (concat "https://chromewebstore.google.com/detail/name/" id "a")))
    (should-not (lispm-browser-extensions--store-id nil))))

(ert-deftest lispm-browser-test-extensions-stale-module ()
  "The module is stale when a source of it is newer than its library."
  (let* ((source (make-temp-file "lispm-browser-webext" t))
         (lispm-browser-extensions-source-directory source)
         (library (expand-file-name ".build/release/liblispm_browser_webext.dylib" source))
         (swift (expand-file-name "Sources/LispmBrowserWebext/Host.swift" source)))
    (unwind-protect
        (progn
          (should-not (lispm-browser-extensions--module-file))
          (make-directory (file-name-directory library) t)
          (make-directory (file-name-directory swift) t)
          (dolist (file (list (expand-file-name "Package.swift" source) swift))
            (write-region "" nil file)
            (set-file-times file (time-subtract nil 60)))
          (write-region "" nil library)
          (should (equal (lispm-browser-extensions--module-file) library))
          (should-not (lispm-browser-extensions--stale-p))
          (set-file-times swift (time-add nil 60))
          (should (lispm-browser-extensions--stale-p)))
      (delete-directory source t))))

(ert-deftest lispm-browser-test-extensions-events ()
  "The module's events: a message shows, a change forgets the list and runs
the hook, and a question is asked after the filter returns and answered,
no when quit."
  (let ((lispm-browser-extensions--installed '((:id "a")))
        (changed nil)
        (answers nil)
        (later nil)
        (reply 'yes))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args) (push (cons function args) later)))
              ((symbol-function 'yes-or-no-p)
               (lambda (prompt)
                 (should (string-match-p "Add “X 1”\\?\n  • Block\n  • Read\n" prompt))
                 (pcase reply ('yes t) ('no nil) ('quit (signal 'quit nil)))))
              ((symbol-function 'lispm-browser-webext-module-answer)
               (lambda (id value) (push (cons id value) answers))))
      (let ((lispm-browser-extensions-changed-hook (list (lambda () (setq changed t)))))
        (lispm-browser-webext--event "changed" "null")
        (should changed)
        (should (eq lispm-browser-extensions--installed 'unread)))
      (let ((shown nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args) (setq shown (apply #'format-message format args)))))
          (lispm-browser-webext--event "message" "\"X is installed\""))
        (should (equal shown "X is installed")))
      (let ((ask "{\"request\":7,\"question\":\"Add “X 1”?\",\"details\":[\"Block\",\"Read\"]}"))
        (lispm-browser-webext--event "ask" ask)
        (should-not answers)
        (pcase-let ((`(,function . ,args) (pop later)))
          (apply function args))
        (should (equal answers '((7 . 1))))
        (setq reply 'no answers nil)
        (lispm-browser-webext--event "ask" ask)
        (pcase-let ((`(,function . ,args) (pop later))) (apply function args))
        (should (equal answers '((7))))
        (setq reply 'quit answers nil)
        (lispm-browser-webext--event "ask" ask)
        (pcase-let ((`(,function . ,args) (pop later)))
          (should-error (apply function args) :type 'quit))
        (should (equal answers '((7))))))))

(ert-deftest lispm-browser-test-extensions-open-tabs ()
  "An extension's new tab opens in the browser, made for the extension's
page when it is one, and the module is answered with its view."
  (let ((calls nil)
        (answers nil))
    (cl-letf (((symbol-function 'lispm-browser-window) #'always)
              ((symbol-function 'lispm-browser-webext-module-expect-page)
               (lambda (url)
                 (push (list 'expect url) calls)
                 (string-prefix-p "chrome-extension:" url)))
              ((symbol-function 'lispm-browser-new-tab)
               (lambda (url) (push (list 'tab url) calls)))
              ((symbol-function 'xwidget-webkit-goto-uri)
               (lambda (_xwidget url) (push (list 'go url) calls)))
              ((symbol-function 'lispm-browser-extensions--address)
               (lambda (_xwidget) 42))
              ((symbol-function 'lispm-browser-webext-module-answer)
               (lambda (id value) (push (cons id value) answers))))
      ;; The extension's page: the tab opens blank and is sent there, as
      ;; `xwidget-webkit-browse-url' would take chrome-extension: for a host.
      (lispm-browser-extensions--open
       '(:url "chrome-extension://abc/welcome.html" :active t :request 3))
      (should (equal (reverse calls) '((expect "chrome-extension://abc/welcome.html")
                                       (tab "about:blank")
                                       (go "chrome-extension://abc/welcome.html"))))
      (should (equal answers '((3 . 42))))
      ;; A website opens straight away; asked for nothing back, nothing is
      ;; answered.
      (setq answers nil calls nil)
      (lispm-browser-extensions--open '(:url "https://example.com/" :active t))
      (should (equal (reverse calls) '((expect "https://example.com/") (tab "https://example.com/"))))
      (should-not answers))))

(ert-deftest lispm-browser-test-extensions-follow-the-page-in-front ()
  "The module hears which page is in front, once it runs."
  (let ((lispm-browser-extensions--started t)
        (told nil)
        (address 1))
    (with-temp-buffer
      (let ((page (current-buffer)))
        (cl-letf (((symbol-function 'lispm-browser-extensions--front-buffer) (lambda () page))
                  ((symbol-function 'xwidget-at) (lambda (_) 'xwidget))
                  ((symbol-function 'lispm-browser-extensions--address) (lambda (_) address))
                  ((symbol-function 'lispm-browser-webext-module-activate) (lambda (a) (push a told))))
          (lispm-browser-extensions--follow)
          (setq address 2)
          (lispm-browser-extensions--follow)
          (should (equal told '(2 1)))
          (let ((lispm-browser-extensions--started nil))
            (lispm-browser-extensions--follow))
          (should (equal told '(2 1))))))))

(ert-deftest lispm-browser-test-extensions-menu ()
  "The Extensions menu has each running extension's button, its badge in
the label, Pin to Toolbar with each one checked when pinned, then the
Chrome Web Store, adding the extension of the page shown when it is a
store page, and managing them."
  (let ((lispm-browser-extensions--started t)
        (lispm-browser-extensions--installed
         '((:id "a" :name "Blocker" :loaded t :badge "12" :actionEnabled t :pinned t)
           (:id "b" :name "Off" :enabled nil :loaded nil)))
        (pinned nil))
    (cl-letf (((symbol-function 'lispm-browser-extensions--shown-store-id) #'ignore)
              ((symbol-function 'lispm-browser-webext-module-set-pinned)
               (lambda (id on) (push (cons id on) pinned))))
      (let* ((items (lispm-browser-extensions-menu-items))
             (pins (plist-get (nth 2 items) :submenu)))
        (should (equal (plist-get (car items) :label) "Blocker [12]"))
        (should (eq (nth 1 items) 'separator))
        (should (equal (plist-get (nth 2 items) :label) "Pin to Toolbar"))
        (should (equal (mapcar (lambda (item) (plist-get item :label)) pins) '("Blocker")))
        (should (plist-get (car pins) :checked))
        (funcall (plist-get (car pins) :action))
        (should (equal pinned '(("a"))))
        (should (eq (nth 3 items) 'separator))
        (should (equal (plist-get (nth 4 items) :label) "Chrome Web Store"))
        (should (eq (plist-get (nth 4 items) :action) 'lispm-browser-extensions-store))
        (should (equal (plist-get (nth 5 items) :label) "Add This Extension"))
        (should-not (plist-get (nth 5 items) :enabled))
        (should (eq (plist-get (car (last items)) :action) 'lispm-browser-extensions))
        (should-not (seq-find (lambda (item) (equal (plist-get item :label) "Off"))
                              (seq-filter #'consp items)))))
    (cl-letf (((symbol-function 'lispm-browser-extensions--shown-store-id)
               (lambda () "ddkjiahejlhfcafbddmgiahcphecmpfh")))
      (should (plist-get (nth 5 (lispm-browser-extensions-menu-items)) :enabled))))
  (let ((lispm-browser-extensions--started nil))
    (cl-letf (((symbol-function 'lispm-browser-extensions--shown-store-id) #'ignore))
      (should (equal (plist-get (car (lispm-browser-extensions-menu-items)) :label)
                     "Chrome Web Store")))))

(ert-deftest lispm-browser-test-extensions-menus-as-emacs-menus ()
  "A menu's items become a menu keymap of Emacs's: commands, functions,
greyed items, check marks, separators and submenus."
  (let* ((ran nil)
         (map (lispm-browser-extensions--keymap-menu
               "Extensions"
               `((:label "Press" :action ,(lambda () (setq ran t)))
                 (:label "Off" :action ignore :enabled nil)
                 separator
                 (:label "Pins" :submenu ((:label "One" :action ignore :checked t)))))))
    (should (equal (keymap-prompt map) "Extensions"))
    (pcase-let ((`(menu-item ,label ,command . ,props) (cdr (assq 'item-1 map))))
      (should (equal label "Press"))
      (should (commandp command))
      (call-interactively command)
      (should ran)
      (should (eq (plist-get props :enable) t)))
    (should-not (plist-get (nthcdr 3 (cdr (assq 'item-2 map))) :enable))
    (should (equal (cdr (assq 'item-3 map)) menu-bar-separator))
    (let ((pins (cdr (cdr (assq 'item-4 map)))))
      (should (equal (plist-get (nthcdr 3 (cdr (assq 'item-1 pins))) :button) '(:toggle . t))))))

(ert-deftest lispm-browser-test-extensions-buttons ()
  "The toolbar shows the running extensions pinned to it, then one popped
out while its popup is up or being opened; each button says what to draw."
  (let ((lispm-browser-extensions--started t)
        (lispm-browser-extensions--popped-out "c")
        (lispm-browser-extensions--installed
         '((:id "a" :name "Blocker" :label "Block ads" :loaded t :pinned t :badge "3"
            :badgeColor "#123456" :actionEnabled t :popup t)
           (:id "b" :name "Unpinned" :loaded t :badge "")
           (:id "c" :name "Wallet" :loaded t :popup t)
           (:id "d" :name "Up" :loaded t :popupShown t)
           (:id "e" :name "Off" :loaded nil :pinned t))))
    (let ((buttons (lispm-browser-extensions-buttons)))
      (should (equal (mapcar (lambda (button) (plist-get button :id)) buttons) '("a" "c" "d")))
      (should (equal (plist-get (car buttons) :name) "Block ads"))
      (should (equal (plist-get (car buttons) :badge) "3"))
      (should (equal (plist-get (car buttons) :badge-color) "#123456"))
      (should (equal (plist-get (car buttons) :badge-text-color) "#FFFFFF"))
      (should (plist-get (car buttons) :enabled))
      (should (plist-get (nth 2 buttons) :open))
      (should-not (plist-get (nth 1 buttons) :pinned)))
    (let ((lispm-browser-extensions--started nil))
      (should-not (lispm-browser-extensions-buttons)))))

(ert-deftest lispm-browser-test-extensions-press-under-the-button ()
  "Pressing hands the module the button's rectangle, with a page view of
its frame; from the keyboard the anchor function says where the button
is.  An unpinned extension pops out while its popup is up, and not when
it has none."
  (let ((lispm-browser-extensions--started t)
        (lispm-browser-extensions--popped-out nil)
        (lispm-browser-extensions--installed 'unread)
        (list '((:id "a" :name "Pinned" :loaded t :pinned t)
                (:id "b" :name "Unpinned" :loaded t)))
        (popup nil)
        (with-popups '("b"))
        (pressed nil)
        (asked nil)
        (lispm-browser-extensions-changed-hook nil))
    (cl-letf (((symbol-function 'lispm-browser-extensions--follow) #'ignore)
              ((symbol-function 'lispm-browser-webext-module-list)
               (lambda ()
                 (json-encode (vconcat (mapcar (lambda (extension)
                                                 (if (and popup (equal (plist-get extension :id) popup))
                                                     (append extension '(:popupShown t))
                                                   extension))
                                               list)))))
              ((symbol-function 'lispm-browser-extensions--frame-view) (lambda (_frame) 7))
              ((symbol-function 'lispm-browser-webext-module-press)
               (lambda (id anchor)
                 (when (member id with-popups) (setq popup id))
                 (push (cons id anchor) pressed)
                 t)))
      (lispm-browser-extensions-press "a" (list (selected-frame) 100 20 28 30))
      (should (equal (json-parse-string (cdar pressed) :object-type 'alist)
                     '((view . 7) (x . 100) (y . 20) (width . 28) (height . 30))))
      (let ((lispm-browser-extensions-anchor-function
             (lambda (id)
               (push (cons id lispm-browser-extensions--popped-out) asked)
               (list (selected-frame) 1 2 3 4))))
        ;; Unpinned, with a popup: popped out before its place is asked.
        (lispm-browser-extensions-press "b")
        (should (equal (car asked) '("b" . "b")))
        (should (equal lispm-browser-extensions--popped-out "b"))
        (should (equal (caar pressed) "b"))
        ;; Its popup down, it goes back.
        (setq popup nil)
        (lispm-browser-extensions--changed)
        (should-not lispm-browser-extensions--popped-out)
        ;; Without a popup it never stays.
        (setq with-popups nil)
        (lispm-browser-extensions-press "b")
        (should-not lispm-browser-extensions--popped-out)
        ;; Nowhere to hang from: the page's top right.
        (let ((lispm-browser-extensions-anchor-function #'ignore))
          (lispm-browser-extensions-press "a")
          (should (equal (car pressed) '("a"))))))))

(ert-deftest lispm-browser-test-extensions-click-anchors ()
  "A click's anchor is the rectangle of what it was on, in its frame: a
tab line's from the window's top left."
  (let* ((window (selected-window))
         (edges (window-pixel-edges window))
         (event `(mouse-1 (,window tab-line (130 . 6) 0 nil nil (0 . 0) nil (10 . 4) (28 . 22)))))
    (should (equal (lispm-browser-extensions-event-anchor event)
                   (list (window-frame window) (+ (nth 0 edges) 120) (+ (nth 1 edges) 2) 28 22)))))

(ert-deftest lispm-browser-test-extensions-tab-line-buttons ()
  "The tab line ends with the toolbar's buttons and the Extensions button,
flush right, each marked as the button it is."
  (let ((lispm-browser-extensions--tab-line nil)
        (buttons '((:id "a" :name "Blocker" :enabled t :badge "3"
                    :badge-color "#D93025" :badge-text-color "#FFFFFF"))))
    (cl-letf (((symbol-function 'lispm-browser-extensions-buttons) (lambda () buttons))
              ((symbol-function 'string-pixel-width) #'length))
      (let ((line (lispm-browser-extensions-tab-line-buttons)))
        (should (string-match "B3" line))
        (should (equal (get-text-property (match-beginning 0) 'lispm-browser-extensions-button line) "a"))
        (should (string-match "🧩" line))
        (should (eq (get-text-property (match-beginning 0) 'lispm-browser-extensions-button line) 'menu))
        ;; The badge keeps its colours over the tab's face.
        (should (memq 'tab-line-tab-inactive (ensure-list (get-text-property 0 'face (substring line 1)))))
        (should (equal (get-text-property 0 'display line)
                       `(space :align-to (- right (,(+ 7 lispm-browser-extensions-tab-line-margin))))))))))

(ert-deftest lispm-browser-test-extensions-button-anchors ()
  "A button is found where Emacs drew it, read from the row's right end:
its rectangle in the frame, the row's height."
  (let* ((window (selected-window))
         (edges (window-pixel-edges window)))
    (cl-letf (((symbol-function 'window-pixel-width) (lambda (&rest _) 100))
              ((symbol-function 'lispm-browser-extensions--button-at)
               (lambda (_window x y)
                 (should (= y 12))
                 (cond ((<= 80 x 89) 'menu) ((<= 60 x 79) "a") ((<= 10 x 20) "a")))))
      (should (equal (lispm-browser-extensions-button-anchor window 2 20 "a")
                     (list (window-frame window) (+ (nth 0 edges) 60) (+ (nth 1 edges) 2) 20 20)))
      (should (equal (lispm-browser-extensions-button-anchor window 2 20 'menu)
                     (list (window-frame window) (+ (nth 0 edges) 80) (+ (nth 1 edges) 2) 10 20)))
      (should-not (lispm-browser-extensions-button-anchor window 2 20 "b")))))

(ert-deftest lispm-browser-test-extensions-page-commands ()
  "What the page of extensions asks is done as the commands do: removing
asks nothing more, as the page asked; the store's button asks first."
  (let ((calls nil))
    (cl-letf (((symbol-function 'lispm-browser-webext-module-set-enabled)
               (lambda (id on) (push (list 'enabled id on) calls)))
              ((symbol-function 'lispm-browser-webext-module-remove)
               (lambda (id) (push (list 'remove id) calls)))
              ((symbol-function 'lispm-browser-extensions-remove)
               (lambda (id) (push (list 'ask-remove id) calls)))
              ((symbol-function 'lispm-browser-webext-module-set-pinned)
               (lambda (id on) (push (list 'pinned id on) calls)))
              ((symbol-function 'lispm-browser-extensions-install)
               (lambda (id) (push (list 'install id) calls)))
              ((symbol-function 'lispm-browser-open-url)
               (lambda (url new-tab) (push (list 'open url new-tab) calls)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked"))))
      (dolist (command '("enable" "disable" "remove" "ask-remove" "pin" "unpin" "install" "store-page"))
        (lispm-browser-extensions--command (list :command command :id "abc")))
      (should (equal (reverse calls)
                     `((enabled "abc" t) (enabled "abc" nil) (remove "abc") (ask-remove "abc")
                       (pinned "abc" t) (pinned "abc" nil) (install "abc")
                       (open ,(concat (string-remove-suffix "/" lispm-browser-extensions-store-url)
                                      "/detail/abc")
                             t))))
      ;; An error is told, not raised from a timer.
      (cl-letf (((symbol-function 'lispm-browser-extensions-reload) (lambda (_) (user-error "Gone")))
                ((symbol-function 'message) (lambda (&rest args) (push (apply #'format args) calls))))
        (lispm-browser-extensions--command '(:command "reload" :id "abc"))
        (should (equal (car calls) "Gone"))))))

(ert-deftest lispm-browser-test-extensions-page-opens-once ()
  "The page of extensions opens in a new tab, or the tab showing it is
shown again, at an extension's details when asked."
  (let ((opened nil)
        (shown nil)
        (went nil)
        (tabs nil))
    (cl-letf (((symbol-function 'lispm-browser-extensions--ensure) #'funcall)
              ((symbol-function 'lispm-browser-tabs) (lambda () tabs))
              ((symbol-function 'lispm-browser-uri) (lambda (buffer) (and (eq buffer 'page) "lispm://extensions/")))
              ((symbol-function 'lispm-browser-open-url)
               (lambda (url new-tab) (push (list url new-tab) opened)))
              ((symbol-function 'lispm-browser-window) #'always)
              ((symbol-function 'lispm-browser-select-tab) (lambda (tab) (push tab shown)))
              ((symbol-function 'xwidget-at) #'ignore)
              ((symbol-function 'xwidget-webkit-goto-uri) (lambda (_ url) (push url went)))
              (lispm-browser-raise-function #'ignore))
      (lispm-browser-extensions)
      (should (equal opened '(("lispm://extensions/" t))))
      (setq tabs '(other page) opened nil)
      (lispm-browser-extensions)
      (should-not opened)
      (should (equal shown '(page))))))

(ert-deftest lispm-browser-test-extensions-store-opens-a-tab ()
  "The Chrome Web Store opens in a new tab, asking nothing."
  (let ((opened nil)
        (lispm-browser-extensions-store-url "https://store.example/"))
    (cl-letf (((symbol-function 'lispm-browser-open-url)
               (lambda (url &optional new-tab) (push (list url new-tab) opened)))
              ((symbol-function 'read-string)
               (lambda (&rest _) (error "Asked for input"))))
      (lispm-browser-extensions-store)
      (should (equal opened '(("https://store.example/" t)))))))

(provide 'lispm-browser-test)
;;; lispm-browser-test.el ends here
