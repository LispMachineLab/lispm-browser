;;; lispm-browser-extensions.el --- Chrome extensions in the browser  -*- lexical-binding: t; -*-

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

;; Chrome extensions in the browser's pages, on macOS 15.4 and later.
;; WebKit runs them itself (WKWebExtension, the engine Safari's extensions
;; run on) in every page view whose configuration carries its controller.
;; Emacs makes its page views itself, so the module lispm-browser-webext
;; (Swift, in native/lispm-browser-webext) hands each one the controller as
;; it is made, and hosts the extensions: the browser's pages are their tabs,
;; their popups hang from their buttons, and their questions are asked
;; here.  Most of the module is ported from Search, a WebKit browser for
;; macOS, with the script Search puts in every extension to fill in the
;; Chrome APIs WebKit lacks, so that heavy ones such as the Rabby wallet run;
;; a window an extension opens of its own is a Mac window.
;;
;; They are used as in Chrome:
;;
;;   toolbar        a button per pinned extension, its icon and badge, then
;;                  the Extensions button, a puzzle piece, with the menu of
;;                  them all: press one, pin it, manage them
;;   a button       its popup hangs under it, or it is told it was clicked
;;   lispm://extensions   the page of them, in a tab: turn one on or off,
;;                  see what it may do, reload it, remove it, add one
;;   the store      "Add to LispM" on an extension's Chrome Web Store page:
;;                  fetched, signature checked, asked, loaded
;;
;; and from the keyboard: M-e presses a button, and every action is a
;; command.  The browser's tab line shows the toolbar's buttons at its right
;; end; a program drawing the browser otherwise, as LispM Desktop draws
;; Netscape's window, draws them from `lispm-browser-extensions-buttons' and
;; `lispm-browser-extensions-menu-items', presses them with
;; `lispm-browser-extensions-press', says where they are through
;; `lispm-browser-extensions-anchor-function', and redraws them on
;; `lispm-browser-extensions-changed-hook'.
;;
;; The module is built with Swift (`lispm-browser-extensions-build') the
;; first time an extension is added, and again at a start that finds its
;; sources changed.  Pages made before it is loaded run no extensions.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'url-util)
(require 'lispm-browser)

(declare-function xwidget-at "xwidget" (pos))
(declare-function xwidget-buffer "xwidget.c" (xwidget))
(declare-function lispm-browser-webext-module-start "lispm-browser-webext-module" (directory))
(declare-function lispm-browser-webext-module-stop "lispm-browser-webext-module" ())
(declare-function lispm-browser-webext-module-list "lispm-browser-webext-module" ())
(declare-function lispm-browser-webext-module-install-store "lispm-browser-webext-module" (text))
(declare-function lispm-browser-webext-module-install-folder "lispm-browser-webext-module" (path))
(declare-function lispm-browser-webext-module-reload "lispm-browser-webext-module" (id))
(declare-function lispm-browser-webext-module-remove "lispm-browser-webext-module" (id))
(declare-function lispm-browser-webext-module-set-enabled "lispm-browser-webext-module" (id enabled))
(declare-function lispm-browser-webext-module-action "lispm-browser-webext-module" (id))
(declare-function lispm-browser-webext-module-press "lispm-browser-webext-module" (id anchor))
(declare-function lispm-browser-webext-module-set-pinned "lispm-browser-webext-module" (id pinned))
(declare-function lispm-browser-webext-module-options-url "lispm-browser-webext-module" (id))
(declare-function lispm-browser-webext-module-expect-page "lispm-browser-webext-module" (url))
(declare-function lispm-browser-webext-module-activate "lispm-browser-webext-module" (address))
(declare-function lispm-browser-webext-module-answer "lispm-browser-webext-module" (id value))
(defvar xwidget-list)

(defgroup lispm-browser-extensions nil
  "Chrome extensions in the browser's pages."
  :group 'lispm-browser)

(defcustom lispm-browser-extensions-enabled t
  "Whether the browser's pages run Chrome extensions where Emacs can: on
macOS 15.4 and later, in an Emacs built with xwidgets.  Takes effect at
the next start."
  :type 'boolean
  :group 'lispm-browser-extensions)

(defcustom lispm-browser-extensions-directory
  (locate-user-emacs-file "lispm-browser-extensions/")
  "Directory the extensions are kept in, each unpacked in a folder named
by its id, beside the list of them, installed.json."
  :type 'directory
  :group 'lispm-browser-extensions)

(defcustom lispm-browser-extensions-store-url "https://chromewebstore.google.com/"
  "Address of the Chrome Web Store, which `lispm-browser-extensions-store' opens."
  :type 'string
  :group 'lispm-browser-extensions)

(defconst lispm-browser-extensions-page-url "lispm://extensions/"
  "Address of the browser's page of extensions, which the module serves.")

(defcustom lispm-browser-extensions-icon-size 16
  "Size in pixels of an extension's icon on its button, as Chrome's 16.
The module hands icons twice as large, sharp on a Retina screen."
  :type 'natnum
  :group 'lispm-browser-extensions)

(defconst lispm-browser-extensions-source-directory
  (expand-file-name "native/lispm-browser-webext"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory (or load-file-name buffer-file-name)))))
  "Directory of the module's Swift package.")

