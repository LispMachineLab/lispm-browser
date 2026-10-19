;;; lispm-browser-extensions.el --- Chrome extensions in the browser  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-browser
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Chrome extensions in the browser's pages, on macOS 15.4 and later.
;; WebKit runs them itself (WKWebExtension, the engine Safari's extensions
;; run on) in every page view whose configuration carries its controller.
;; Emacs makes its page views itself, so the module lispm-browser-webext
;; (Swift, in native/lispm-browser-webext) hands each one the controller as
;; it is made, and hosts the extensions: the browser's pages are their tabs,
;; their popups hang from the page in front, and their questions are asked
;; here.  Most of the module is ported from Search, a WebKit browser for
;; macOS, with the script Search puts in every extension to fill in the
;; Chrome APIs WebKit lacks, so that heavy ones such as the Rabby wallet run;
;; a window an extension opens of its own is a Mac window.
;;
;;   Chrome Web Store link --install--> fetched, signature checked, asked, loaded
;;   M-e, an extension's button   --->  its popup, or its click
;;   Extensions menu, M-x lispm-browser-extensions: the list of them
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

(defconst lispm-browser-extensions-source-directory
  (expand-file-name "native/lispm-browser-webext"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory (or load-file-name buffer-file-name)))))
  "Directory of the module's Swift package.")

(defvar lispm-browser-extensions-changed-hook nil
  "Hook run when the extensions, their buttons or their badges change.")

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
:enabled, :loaded, :fromStore, :source, and, while it runs, :label, :badge,
:actionEnabled and :popup of its button for the page in front, :options
and :errors."
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
      ("search" (run-at-time 0 nil #'lispm-browser-extensions--search payload)))))

(defun lispm-browser-extensions--changed ()
  "Forget the list, and redraw what shows it."
  (setq lispm-browser-extensions--installed 'unread)
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

;;;###autoload
(defun lispm-browser-extensions-press (id)
  "Press the button of extension ID for the page in front: its popup opens,
or it is told it was clicked.  Asks which one, badges shown."
  (interactive
   (progn (unless lispm-browser-extensions--started
            (user-error "No extension runs: add one with M-x lispm-browser-extensions-install"))
          (lispm-browser-extensions--follow)
          (list (lispm-browser-extensions--read
                 "Press the button of: " #'lispm-browser-extensions--running-p))))
  (unless (lispm-browser-webext-module-action id)
    (user-error "That extension has no button")))

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
  "r" #'lispm-browser-extensions-reload
  "D" #'lispm-browser-extensions-remove
  "i" #'lispm-browser-extensions-install
  "l" #'lispm-browser-extensions-load-unpacked)

(define-derived-mode lispm-browser-extensions-mode tabulated-list-mode "Extensions"
  "The browser's Chrome extensions.
\\<lispm-browser-extensions-mode-map>
\\[lispm-browser-extensions-install] adds one from the Chrome Web Store,
\\[lispm-browser-extensions-load-unpacked] one from a folder.  On a line,
\\[lispm-browser-extensions-press] presses its button,
\\[lispm-browser-extensions-options] opens its options,
\\[lispm-browser-extensions-toggle] turns it on or off,
\\[lispm-browser-extensions-reload] reloads it and
\\[lispm-browser-extensions-remove] removes it."
  (setq tabulated-list-format [("Name" 28 t) ("Version" 12 nil) ("State" 7 t)
                               ("Badge" 6 nil) ("From" 0 nil)]
        tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook
            (lambda () (setq tabulated-list-entries (lispm-browser-extensions--entries)))
            nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun lispm-browser-extensions ()
  "List the browser's Chrome extensions, to add, press, set up and remove them."
  (interactive)
  (lispm-browser-extensions--ensure
   (lambda ()
     (with-current-buffer (get-buffer-create "*Browser Extensions*")
       (lispm-browser-extensions-mode)
       (setq tabulated-list-entries (lispm-browser-extensions--entries))
       (tabulated-list-print)
       (pop-to-buffer (current-buffer))))))

;;;; The browser's Extensions menu

(defun lispm-browser-extensions--menu-items ()
  "Return the items of the browser's Extensions menu: each running
extension's button, then adding and managing them."
  (let ((running (and lispm-browser-extensions--started
                      (seq-filter #'lispm-browser-extensions--running-p
                                  (lispm-browser-extensions-installed)))))
    `(,@(mapcar (lambda (extension)
                  (let ((id (plist-get extension :id)))
                    (list :label (lispm-browser-extensions--label extension)
                          :action (lambda () (lispm-browser-extensions-press id))
                          :enabled (plist-get extension :actionEnabled))))
                running)
      ,@(when running '(separator))
      (:label "Add This Extension" :action lispm-browser-extensions-install-shown
              :enabled ,(and (lispm-browser-extensions--shown-store-id) t))
      (:label "Add from Chrome Web Store…" :action lispm-browser-extensions-install)
      (:label "Load Unpacked…" :action lispm-browser-extensions-load-unpacked)
      separator
      (:label "Manage Extensions" :action lispm-browser-extensions))))

;;;; Setup

(defun lispm-browser-extensions-setup ()
  "Run Chrome extensions in the browser's pages where Emacs can.
The host starts at once when its module is built, so that every page runs
them; the module is built in the background when extensions were added
before and it is missing or its sources changed."
  (when (and lispm-browser-extensions-enabled (lispm-browser-extensions-supported-p))
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