(defvar lispm-browser-extensions-changed-hook nil
  "Hook run when the extensions, their buttons or their badges change: an
icon, a badge, a pin, a popup opening or closing.  What draws the buttons
redraws them.")

;;;; Where they can run

(defvar lispm-browser-extensions--macos-version nil
  "The version of macOS, once read.")

(defun lispm-browser-extensions--macos-version ()
  "Return the version of macOS this Emacs runs on, as a string, or nil."
  (or lispm-browser-extensions--macos-version
      (setq lispm-browser-extensions--macos-version
            (car (ignore-errors (process-lines "sw_vers" "-productVersion"))))))

(defun lispm-browser-extensions-supported-p ()
  "Return non-nil when pages can run Chrome extensions here: in the Mac
build of Emacs, built with xwidgets, on macOS 15.4 or later."
  (and (eq system-type 'darwin)
       (featurep 'ns)
       (featurep 'xwidget-internal)
       (when-let* ((version (lispm-browser-extensions--macos-version)))
         (version<= "15.4" version))))

;;;; The module

(defun lispm-browser-extensions--module-file ()
  "Return the built library of the module, or nil."
  (let ((file (expand-file-name ".build/release/liblispm_browser_webext.dylib"
                                lispm-browser-extensions-source-directory)))
    (and (file-exists-p file) file)))

(defun lispm-browser-extensions--stale-p ()
  "Return non-nil when a source of the module is newer than its library,
as after an update."
  (when-let* ((library (lispm-browser-extensions--module-file)))
    (let ((source lispm-browser-extensions-source-directory))
      (seq-some (lambda (file) (file-newer-than-file-p file library))
                (append (mapcar (lambda (name) (expand-file-name name source))
                                '("Package.swift" "Package.resolved"))
                        (directory-files-recursively (expand-file-name "Sources" source)
                                                     "\\.swift\\'"))))))

(defvar lispm-browser-extensions--building nil
  "The Swift process building the module, while it runs.")

(defvar lispm-browser-extensions--after-build nil
  "Functions to call once the module being built is built.")

(defun lispm-browser-extensions-build (&optional callback)
  "Build the module with Swift in the background, then call CALLBACK.
Its output is in the *lispm-browser-webext build* buffer."
  (interactive)
  (unless (executable-find "swift")
    (user-error "Building lispm-browser-webext needs Swift: install Xcode or its command line tools"))
  (when callback
    (push callback lispm-browser-extensions--after-build))
  (unless (process-live-p lispm-browser-extensions--building)
    (let ((default-directory (file-name-as-directory lispm-browser-extensions-source-directory))
          (buffer (get-buffer-create "*lispm-browser-webext build*")))
      (with-current-buffer buffer (erase-buffer))
      (message "Building lispm-browser-webext, the browser's extension host…")
      (setq lispm-browser-extensions--building
            (make-process
             :name "lispm-browser-webext build" :buffer buffer :noquery t
             :command '("swift" "build" "-c" "release" "--product" "lispm_browser_webext")
             :sentinel #'lispm-browser-extensions--built)))))

(defun lispm-browser-extensions--built (process _event)
  "Report how the module's build PROCESS went, and call what waited for it."
  (unless (process-live-p process)
    (let ((waiting (reverse lispm-browser-extensions--after-build)))
      (setq lispm-browser-extensions--after-build nil)
      (if (and (= (process-exit-status process) 0) (lispm-browser-extensions--module-file))
          (progn
            ;; Swift leaves a library it found current untouched.
            (set-file-times (lispm-browser-extensions--module-file))
            (if (featurep 'lispm-browser-webext-module)
                (message "lispm-browser-webext is rebuilt: restart Emacs to use it")
              (message "lispm-browser-webext is built"))
            (mapc #'funcall waiting))
        (message "lispm-browser-webext could not be built: see *lispm-browser-webext build*")))))

(defvar lispm-browser-extensions--started nil
  "Non-nil once the module's extension host runs.")

(defun lispm-browser-extensions--start ()
  "Load the module and start its extension host when it is built; return
non-nil once it runs.  Pages already open run no extensions."
  (or lispm-browser-extensions--started
      (when-let* (((lispm-browser-extensions-supported-p))
                  ((fboundp 'module-load))
                  ((not (process-live-p lispm-browser-extensions--building)))
                  (file (lispm-browser-extensions--module-file)))
        (unless (featurep 'lispm-browser-webext-module)
          (module-load file))
        (make-directory lispm-browser-extensions-directory t)
        (lispm-browser-webext-module-start (expand-file-name lispm-browser-extensions-directory))
        (add-hook 'kill-emacs-hook #'lispm-browser-extensions--stop)
        (when (bound-and-true-p xwidget-list)
          (message "Extensions run in the pages opened from now on"))
        (setq lispm-browser-extensions--started t))))

(defun lispm-browser-extensions--stop ()
  "Stop the module calling Emacs back, as Emacs exits and closes its pipe."
  (when (fboundp 'lispm-browser-webext-module-stop)
    (lispm-browser-webext-module-stop)))

(defun lispm-browser-extensions--ensure (then)
  "Call THEN once the extension host runs, the module built first if need be."
  (cond ((not (lispm-browser-extensions-supported-p))
         (user-error "Chrome extensions need the Mac build of Emacs with xwidgets, on macOS 15.4 or later"))
        ((lispm-browser-extensions--start) (funcall then))
        (t (lispm-browser-extensions-build
            (lambda () (when (lispm-browser-extensions--start) (funcall then)))))))

;;;; Pages, as the module knows them

(defun lispm-browser-extensions--address-in (printed)
  "Return the view address in PRINTED, an xwidget as `prin1' writes it."
  (when (string-match "\\`#<xwidget [0-9]+ 0x\\([[:xdigit:]]+\\)>\\'" printed)
    (string-to-number (match-string 1 printed) 16)))

(defun lispm-browser-extensions--address (xwidget)
  "Return the address of XWIDGET's WebKit view, the module's name for its page.
Emacs on macOS prints an xwidget with that address."
  (and xwidget (lispm-browser-extensions--address-in (prin1-to-string xwidget))))

(defun lispm-browser-extensions--buffer (address)
  "Return the buffer of the page whose view is at ADDRESS, or nil."
  (seq-some (lambda (xwidget)
              (and (eql (lispm-browser-extensions--address xwidget) address)
                   (buffer-live-p (xwidget-buffer xwidget))
                   (xwidget-buffer xwidget)))
            (bound-and-true-p xwidget-list)))

(defun lispm-browser-extensions--front-buffer ()
  "Return the page in front: the selected window's, or else the browser's."
  (let ((selected (window-buffer (selected-window))))
    (if (eq (buffer-local-value 'major-mode selected) 'xwidget-webkit-mode)
        selected
      (lispm-browser-shown-buffer))))

(defun lispm-browser-extensions--follow (&rest _)
  "Tell the extensions which page is in front.  The module tells WebKit only
when it changed."
  (when-let* ((lispm-browser-extensions--started)
              (buffer (lispm-browser-extensions--front-buffer))
              ((buffer-live-p buffer))
              (xwidget (with-current-buffer buffer (xwidget-at (point-min))))
              (address (lispm-browser-extensions--address xwidget)))
    (lispm-browser-webext-module-activate address)))

;;;; What the module says

(defvar lispm-browser-extensions--installed 'unread
  "The installed extensions as the module last listed them, plists, or
`unread' until they are listed again.")

(defun lispm-browser-extensions--parse (json)
  "Return JSON parsed, objects as plists and arrays as lists."
  (json-parse-string json :object-type 'plist :array-type 'list
                     :null-object nil :false-object nil))

(defun lispm-browser-extensions-installed ()
  "Return the installed extensions, each a plist: :id, :name, :version,
:description, :enabled, :loaded, :fromStore, :source, :pinned, :popupShown,
and, while it runs, :label, :badge, :badgeColor, :badgeTextColor,
:actionEnabled, :popup and :icon (PNG in base64) of its button for the page
in front, :options and :errors."
  (when (eq lispm-browser-extensions--installed 'unread)
    (setq lispm-browser-extensions--installed
          (and lispm-browser-extensions--started
               (lispm-browser-extensions--parse (lispm-browser-webext-module-list)))))
  lispm-browser-extensions--installed)

(defun lispm-browser-webext--event (kind json)
  "Handle event KIND of the module, JSON its payload.
The module calls this from its channel's process filter, so whatever waits
for the user, or opens and closes pages, runs after it returns."
  (let ((payload (lispm-browser-extensions--parse json)))
    (pcase kind
      ("message" (message "%s" payload))
      ("changed" (lispm-browser-extensions--changed))
      ("ask" (run-at-time 0 nil #'lispm-browser-extensions--ask payload))
      ("open" (run-at-time 0 nil #'lispm-browser-extensions--open payload))
      ("close" (run-at-time 0 nil #'lispm-browser-extensions--close payload))
      ("activate" (run-at-time 0 nil #'lispm-browser-extensions--activate payload))
      ("command" (run-at-time 0 nil #'lispm-browser-extensions--command payload))
      ("search" (run-at-time 0 nil #'lispm-browser-extensions--search payload)))))

(defun lispm-browser-extensions--changed ()
  "Forget the list, and redraw what shows it.  An extension popped out on
the toolbar goes back once its popup is down."
  (setq lispm-browser-extensions--installed 'unread)
  (lispm-browser-extensions--settle-popped-out)
  (when-let* ((buffer (get-buffer "*Browser Extensions*")))
    (with-current-buffer buffer (revert-buffer)))
  (run-hooks 'lispm-browser-extensions-changed-hook))

(defun lispm-browser-extensions--question (payload)
  "Return the question PAYLOAD asks, its details below it, for a prompt."
  (concat (plist-get payload :question) "\n"
          (mapconcat (lambda (line) (concat "  • " line)) (plist-get payload :details) "\n")
          "\n"))

(defun lispm-browser-extensions--ask (payload)
  "Ask the question in PAYLOAD and answer the module, no when quit."
  (let (yes)
    (unwind-protect
        (setq yes (yes-or-no-p (lispm-browser-extensions--question payload)))
      (lispm-browser-webext-module-answer (plist-get payload :request) (and yes 1)))))

(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))

(defun lispm-browser-extensions--open-tab (url active)
  "Open URL in a new browser tab, in front when ACTIVE; return the address of
its view.  A running extension's page is shown by a view made for it."
  (unless (or (not active) (lispm-browser-window))
    (lispm-browser-show))
  (let* ((own (lispm-browser-webext-module-expect-page url))
         ;; `xwidget-webkit-browse-url' takes an address whose scheme has a
         ;; hyphen, chrome-extension:, for a bare host and puts https://
         ;; before it; the tab opens blank and is then sent there.
         (first (if own "about:blank" url)))
    (if active
        (lispm-browser-new-tab first)
      (save-window-excursion (lispm-browser-new-tab first)))
    ;; Emacs puts the newest xwidget first.
    (let ((xwidget (car (bound-and-true-p xwidget-list))))
      (when own (xwidget-webkit-goto-uri xwidget url))
      (lispm-browser-extensions--address xwidget))))

(defun lispm-browser-extensions--open (payload)
  "Open the page in PAYLOAD in a new tab; answer with its view when asked."
  (let ((request (plist-get payload :request))
        address)
    (unwind-protect
        (setq address (lispm-browser-extensions--open-tab
                       (plist-get payload :url) (plist-get payload :active)))
      (when request
        (lispm-browser-webext-module-answer request address)))))

(defun lispm-browser-extensions--close (payload)
  "Close the tab of the page whose view PAYLOAD names."
  (when-let* ((buffer (lispm-browser-extensions--buffer (plist-get payload :view))))
    (lispm-browser-close-tab buffer)))


(defun lispm-browser-extensions--search (payload)
  "Search for the words in PAYLOAD with the browser's search engine, in a
new tab when it asks for one (chrome.search.query)."
  (let ((text (plist-get payload :text)))
    (unless (string-empty-p (or text ""))
      (lispm-browser-open-url
       (format lispm-browser-search-url (url-hexify-string text))
       (plist-get payload :newTab)))))

(defun lispm-browser-extensions--activate (payload)
  "Bring the tab of the page whose view PAYLOAD names in front."
  (when-let* ((buffer (lispm-browser-extensions--buffer (plist-get payload :view))))
    (unless (lispm-browser-window)
      (lispm-browser-show))
    (lispm-browser-select-tab buffer)))

;;;; Commands

(defun lispm-browser-extensions--store-id (url)
  "Return the extension id of URL when it is a Chrome Web Store page, else nil."
  (when (and url (string-match (concat "\\`https://\\(?:chromewebstore\\.google\\.com/detail"
                                       "\\|chrome\\.google\\.com/webstore/detail\\)"
                                       "/\\(?:[^/?#]+/\\)?\\([a-p]\\{32\\}\\)\\(?:[/?#]\\|\\'\\)")
                               url))
    (match-string 1 url)))

(defun lispm-browser-extensions--shown-store-id ()
  "Return the id of the extension whose Chrome Web Store page the browser shows."
  (lispm-browser-extensions--store-id (ignore-errors (lispm-browser-uri))))

(defun lispm-browser-extensions--label (extension)
  "Return EXTENSION's name, with its button's badge when it shows one."
  (let ((badge (plist-get extension :badge)))
    (if (and badge (not (string-empty-p badge)))
        (format "%s [%s]" (plist-get extension :name) badge)
      (plist-get extension :name))))

(defun lispm-browser-extensions--read (prompt &optional predicate)
  "Read an installed extension with PROMPT, among those PREDICATE accepts;
return its id.  In the list of extensions, it is the one at point."
  (if-let* (((derived-mode-p 'lispm-browser-extensions-mode))
            (id (tabulated-list-get-id)))
      id
    (lispm-browser-extensions--choose prompt predicate)))

(defun lispm-browser-extensions--choose (prompt predicate)
  "Read an installed extension with PROMPT, among those PREDICATE accepts."
  (let* ((extensions (seq-filter (or predicate #'identity) (lispm-browser-extensions-installed)))
         (choices (mapcar (lambda (extension)
                            (cons (format "%s %s" (plist-get extension :name) (plist-get extension :version))
                                  (plist-get extension :id)))
                          extensions)))
    (unless choices (user-error "No extension to choose from"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

;;;###autoload
(defun lispm-browser-extensions-store ()
  "Open the Chrome Web Store in a new tab.  On an extension's page there,
Add to LispM, where the store's own button stood, or
\\[lispm-browser-extensions-install-shown], adds it: the store's button
is Chrome's, and works in Chrome alone."
  (interactive)
  (lispm-browser-open-url lispm-browser-extensions-store-url t)
  (message "%s" (substitute-command-keys
                 "On an extension's page, Add to LispM adds it")))

(defun lispm-browser-extensions-install (text)
  "Add the Chrome extension TEXT names, its Chrome Web Store link or id.
It is fetched from the store and its signature checked, then you are asked,
with what it will be able to do.  The page shown is the default when it
is a store page."
  (interactive
   (let ((shown (lispm-browser-extensions--shown-store-id)))
     (list (read-string (format-prompt "Add from the Chrome Web Store (link or id)" shown)
                        nil nil shown))))
  (lispm-browser-extensions--ensure
   (lambda () (lispm-browser-webext-module-install-store text))))

(defun lispm-browser-extensions-install-shown ()
  "Add the extension whose Chrome Web Store page the browser shows."
  (interactive)
  (if-let* ((id (lispm-browser-extensions--shown-store-id)))
      (lispm-browser-extensions-install id)
    (user-error "The page shown is no Chrome Web Store extension")))

;;;###autoload
(defun lispm-browser-extensions-load-unpacked (directory)
  "Add the unpacked extension in DIRECTORY, a copy of it, as Chrome's
developer mode does; `lispm-browser-extensions-reload' takes its
changes."
  (interactive "DLoad the extension in folder: ")
  (lispm-browser-extensions--ensure
   (lambda () (lispm-browser-webext-module-install-folder (expand-file-name directory)))))

(defun lispm-browser-extensions--running-p (extension)
  "Return non-nil when EXTENSION is on and runs."
  (plist-get extension :loaded))

;;;; Its button

(defun lispm-browser-extensions--find (id)
  "Return the installed extension ID, or nil."
  (seq-find (lambda (extension) (equal (plist-get extension :id) id))
            (lispm-browser-extensions-installed)))

(defvar lispm-browser-extensions--popped-out nil
  "The unpinned extension whose button the toolbar shows while its popup
is up, beside the Extensions button, as Chrome pops it out; or nil.")

(defun lispm-browser-extensions--settle-popped-out ()
  "Take the popped-out button off the toolbar once its popup is down."
  (when-let* ((id lispm-browser-extensions--popped-out))
    (unless (plist-get (lispm-browser-extensions--find id) :popupShown)
      (setq lispm-browser-extensions--popped-out nil))))

(defvar lispm-browser-extensions-anchor-function #'lispm-browser-extensions--tab-line-anchor
  "Function telling where an extension's button is, for its popup to hang
from when it is pressed from the keyboard or a menu.  It is called with
the extension's id, or `menu' for the Extensions button, and returns an
anchor, (FRAME X Y WIDTH HEIGHT): the button's rectangle in pixels from
FRAME's top left, as `window-pixel-edges' counts them; or nil, for the
popup to hang from the page's top right.  The browser's tab line is the
default; a program drawing the buttons elsewhere sets its own.")

(defun lispm-browser-extensions-event-anchor (event)
  "Return the anchor of what mouse EVENT clicked: the rectangle, in its
frame, of the image or string it was on, see
`lispm-browser-extensions-anchor-function'.  Nil when it names no window."
  (let* ((posn (event-start event))
         (window (posn-window posn)))
    (when (window-live-p window)
      (pcase-let* ((`(,x . ,y) (posn-x-y posn))
                   (`(,dx . ,dy) (or (posn-object-x-y posn) '(0 . 0)))
                   (`(,width . ,height) (or (posn-object-width-height posn) '(0 . 0)))
                   (`(,left . ,top) (lispm-browser-extensions--posn-origin posn)))
        (list (window-frame window) (+ left (- x dx)) (+ top (- y dy)) width height)))))

(defun lispm-browser-extensions--posn-origin (posn)
  "Return where POSN's x and y count from, in pixels of its frame: the
window's text area for a click in it, else the window's top left past a
scroll bar on the left, as Emacs counts a click in a mode, header or tab
line."
  (let ((window (posn-window posn)))
    (if (null (posn-area posn))
        (pcase-let ((`(,left ,top . ,_) (window-inside-pixel-edges window)))
          (cons left top))
      (pcase-let ((`(,left ,top . ,_) (window-pixel-edges window)))
        (cons (+ left (if (eq (window-current-scroll-bars window) 'left)
                          (window-scroll-bar-width window)
                        0))
              top)))))

(defun lispm-browser-extensions--frame-view (frame)
  "Return the address of a page view FRAME shows, the browser's first."
  (seq-some (lambda (window)
              (and window (eq (window-frame window) frame)
                   (lispm-browser--page-window-p window)
                   (lispm-browser-extensions--address
                    (with-current-buffer (window-buffer window) (xwidget-at (point-min))))))
            (cons (lispm-browser-window) (window-list frame 'no-mini))))

(defun lispm-browser-extensions--button-at (window x y)
  "Return the `lispm-browser-extensions-button' of what WINDOW shows X and Y
pixels from its top left: in a tab, header or mode line, an overlay's
string or the buffer's text."
  (let* ((posn (posn-at-x-y x y window t))
         (string (posn-string posn))
         (point (posn-point posn)))
    (cond ((and (consp string) (stringp (car string)) (natnump (cdr string))
                (< (cdr string) (length (car string))))
           (get-text-property (cdr string) 'lispm-browser-extensions-button (car string)))
          ((and (null (posn-area posn)) (integerp point))
           (with-current-buffer (window-buffer window)
             (and (<= (point-min) point) (< point (point-max))
                  (get-char-property point 'lispm-browser-extensions-button)))))))

(defun lispm-browser-extensions-button-anchor (window top height id)
  "Return the anchor of the button of ID, or `menu' for the Extensions
button, drawn on the row of WINDOW that starts TOP pixels from its top
and is HEIGHT pixels high: the text with the property
`lispm-browser-extensions-button' ID, found where Emacs drew it.  The
row is read from its right end, where toolbars keep their buttons.  Nil
when the button is not there."
  (when (window-live-p window)
    (let ((y (+ top (/ height 2)))
          (x (1- (window-pixel-width window)))
          right left)
      (while (>= x 0)
        (if (equal (lispm-browser-extensions--button-at window x y) id)
            (setq right (or right x) left x x (1- x))
          ;; Past the button's left end, it is found.
          (setq x (if right -1 (1- x)))))
      (when right
        (pcase-let ((`(,window-left ,window-top . ,_) (window-pixel-edges window)))
          (list (window-frame window) (+ window-left left) (+ window-top top)
                (1+ (- right left)) height))))))

(defun lispm-browser-extensions--anchor-json (anchor)
  "Return ANCHOR as the module takes it, JSON naming a page view of its
frame, or nil when the frame shows no page."
  (pcase-let ((`(,frame ,x ,y ,width ,height) anchor))
    (when-let* (((frame-live-p frame))
                (view (lispm-browser-extensions--frame-view frame)))
      (json-encode `((view . ,view) (x . ,x) (y . ,y) (width . ,width) (height . ,height))))))

;;;###autoload
(defun lispm-browser-extensions-press (id &optional anchor)
  "Press the button of extension ID for the page in front: its popup opens
under the button, or it is told it was clicked.  Pressing the button of
the popup that is up closes it.  ANCHOR says where the button is, see
`lispm-browser-extensions-anchor-function', which is asked when it is
nil.  The button of an extension not pinned to the toolbar shows there
while its popup is up.  Interactively, asks which one, badges shown."
  (interactive
   (progn (unless lispm-browser-extensions--started
            (user-error "No extension runs: add one with M-x lispm-browser-extensions-install"))
          (list (lispm-browser-extensions--read
                 "Press the button of: " #'lispm-browser-extensions--running-p))))
  (lispm-browser-extensions--follow)
  (let ((extension (lispm-browser-extensions--find id)))
    (unless (or anchor (plist-get extension :pinned) (plist-get extension :popupShown))
      (setq lispm-browser-extensions--popped-out id)
      (run-hooks 'lispm-browser-extensions-changed-hook))
    (let* ((anchor (or anchor (and lispm-browser-extensions-anchor-function
                                   (funcall lispm-browser-extensions-anchor-function id))))
           (json (and anchor (lispm-browser-extensions--anchor-json anchor)))
           (pressed (if (fboundp 'lispm-browser-webext-module-press)
                        (lispm-browser-webext-module-press id json)
                      (lispm-browser-webext-module-action id))))
      ;; One without a popup was only told it was clicked.
      (setq lispm-browser-extensions--installed 'unread)
      (lispm-browser-extensions--settle-popped-out)
      (unless pressed
        (user-error "That extension has no button")))))

(defun lispm-browser-extensions-pin (id &optional unpin)
  "Pin extension ID's button to the toolbar, or with UNPIN take it off:
it is then in the Extensions menu alone.  Interactively, UNPIN is the
prefix argument."
  (interactive (list (lispm-browser-extensions--read
                      (if current-prefix-arg "Unpin from the toolbar: " "Pin to the toolbar: ")
                      (if current-prefix-arg
                          (lambda (extension) (plist-get extension :pinned))
                        (lambda (extension) (not (plist-get extension :pinned)))))
                     current-prefix-arg))
  (lispm-browser-webext-module-set-pinned id (not unpin)))

(defun lispm-browser-extensions-unpin (id)
  "Take extension ID's button off the toolbar, see `lispm-browser-extensions-pin'."
  (interactive (list (lispm-browser-extensions--read
                      "Unpin from the toolbar: " (lambda (extension) (plist-get extension :pinned)))))
  (lispm-browser-extensions-pin id t))

(defun lispm-browser-extensions-toggle-pin (id)
  "Pin extension ID's button to the toolbar when it is not, else unpin it."
  (interactive (list (lispm-browser-extensions--read "Pin or unpin: ")))
  (lispm-browser-extensions-pin id (plist-get (lispm-browser-extensions--find id) :pinned)))

(defun lispm-browser-extensions-options (id)
  "Open the options page of extension ID in a new tab."
  (interactive (list (lispm-browser-extensions--read
                      "Options of: " (lambda (extension) (plist-get extension :options)))))
  (if-let* ((url (lispm-browser-webext-module-options-url id)))
      (lispm-browser-extensions--open-tab url t)
    (user-error "That extension has no options page")))

(defun lispm-browser-extensions-reload (id)
  "Load extension ID again, copied afresh from its folder if it came from one."
  (interactive (list (lispm-browser-extensions--read "Reload: ")))
  (lispm-browser-webext-module-reload id))

(defun lispm-browser-extensions-toggle (id)
  "Turn extension ID off when it is on, else on."
  (interactive (list (lispm-browser-extensions--read "Turn on or off: ")))
  (let ((extension (seq-find (lambda (extension) (equal (plist-get extension :id) id))
                             (lispm-browser-extensions-installed))))
    (lispm-browser-webext-module-set-enabled id (not (plist-get extension :enabled)))))

(defun lispm-browser-extensions-remove (id)
  "Remove extension ID and what it kept, once you say yes."
  (interactive (list (lispm-browser-extensions--read "Remove: ")))
  (let ((extension (seq-find (lambda (extension) (equal (plist-get extension :id) id))
                             (lispm-browser-extensions-installed))))
    (when (yes-or-no-p (format "Remove “%s” and what it kept? " (plist-get extension :name)))
      (lispm-browser-webext-module-remove id))))

;;;; The list of them

(defun lispm-browser-extensions--entries ()
  "Return the rows of the extension list."
  (mapcar (lambda (extension)
            (list (plist-get extension :id)
                  (vector (plist-get extension :name)
                          (plist-get extension :version)
                          (cond ((plist-get extension :loaded) "on")
                                ((plist-get extension :enabled) "failed")
                                (t "off"))
                          (if (plist-get extension :pinned) "yes" "")
                          (or (plist-get extension :badge) "")
                          (if (plist-get extension :fromStore) "Chrome Web Store"
                            (abbreviate-file-name (or (plist-get extension :source) ""))))))
          (lispm-browser-extensions-installed)))

(defvar-keymap lispm-browser-extensions-mode-map
  :doc "Keys of the extension list; those of one extension act on the line's."
  "RET" #'lispm-browser-extensions-press
  "a" #'lispm-browser-extensions-press
  "o" #'lispm-browser-extensions-options
  "e" #'lispm-browser-extensions-toggle
  "p" #'lispm-browser-extensions-toggle-pin
  "r" #'lispm-browser-extensions-reload
  "D" #'lispm-browser-extensions-remove
  "s" #'lispm-browser-extensions-store
  "i" #'lispm-browser-extensions-install
  "l" #'lispm-browser-extensions-load-unpacked
  "m" #'lispm-browser-extensions)

(define-derived-mode lispm-browser-extensions-mode tabulated-list-mode "Extensions"
  "The browser's Chrome extensions.
\\<lispm-browser-extensions-mode-map>
\\[lispm-browser-extensions-store] opens the Chrome Web Store, where
\\[lispm-browser-extensions-install-shown] adds the extension whose page is shown;
\\[lispm-browser-extensions-install] adds one by its store link or id,
\\[lispm-browser-extensions-load-unpacked] one from a folder.  On a line,
\\[lispm-browser-extensions-press] presses its button,
\\[lispm-browser-extensions-options] opens its options,
\\[lispm-browser-extensions-toggle] turns it on or off,
\\[lispm-browser-extensions-toggle-pin] pins it to the toolbar or unpins it,
\\[lispm-browser-extensions-reload] reloads it and
\\[lispm-browser-extensions-remove] removes it.  \\[lispm-browser-extensions] opens their page."
  (setq tabulated-list-format [("Name" 28 t) ("Version" 12 nil) ("State" 7 t)
                               ("Pinned" 7 t) ("Badge" 6 nil) ("From" 0 nil)]
        tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook
            (lambda () (setq tabulated-list-entries (lispm-browser-extensions--entries)))
            nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun lispm-browser-extensions-list ()
  "List the browser's Chrome extensions in a buffer, to add, press, set up
and remove them from the keyboard; `lispm-browser-extensions' is their page."
  (interactive)
  (lispm-browser-extensions--ensure
   (lambda ()
     (with-current-buffer (get-buffer-create "*Browser Extensions*")
       (lispm-browser-extensions-mode)
       (setq tabulated-list-entries (lispm-browser-extensions--entries))
       (tabulated-list-print)
       (pop-to-buffer (current-buffer))))))

;;;; The page of them

(defun lispm-browser-extensions--page-p (buffer)
  "Return non-nil when tab BUFFER shows the page of extensions."
  (string-prefix-p "lispm://extensions" (or (ignore-errors (lispm-browser-uri buffer)) "")))

;;;###autoload
(defun lispm-browser-extensions (&optional id)
  "Open the browser's page of extensions, lispm://extensions, as Chrome's
chrome://extensions: a card for each, to turn it on and off, see what it
may do, reload or remove it, and the ways to add one.  The tab showing it
already is shown again.  ID opens that extension's details."
  (interactive)
  (lispm-browser-extensions--ensure
   (lambda ()
     (let ((url (if id (concat lispm-browser-extensions-page-url "?id=" (url-hexify-string id))
                  lispm-browser-extensions-page-url))
           (tab (seq-find #'lispm-browser-extensions--page-p (lispm-browser-tabs))))
       (if (not tab)
           (lispm-browser-open-url url t)
         (unless (lispm-browser-window)
           (lispm-browser-show))
         (lispm-browser-select-tab tab)
         (when id
           (xwidget-webkit-goto-uri (with-current-buffer tab (xwidget-at (point-min))) url))
         (funcall lispm-browser-raise-function))))))

(defun lispm-browser-extensions--command (payload)
  "Do what the page of extensions or the store's button asked in PAYLOAD,
its :command and the :id of its extension, as the commands do.  The page
asked before it removes one; the store's button asks here."
  (let ((id (plist-get payload :id)))
    (condition-case error
        (pcase (plist-get payload :command)
          ("enable" (lispm-browser-webext-module-set-enabled id t))
          ("disable" (lispm-browser-webext-module-set-enabled id nil))
          ("remove" (lispm-browser-webext-module-remove id))
          ("ask-remove" (lispm-browser-extensions-remove id))
          ("reload" (lispm-browser-extensions-reload id))
          ("options" (lispm-browser-extensions-options id))
          ("pin" (lispm-browser-extensions-pin id))
          ("unpin" (lispm-browser-extensions-pin id t))
          ("press" (lispm-browser-extensions-press id))
          ("install" (lispm-browser-extensions-install id))
          ("store" (lispm-browser-extensions-store))
          ("store-page" (lispm-browser-open-url
                         (concat (string-remove-suffix "/" lispm-browser-extensions-store-url)
                                 "/detail/" id)
                         t))
          ("load-unpacked" (call-interactively #'lispm-browser-extensions-load-unpacked)))
      (error (message "%s" (error-message-string error))))))

;;;; The toolbar's buttons

(defvar lispm-browser-extensions--images (make-hash-table :test #'equal)
  "Icons made into images, by their PNG in base64.")

(defun lispm-browser-extensions-icon (extension)
  "Return EXTENSION's button icon for the page in front as an image, or nil.
It is `lispm-browser-extensions-icon-size' pixels square; its `:data' is
the PNG the module drew, twice as large."
  (when-let* ((data (plist-get extension :icon))
              ((stringp data)))
    (or (gethash data lispm-browser-extensions--images)
        (when-let* ((png (ignore-errors (base64-decode-string data)))
                    (image (ignore-errors
                             (create-image png 'png t
                                           :width lispm-browser-extensions-icon-size
                                           :height lispm-browser-extensions-icon-size
                                           :ascent 'center))))
          (when (> (hash-table-count lispm-browser-extensions--images) 128)
            (clrhash lispm-browser-extensions--images))
          (puthash data image lispm-browser-extensions--images)))))

(defun lispm-browser-extensions--badge (extension)
  "Return EXTENSION's badge text, or nil when it shows none."
  (let ((badge (plist-get extension :badge)))
    (and (stringp badge) (not (string-empty-p badge)) badge)))

(defun lispm-browser-extensions--button (extension)
  "Return EXTENSION's toolbar button, see `lispm-browser-extensions-buttons'."
  (list :id (plist-get extension :id)
        :name (or (plist-get extension :label) (plist-get extension :name))
        :icon (lispm-browser-extensions-icon extension)
        :badge (lispm-browser-extensions--badge extension)
        :badge-color (or (plist-get extension :badgeColor) "#D93025")
        :badge-text-color (or (plist-get extension :badgeTextColor) "#FFFFFF")
        :enabled (and (plist-get extension :actionEnabled) t)
        :popup (and (plist-get extension :popup) t)
        :open (and (plist-get extension :popupShown) t)
        :pinned (and (plist-get extension :pinned) t)))

(defun lispm-browser-extensions-buttons ()
  "Return the buttons the toolbar shows, in order: each running extension
pinned to it, then the one popped out while its popup is up.  Each is a
plist: :id, :name (its button's label), :icon (an image, see
`lispm-browser-extensions-icon'), :badge (its text, or nil),
:badge-color and :badge-text-color (\"#RRGGBB\"), :enabled (whether it
does anything on the page in front), :popup (whether it has one), :open
(whether its popup is up) and :pinned."
  (when lispm-browser-extensions--started
    (let ((running (seq-filter #'lispm-browser-extensions--running-p
                               (lispm-browser-extensions-installed))))
      (mapcar #'lispm-browser-extensions--button
              (append (seq-filter (lambda (extension) (plist-get extension :pinned)) running)
                      (seq-filter (lambda (extension)
                                    (and (not (plist-get extension :pinned))
                                         (or (plist-get extension :popupShown)
                                             (equal (plist-get extension :id)
                                                    lispm-browser-extensions--popped-out))))
                                  running))))))

;;;; The Extensions menu

(defun lispm-browser-extensions-menu-items ()
  "Return the items of the Extensions menu, which the toolbar's Extensions
button and the menu bar show: each running extension, with its icon and
badge, pressing its button; Pin to Toolbar, each one checked when its
button is pinned; then the Chrome Web Store, adding and managing them.
Each item is a plist, :label, :action, and :icon, :enabled, :checked and
:submenu where they apply, or `separator'."
  (let ((running (and lispm-browser-extensions--started
                      (seq-filter #'lispm-browser-extensions--running-p
                                  (lispm-browser-extensions-installed)))))
    `(,@(mapcar (lambda (extension)
                  (let ((id (plist-get extension :id)))
                    (list :label (lispm-browser-extensions--label extension)
                          :icon (lispm-browser-extensions-icon extension)
                          :action (lambda () (lispm-browser-extensions-press id))
                          :enabled (plist-get extension :actionEnabled))))
                running)
      ,@(when running
          `(separator
            (:label "Pin to Toolbar"
                    :submenu ,(mapcar (lambda (extension)
                                        (let ((id (plist-get extension :id))
                                              (pinned (plist-get extension :pinned)))
                                          (list :label (plist-get extension :name)
                                                :icon (lispm-browser-extensions-icon extension)
                                                :checked (and pinned t)
                                                :action (lambda () (lispm-browser-extensions-pin id pinned)))))
                                      running))
            separator))
      (:label "Chrome Web Store" :action lispm-browser-extensions-store)
      (:label "Add This Extension" :action lispm-browser-extensions-install-shown
              :enabled ,(and (lispm-browser-extensions--shown-store-id) t))
      (:label "Load Unpacked…" :action lispm-browser-extensions-load-unpacked)
      separator
      (:label "Manage Extensions" :action lispm-browser-extensions))))

(define-obsolete-function-alias 'lispm-browser-extensions--menu-items
  #'lispm-browser-extensions-menu-items "0.2")

(defun lispm-browser-extensions-button-menu-items (id)
  "Return the items of the menu of extension ID's toolbar button, as Chrome
shows when one is right-clicked: its name, pinning, its options, its
details on the page of extensions, and removing it."
  (when-let* ((extension (lispm-browser-extensions--find id)))
    (let ((pinned (plist-get extension :pinned)))
      `((:label ,(plist-get extension :name) :enabled nil)
        separator
        (:label ,(if pinned "Unpin from Toolbar" "Pin to Toolbar")
                :action ,(lambda () (lispm-browser-extensions-pin id pinned)))
        (:label "Options…" :action ,(lambda () (lispm-browser-extensions-options id))
                :enabled ,(and (plist-get extension :options) t))
        (:label "Manage Extension" :action ,(lambda () (lispm-browser-extensions id)))
        separator
        (:label "Remove…" :action ,(lambda () (lispm-browser-extensions-remove id)))))))

(defun lispm-browser-extensions--menu-command (action)
  "Return a command running menu ACTION, a command or a function."
  (if (commandp action)
      action
    (lambda () (interactive) (funcall action))))

(defun lispm-browser-extensions--keymap-menu (title items)
  "Return ITEMS, as `lispm-browser-extensions-menu-items' has them, as a
menu keymap named TITLE, for Emacs's own menus."
  (let ((map (make-sparse-keymap title))
        (count 0))
    (dolist (item items)
      (let ((key (vector (intern (format "item-%d" (cl-incf count))))))
        (cond ((eq item 'separator)
               (define-key-after map key menu-bar-separator))
              ((plist-get item :submenu)
               (let ((submenu (plist-get item :submenu)))
                 (define-key-after map key
                   (cons (plist-get item :label)
                         (lispm-browser-extensions--keymap-menu
                          (plist-get item :label) (if (functionp submenu) (funcall submenu) submenu))))))
              (t
               (define-key-after map key
                 `(menu-item ,(plist-get item :label)
                             ,(lispm-browser-extensions--menu-command (or (plist-get item :action) #'ignore))
                             :enable ,(or (not (plist-member item :enabled)) (and (plist-get item :enabled) t))
                             ,@(when (plist-member item :checked)
                                 `(:button (:toggle . ,(and (plist-get item :checked) t))))))))))
    map))

(defun lispm-browser-extensions--pop-up (items where)
  "Pop up ITEMS as one of Emacs's menus at WHERE: a mouse event, or an
anchor, under which it opens."
  (popup-menu (lispm-browser-extensions--keymap-menu "Extensions" items)
              (if (eventp where)
                  where
                (pcase-let ((`(,frame ,x ,y ,_ ,height) where))
                  (list (list x (+ y height)) frame)))))

(defun lispm-browser-extensions-menu (&optional event)
  "Pop up the Extensions menu under the Extensions button, or at mouse
EVENT."
  (interactive (list (and (mouse-event-p last-nonmenu-event) last-nonmenu-event)))
  (lispm-browser-extensions--pop-up
   (lispm-browser-extensions-menu-items)
   (or event
       (and lispm-browser-extensions-anchor-function
            (funcall lispm-browser-extensions-anchor-function 'menu))
       (list (selected-frame) 0 0 0 0))))

;;;; Buttons in the tab line
;;
;; Out of the box the browser shows its toolbar's buttons at the right end
;; of each page's tab line: a button per extension, its icon and badge,
;; then the Extensions button.  Their place is known from their widths, so
;; a popup pressed from the keyboard hangs under its button too.

(defconst lispm-browser-extensions-tab-line-margin 4
  "Pixels between the tab line's buttons and its right end.")

(defvar lispm-browser-extensions--tab-line nil
  "The tab line's buttons, drawn: (BUTTONS HEIGHT STRING WIDTH), drawn
again when BUTTONS change.")

(defun lispm-browser-extensions--tab-line-keymap (press menu)
  "Return the keymap of a tab line button: PRESS runs on a click with the
event, MENU, when non-nil, on a right click."
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<tab-line> <down-mouse-1>" #'ignore)
    (keymap-set map "<tab-line> <mouse-1>" (lambda (event) (interactive "e") (funcall press event)))
    (when menu
      (keymap-set map "<tab-line> <down-mouse-3>" #'ignore)
      (keymap-set map "<tab-line> <mouse-3>" (lambda (event) (interactive "e") (funcall menu event))))
    map))

(defun lispm-browser-extensions--tab-line-button (button)
  "Return BUTTON drawn for the tab line: its icon, or its name's initial,
then its badge."
  (let* ((id (plist-get button :id))
         (icon (plist-get button :icon))
         (face (if (plist-get button :open) 'tab-line-tab-current 'tab-line-tab-inactive))
         (badge (plist-get button :badge)))
    (let ((label (concat " "
                         (if icon
                             (propertize " " 'display (if (plist-get button :enabled) icon
                                                        (append icon '(:conversion disabled))))
                           (upcase (substring (or (plist-get button :name) "?") 0 1)))
                         (if badge
                             (propertize badge 'face `(:height 0.8 :weight bold
                                                       :foreground ,(plist-get button :badge-text-color)
                                                       :background ,(plist-get button :badge-color)))
                           "")
                         " ")))
      ;; The badge keeps its colours over the tab's.
      (add-face-text-property 0 (length label) face t label)
      (propertize label
                 'lispm-browser-extensions-button id
                 'mouse-face 'tab-line-highlight 'pointer 'arrow
                 'help-echo (plist-get button :name)
                 'keymap (lispm-browser-extensions--tab-line-keymap
                          (lambda (event)
                            (lispm-browser-extensions-press id (lispm-browser-extensions-event-anchor event)))
                          (lambda (event)
                            (lispm-browser-extensions--pop-up
                             (lispm-browser-extensions-button-menu-items id) event)))))))

(defun lispm-browser-extensions--tab-line-puzzle ()
  "Return the tab line's Extensions button, a puzzle piece."
  (propertize " 🧩 " 'lispm-browser-extensions-button 'menu
              'face 'tab-line-tab-inactive 'mouse-face 'tab-line-highlight 'pointer 'arrow
              'help-echo "Extensions"
              'keymap (lispm-browser-extensions--tab-line-keymap #'lispm-browser-extensions-menu nil)))

(defun lispm-browser-extensions--tab-line-width (string)
  "Return the width in pixels of STRING in the tab line, whose own face
gives what the faces of STRING leave unsaid: its font, smaller."
  (let ((copy (copy-sequence string)))
    (add-face-text-property 0 (length copy) 'tab-line t copy)
    (string-pixel-width copy)))

(defun lispm-browser-extensions--tab-line-draw ()
  "Return the tab line's buttons drawn, see `lispm-browser-extensions--tab-line'."
  (let ((buttons (lispm-browser-extensions-buttons))
        (height (frame-char-height)))
    (unless (and lispm-browser-extensions--tab-line
                 (equal (car lispm-browser-extensions--tab-line) buttons)
                 (eql (nth 1 lispm-browser-extensions--tab-line) height))
      (let ((string (concat (mapconcat #'lispm-browser-extensions--tab-line-button buttons "")
                            (lispm-browser-extensions--tab-line-puzzle))))
        (setq lispm-browser-extensions--tab-line
              (list buttons height string (lispm-browser-extensions--tab-line-width string)))))
    lispm-browser-extensions--tab-line))

(defun lispm-browser-extensions-tab-line-buttons ()
  "Return the toolbar's buttons for the end of a page's tab line, flush
right: see `lispm-browser-tab-line-end-function'."
  (pcase-let ((`(,_ ,_ ,string ,width) (lispm-browser-extensions--tab-line-draw)))
    (concat (propertize " " 'display `(space :align-to (- right (,(+ width lispm-browser-extensions-tab-line-margin)))))
            string
            (propertize " " 'display `(space :width (,lispm-browser-extensions-tab-line-margin))))))

(defun lispm-browser-extensions--tab-line-anchor (id)
  "Return the anchor of the tab line's button ID, or `menu' for the
Extensions button, in the browser's window."
  (when-let* (((eq lispm-browser-tab-line-end-function #'lispm-browser-extensions-tab-line-buttons))
              (window (lispm-browser-window)))
    (lispm-browser-extensions-button-anchor window 0 (window-tab-line-height window) id)))

;;;; Setup

(defun lispm-browser-extensions-setup ()
  "Run Chrome extensions in the browser's pages where Emacs can.
The host starts at once when its module is built, so that every page runs
them; the module is built in the background when extensions were added
before and it is missing or its sources changed."
  (when (and lispm-browser-extensions-enabled (lispm-browser-extensions-supported-p))
    ;; The toolbar's buttons end the tab line, unless the browser's chrome
    ;; draws them itself.
    (unless lispm-browser-tab-line-end-function
      (setq lispm-browser-tab-line-end-function #'lispm-browser-extensions-tab-line-buttons))
    (add-hook 'window-selection-change-functions #'lispm-browser-extensions--follow)
    (add-hook 'window-buffer-change-functions #'lispm-browser-extensions--follow)
    (let ((added (file-exists-p (expand-file-name "installed.json" lispm-browser-extensions-directory))))
      (cond ((and (lispm-browser-extensions--module-file)
                  (not (lispm-browser-extensions--stale-p)))
             (lispm-browser-extensions--start))
            ((and added (executable-find "swift"))
             (lispm-browser-extensions-build #'lispm-browser-extensions--start))
            ;; Changed sources and no Swift to build them: the module built
            ;; before runs still.
            ((lispm-browser-extensions--module-file)
             (lispm-browser-extensions--start))))))

(provide 'lispm-browser-extensions)
;;; lispm-browser-extensions.el ends here
