;;; lispm-browser.el --- A WebKit browser in Emacs, with tabs and Chrome extensions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-browser
;; Version: 0.4.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: hypermedia, comm
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

;; lispm-browser makes the WebKit pages of an Emacs built with xwidgets a
;; browser: its pages are tabs, kept in the order they were opened, each
;; with its page's icon; it remembers the pages visited and keeps
;; bookmarks (lispm-browser-places.el), follows links and types in fields
;; from the keyboard (lispm-browser-hints.el), and runs Chrome extensions
;; on macOS (lispm-browser-extensions.el).  It also keeps Emacs from the
;; crashes closing pages and running page scripts could cause on macOS.
;;
;;   (require 'lispm-browser)
;;   (lispm-browser-setup)
;;   M-x lispm-browser                 show the browser, or open its home page
;;   M-x lispm-browser-browse-url      open an address
;;
;; Out of the box a page shows its tabs in its tab line, a click choosing
;; one, its close button or a middle click closing it, and takes the keys
;; of `lispm-browser-keys'.  A program giving the
;; browser a look of its own, as LispM Desktop draws Netscape Communicator's
;; window, says where it is through these variables and hooks:
;;
;;   `lispm-browser-window-function'      the window showing the page
;;   `lispm-browser-tab-window-function'  where a tab opens when none shows
;;   `lispm-browser-show-function'        showing the browser
;;   `lispm-browser-raise-function'       bringing it in front
;;   `lispm-browser-tab-hook'             each new tab's buffer, set up
;;   `lispm-browser-change-hook'          the page or the tab shown changed
;;   `lispm-browser-redraw-hook'          a title or a page icon changed
;;   `lispm-browser-before-quit-hook'     the browser quits, tabs still open
;;   `lispm-browser-quit-hook'            the browser quit, tabs closed

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tab-line)
(require 'thingatpt)
(require 'url-util)

(declare-function xwidget-at "xwidget" (pos))
(declare-function xwidget-webkit-uri "xwidget" (xwidget))
(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))
(declare-function xwidget-webkit-browse-url "xwidget" (url &optional new-session))
(declare-function xwidget-webkit-current-session "xwidget" ())
(declare-function xwidget-webkit-back "xwidget" ())
(declare-function xwidget-webkit-forward "xwidget" ())
(declare-function xwidget-webkit-reload "xwidget" ())
(declare-function xwidget-webkit-stop "xwidget" ())
(declare-function xwidget-webkit-back-forward-list "xwidget.c" (xwidget &optional limit))
(declare-function xwidget-webkit-execute-script "xwidget.c" (xwidget script &optional fun))
(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(defvar xwidget-webkit--loading-p)
(defvar xwidget-list)

(defgroup lispm-browser nil
  "A WebKit browser in Emacs, with tabs and Chrome extensions."
  :group 'hypermedia
  :prefix "lispm-browser-")

(defcustom lispm-browser-home-url "https://duckduckgo.com"
  "Page a new tab opens, and Home goes to."
  :type 'string
  :group 'lispm-browser)

(defcustom lispm-browser-search-url "https://duckduckgo.com/?q=%s"
  "Address searched for what is typed as an address that is no address,
%s standing for the words searched."
  :type 'string
  :group 'lispm-browser)

(defconst lispm-browser-tab-width 24
  "Maximum width in columns of a tab's title.")

;;;; Addresses

(defun lispm-browser-available-p ()
  "Return non-nil when this Emacs can show WebKit pages: built with xwidgets,
on a graphical display, as a text terminal draws none."
  (and (featurep 'xwidget-internal)
       (fboundp 'xwidget-webkit-browse-url)
       (display-graphic-p)))

(defun lispm-browser-normalize-url (url)
  "Return URL with a scheme, https when it names none."
  (if (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" url)
      url
    (concat "https://" url)))

(defun lispm-browser-input-url (input)
  "Return the address to visit for INPUT, typed as an address.
A local host (localhost or 127.0.0.1, with any port or path) is served over
http; input that names a scheme, or a dotted host without spaces, is an
address; anything else is a search, see `lispm-browser-search-url'."
  (cond ((string-match-p "\\`\\(localhost\\|127\\.0\\.0\\.1\\)\\([:/]\\|\\'\\)" input)
         (concat "http://" input))
        ((or (string-match-p "\\`[a-z][a-z0-9+.-]*://" input)
             (and (string-match-p "\\." input) (not (string-match-p " " input))))
         (lispm-browser-normalize-url input))
        (t (format lispm-browser-search-url (url-hexify-string input)))))

(defun lispm-browser-browse-url (url &rest _)
  "Open URL in a WebKit page when this Emacs has them, else in the system's
browser.  It also serves as a `browse-url-browser-function'."
  (interactive (list (read-string "URL: " (or (thing-at-point-url-at-point) ""))))
  (if (lispm-browser-available-p)
      (xwidget-webkit-browse-url (lispm-browser-normalize-url url))
    (browse-url-default-browser (lispm-browser-normalize-url url))))

(defun lispm-browser-web-search (query)
  "Search the web for QUERY, see `lispm-browser-search-url'."
  (interactive (list (read-string "Search: " (or (thing-at-point 'symbol t) ""))))
  (lispm-browser-browse-url (format lispm-browser-search-url (url-hexify-string query))))

(defun lispm-browser-open-url-at-point ()
  "Open the address at point in a WebKit page when this Emacs has them."
  (interactive)
  (let ((url (thing-at-point-url-at-point)))
    (unless url
      (user-error "No URL at point"))
    (lispm-browser-browse-url url)))

;;;; Tabs and the window showing them

(defvar lispm-browser--tab-order nil
  "Tab buffers in the order they were opened.
Buffer names follow page titles, so they cannot order the tabs.")

(defun lispm-browser-tabs ()
  "Return the live tabs, in the order they were opened."
  (setq lispm-browser--tab-order (seq-filter #'buffer-live-p lispm-browser--tab-order)))

(defun lispm-browser-title (buffer)
  "Return the page title of tab BUFFER, from its buffer name."
  (let ((name (string-trim (buffer-name buffer) "\\*" "\\*")))
    (string-trim (replace-regexp-in-string "\\`xwidget[- ]webkit: ?" "" name))))

(defun lispm-browser--page-window-p (window)
  "Return non-nil when WINDOW shows a WebKit page."
  (eq (buffer-local-value 'major-mode (window-buffer window)) 'xwidget-webkit-mode))

(defun lispm-browser--window-on-frame ()
  "Return the selected window when it shows a page, or else a window of
the selected frame showing one, or nil."
  (if (lispm-browser--page-window-p (selected-window))
      (selected-window)
    (seq-find #'lispm-browser--page-window-p (window-list nil 'no-mini))))

(defvar lispm-browser-window-function #'lispm-browser--window-on-frame
  "Function returning the window showing the browser's page, or nil.")

(defvar lispm-browser-tab-window-function #'selected-window
  "Function returning the window a new tab opens in when no window shows
the browser.")

(defun lispm-browser-window ()
  "Return the window showing the browser's page, or nil.
See `lispm-browser-window-function'."
  (funcall lispm-browser-window-function))

(defun lispm-browser-shown-buffer ()
  "Return the shown tab's buffer, or nil."
  (when-let* ((window (lispm-browser-window)))
    (window-buffer window)))

(defun lispm-browser-uri (&optional buffer)
  "Return the address of the page in tab BUFFER, by default the shown tab."
  (when-let* ((buffer (or buffer (lispm-browser-shown-buffer)))
              (xwidget (with-current-buffer buffer (xwidget-at (point-min)))))
    (xwidget-webkit-uri xwidget)))

(defvar lispm-browser-change-hook nil
  "Hook run once the page shown or the tab shown changed: after navigating,
choosing a tab, opening one and closing one.")

(defvar lispm-browser-redraw-hook nil
  "Hook run when what tabs show changed without a navigation: a page icon
arrived, or a page's title.")

(defun lispm-browser--changed ()
  "Tell the browser's chrome that the page or the tab shown changed."
  (run-hooks 'lispm-browser-change-hook))

(defun lispm-browser--redraw ()
  "Redraw the tabs: their titles or icons changed."
  (run-hooks 'lispm-browser-redraw-hook)
  (force-mode-line-update t))

(defvar-local lispm-browser-status-note nil
  "What the page's status says instead of its state, or nil.
Following a link from the keyboard and typing in a page tell their keys
there.")

;;;; Showing the browser

(defun lispm-browser--show-in-selected-window ()
  "Show the browser in the selected window: the window showing it is
selected, or else the first tab is shown, or else the home page opens."
  (if-let* ((window (lispm-browser-window)))
      (select-window window)
    (if-let* ((tab (car (lispm-browser-tabs))))
        (pop-to-buffer-same-window tab)
      (xwidget-webkit-browse-url lispm-browser-home-url t))))

(defun lispm-browser--select-window ()
  "Select the window showing the browser."
  (when-let* ((window (lispm-browser-window)))
    (select-window window)))

(defvar lispm-browser-show-function #'lispm-browser--show-in-selected-window
  "Function showing the browser with a tab: the first when none is shown,
the home page when there is none.")

(defvar lispm-browser-raise-function #'lispm-browser--select-window
  "Function bringing the browser in front once it shows a page.")

(defun lispm-browser-show ()
  "Show the browser, opening `lispm-browser-home-url' when there is no tab.
See `lispm-browser-show-function'."
  (interactive)
  (funcall lispm-browser-show-function))

(defun lispm-browser ()
  "Show the browser, see `lispm-browser-show'."
  (interactive)
  (unless (lispm-browser-available-p)
    (if (featurep 'xwidget-internal)
        (user-error "WebKit pages show only on a graphical display, not on a text terminal")
      (user-error "This Emacs has no WebKit pages: it was built without xwidgets")))
  (lispm-browser-show))

;;;; Navigation

(defun lispm-browser--in-page (command)
  "Run COMMAND, a WebKit navigation command, in the shown tab."
  (when-let* ((window (lispm-browser-window)))
    (with-selected-window window
      (funcall command))
    (lispm-browser--changed)))

(defun lispm-browser-back ()
  "Go back a page in the shown tab."
  (interactive)
  (lispm-browser--in-page #'xwidget-webkit-back))

(defun lispm-browser-forward ()
  "Go forward a page in the shown tab."
  (interactive)
  (lispm-browser--in-page #'xwidget-webkit-forward))

(defun lispm-browser-reload ()
  "Load the shown tab's page again."
  (interactive)
  (lispm-browser--in-page #'xwidget-webkit-reload))

(defun lispm-browser-home ()
  "Go to `lispm-browser-home-url' in the shown tab."
  (interactive)
  (lispm-browser--in-page
   (lambda () (xwidget-webkit-goto-uri (xwidget-at (point-min)) lispm-browser-home-url))))

(defun lispm-browser-stop ()
  "Stop loading the shown tab's page."
  (interactive)
  (lispm-browser--in-page #'xwidget-webkit-stop))

(defun lispm-browser-navigation-state ()
  "Return what the shown tab can do: (:page P :back B :forward F :loading L).
Where WebKit cannot tell the pages back and forward, as on macOS, Back and
Forward are open to any page."
  (let* ((buffer (lispm-browser-shown-buffer))
         (xwidget (and buffer (with-current-buffer buffer (xwidget-at (point-min)))))
         (known (fboundp 'xwidget-webkit-back-forward-list))
         (pages (and xwidget known (ignore-errors (xwidget-webkit-back-forward-list xwidget 1)))))
    (list :page (and xwidget t)
          :back (and xwidget (or (not known) (car pages)) t)
          :forward (and xwidget (or (not known) (nth 2 pages)) t)
          :loading (and buffer (buffer-local-value 'xwidget-webkit--loading-p buffer) t))))

(defun lispm-browser-open-url (url &optional new-tab)
  "Show the page at URL in the shown tab, or in a new tab when NEW-TAB or
when none is shown.  The browser comes in front."
  (let ((window (lispm-browser-window)))
    (cond ((and window (not new-tab))
           (with-current-buffer (window-buffer window)
             (xwidget-webkit-goto-uri (xwidget-at (point-min)) url))
           (lispm-browser--changed))
          (window (lispm-browser-new-tab url))
          (t (lispm-browser-show)
             (lispm-browser-open-url url)))
    (funcall lispm-browser-raise-function)))

(defun lispm-browser-open-external ()
  "Open the shown tab's page in the system's default browser."
  (interactive)
  (if-let* ((uri (lispm-browser-uri)))
      (browse-url-default-browser uri)
    (user-error "No page is shown")))

(defconst lispm-browser--paste-script
  "(function (text) {
  var field = document.activeElement;
  if (field && typeof field.setRangeText === 'function') {
    field.setRangeText(text, field.selectionStart, field.selectionEnd, 'end');
    field.dispatchEvent(new InputEvent('input', {bubbles: true,
      inputType: 'insertFromPaste', data: text}));
  } else {
    document.execCommand('insertText', false, text);
  }
})(%s);"
  "Script inserting a text, its JSON-encoded argument, at the page's caret.
Text fields take it through `setRangeText', which leaves it verbatim, and
are told by an input event, so scripted pages see the change;
`insertText' would have WebKit turn straight quotes into curly ones.
Rich-text editors, which have no such method, take `insertText'.")

(defun lispm-browser-paste (text)
  "Insert TEXT verbatim at the caret of the shown page's focused field.
The text travels as a JSON string literal, so quotes and newlines in it
cannot break out of `lispm-browser--paste-script'."
  (lispm-browser-run-script (xwidget-webkit-current-session)
                            (format lispm-browser--paste-script (json-encode text))))

;;;; Tab commands

(defun lispm-browser-select-tab (buffer)
  "Show tab BUFFER in the browser's window."
  (when-let* ((window (lispm-browser-window)))
    (set-window-buffer window buffer)
    (lispm-browser--changed)))

(defun lispm-browser--step-tab (step)
  "Show the tab STEP places from the one shown, wrapping around."
  (let* ((tabs (lispm-browser-tabs))
         (index (or (seq-position tabs (lispm-browser-shown-buffer)) 0)))
    (when (cdr tabs)
      (lispm-browser-select-tab (nth (mod (+ index step) (length tabs)) tabs)))))

(defun lispm-browser-next-tab ()
  "Show the next tab."
  (interactive)
  (lispm-browser--step-tab 1))

(defun lispm-browser-previous-tab ()
  "Show the previous tab."
  (interactive)
  (lispm-browser--step-tab -1))

(defun lispm-browser-new-tab (&optional url)
  "Open URL, by default `lispm-browser-home-url', in a new tab and show it.
It opens in the browser's window, or else in the window of
`lispm-browser-tab-window-function'."
  (interactive)
  (with-selected-window (or (lispm-browser-window) (funcall lispm-browser-tab-window-function))
    (xwidget-webkit-browse-url (or url lispm-browser-home-url) t))
  (lispm-browser--changed))

(defvar lispm-browser-before-quit-hook nil
  "Hook run as the browser quits, while its tabs are still open.")

(defvar lispm-browser-quit-hook nil
  "Hook run once the browser quit and its tabs are closed.")

(defun lispm-browser-quit ()
  "Quit the browser: close every tab."
  (interactive)
  (run-hooks 'lispm-browser-before-quit-hook)
  (let ((kill-buffer-query-functions nil))
    (mapc #'kill-buffer (lispm-browser-tabs)))
  (run-hooks 'lispm-browser-quit-hook))

(defun lispm-browser-close-tab (buffer)
  "Close tab BUFFER without asking.
Closing a tab behind leaves the shown tab shown; closing the shown tab
shows the one after it, or the one before when it was the last, as
Chrome does.  Closing the last tab quits the browser, see
`lispm-browser-quit'."
  (let* ((window (lispm-browser-window))
         (shown (and window (window-buffer window)))
         (index (or (seq-position (lispm-browser-tabs) buffer) 0))
         (kill-buffer-query-functions nil))
    (kill-buffer buffer)
    (if-let* ((tabs (lispm-browser-tabs)))
        (when (and (eq buffer shown) (window-live-p window))
          (set-window-buffer window (nth (min index (1- (length tabs))) tabs)))
      (lispm-browser-quit)))
  (lispm-browser--changed))

(defun lispm-browser-close-shown-tab ()
  "Close the shown tab, see `lispm-browser-close-tab'."
  (interactive)
  (when-let* ((window (lispm-browser-window)))
    (lispm-browser-close-tab (window-buffer window))))

;;;; Page icons
;;
;; A tab shows its page's icon.  Once a page has loaded, a script reads the
;; icon's address from the page; the icon is fetched once per address,
;; without cookies, and decoded by the image backend:
;;
;;   page --script--> icon address --fetch--> bytes --decode--> image
;;
;; Until the icon is known, or when the page has none, a tab shows none.

(defconst lispm-browser--favicon-script
  "(function () {
  var link = document.querySelector('link[rel~=\"icon\"]')
          || document.querySelector('link[rel=\"apple-touch-icon\"]');
  var icon = link && link.href ? link.href
           : location.protocol.indexOf('http') === 0
             ? location.origin + '/favicon.ico' : '';
  return location.href + '\\n' + icon;
})()"
  "Script returning the document's address and its icon's, on two lines.
A page names its icon in a link element; failing that, browsers look for
/favicon.ico at the page's origin.  The icon line is empty when there is
none.  The document's address tells whose icon it is: while a page loads,
the view's address is already the new page's but the document is the old.")

(defvar lispm-browser--favicons (make-hash-table :test #'equal)
  "Icon per icon address: an image, `pending' while fetched, `none' if unusable.")

(defvar-local lispm-browser--favicon-source nil
  "(PAGE . ICON): the page address this tab's icon was looked up for, and
the icon's address, `pending' while the page is asked, or nil for none.")

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defun lispm-browser--favicon-image (data)
  "Return icon DATA as an image a line high, or nil when it is no image.
Formats Emacs recognizes are accepted, and ICO by its magic bytes: the
macOS image backend decodes ICO when asked for PNG.  Anything else would
draw as an empty box, so it is refused."
  (when-let* ((type (or (image-type-from-data data)
                        (and (string-prefix-p "\0\0\1\0" data) 'png))))
    (create-image data type t
                  :height (round (* 0.85 (frame-char-height)))
                  :ascent 'center)))

(defun lispm-browser--data-url-bytes (url)
  "Return the bytes a data URL holds, or nil when URL is malformed."
  (when (string-match "\\`data:[^,]*?\\(;base64\\)?," url)
    (let ((base64 (match-beginning 1))
          (payload (substring url (match-end 0))))
      (if base64
          (ignore-errors (base64-decode-string payload))
        (encode-coding-string (url-unhex-string payload) 'utf-8)))))

(defun lispm-browser--store-favicon (icon data)
  "Record icon address ICON as fetched with DATA, nil on failure, and redraw."
  (puthash icon (or (and data (lispm-browser--favicon-image data)) 'none)
           lispm-browser--favicons)
  (lispm-browser--redraw))

(defun lispm-browser--fetch-favicon (icon)
  "Fetch the icon at address ICON, once, and store it as it arrives.
A data URL is decoded in place; others are fetched without cookies, and
only a successful response's body is kept."
  (puthash icon 'pending lispm-browser--favicons)
  (if (string-prefix-p "data:" icon)
      (lispm-browser--store-favicon icon (lispm-browser--data-url-bytes icon))
    (require 'url)
    (url-retrieve
     icon
     (lambda (status)
       (let ((data (and (not (plist-get status :error))
                        (eql url-http-response-status 200)
                        (bound-and-true-p url-http-end-of-headers)
                        (buffer-substring-no-properties
                         (1+ url-http-end-of-headers) (point-max)))))
         (kill-buffer)
         (lispm-browser--store-favicon icon data)))
     nil t t)))

(defun lispm-browser--look-up-favicon (buffer page)
  "Ask tab BUFFER's PAGE for its icon address, then fetch the icon.
Only web and data addresses are followed.  An answer arriving after the
tab moved to another page is dropped.  An answer from another document
than PAGE's, the one being replaced while PAGE loads, is no answer: the
lookup is forgotten and runs again at the next redraw, which the finished
load brings."
  (with-current-buffer buffer
    (setq lispm-browser--favicon-source (cons page 'pending))
    (when-let* ((xwidget (xwidget-at (point-min))))
      (lispm-browser-run-script
       xwidget lispm-browser--favicon-script
       (lambda (answer)
         (when (and (buffer-live-p buffer)
                    (equal (car (buffer-local-value 'lispm-browser--favicon-source buffer))
                           page))
           (pcase-let* ((`(,document ,icon) (and (stringp answer)
                                                 (split-string answer "\n")))
                        (icon (and icon
                                   (string-match-p "\\`\\(?:https?\\|data\\):" icon)
                                   icon)))
             (with-current-buffer buffer
               (setq lispm-browser--favicon-source
                     (and (equal document page) (cons page icon))))
             (when (and icon (equal document page)
                        (not (gethash icon lispm-browser--favicons)))
               (lispm-browser--fetch-favicon icon))
             (lispm-browser--redraw))))))))

(defun lispm-browser-favicon (buffer)
  "Return tab BUFFER's page icon as a string showing it, or nil.
Nil stands for an icon not known yet or absent.  A loaded page whose icon
was not looked up yet has its lookup started."
  (when-let* ((page (lispm-browser-uri buffer)))
    (let ((source (buffer-local-value 'lispm-browser--favicon-source buffer)))
      (cond ((buffer-local-value 'xwidget-webkit--loading-p buffer) nil)
            ((not (equal (car source) page))
             (lispm-browser--look-up-favicon buffer page)
             nil)
            ((stringp (cdr source))
             (let ((image (gethash (cdr source) lispm-browser--favicons)))
               (when (consp image)
                 (propertize " " 'display image))))))))

;;;; The tab line

(defun lispm-browser-tab-command (function &rest args)
  "Return an interactive command applying FUNCTION to ARGS."
  (lambda () (interactive) (apply function args)))

(defun lispm-browser-tab-keymap (command &optional close)
  "Return the keymap of a tab in a tab line, running COMMAND when clicked.
CLOSE, when given, runs on a middle click, as a middle click closes a tab
in Emacs's own tab line and in Chrome."
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<tab-line> <down-mouse-1>" #'ignore)
    (keymap-set map "<tab-line> <mouse-1>" command)
    (when close
      (keymap-set map "<tab-line> <down-mouse-2>" #'ignore)
      (keymap-set map "<tab-line> <mouse-2>" close))
    map))

(defun lispm-browser-tab-close-command (buffer)
  "Return the command closing tab BUFFER, for its close button."
  (lispm-browser-tab-command #'lispm-browser-close-tab buffer))

(defun lispm-browser--tab-label (buffer)
  "Return the label of tab BUFFER: its page's icon, when known, and title."
  (let ((icon (lispm-browser-favicon buffer)))
    (concat (and icon (concat icon " "))
            (truncate-string-to-width (lispm-browser-title buffer)
                                      lispm-browser-tab-width nil nil "…"))))

(defvar lispm-browser-tab-line-end-function nil
  "Function returning what the tab line shows at its right end, or nil:
the toolbar's buttons of the extensions, once they run (see
`lispm-browser-extensions-tab-line-buttons').")

(defun lispm-browser--tab-close-button (buffer face)
  "Return the button closing tab BUFFER, in the tab's FACE.
It is the icon of Emacs's own tab line, `tab-line-close'."
  (let ((button (copy-sequence (icon-string 'tab-line-close)))
        (close (lispm-browser-tab-close-command buffer)))
    (add-face-text-property 0 (length button) face t button)
    (propertize button
                'mouse-face 'tab-line-close-highlight 'pointer 'arrow
                'keymap (lispm-browser-tab-keymap close close)
                'help-echo "Close this tab")))

(defun lispm-browser-tab-line ()
  "Return the tab line of the page being drawn: a tab per page, its own in
front, each with a button closing it, then + for a new one, and what
`lispm-browser-tab-line-end-function' puts at the right end.  A middle
click on a tab closes it too."
  (let ((shown (current-buffer)))
    (concat
     (mapconcat (lambda (buffer)
                  (let ((face (if (eq buffer shown) 'tab-line-tab-current 'tab-line-tab-inactive))
                        (properties
                         (list 'mouse-face 'tab-line-highlight 'pointer 'arrow
                               'keymap (lispm-browser-tab-keymap
                                        (lispm-browser-tab-command #'lispm-browser-select-tab buffer)
                                        (lispm-browser-tab-close-command buffer))
                               'help-echo (or (lispm-browser-uri buffer) "Show this tab"))))
                    (concat (apply #'propertize (concat " " (lispm-browser--tab-label buffer))
                                   'face face properties)
                            (lispm-browser--tab-close-button buffer face)
                            (apply #'propertize " " 'face face properties))))
                (lispm-browser-tabs) "")
     (propertize " + " 'face 'tab-line-tab-inactive 'mouse-face 'tab-line-highlight 'pointer 'arrow
                 'keymap (lispm-browser-tab-keymap #'lispm-browser-new-tab)
                 'help-echo "New tab")
     (and lispm-browser-tab-line-end-function
          (funcall lispm-browser-tab-line-end-function)))))

;;;; Keys

(declare-function lispm-browser-open-location "lispm-browser-places" ())
(declare-function lispm-browser-add-bookmark "lispm-browser-places" ())
(declare-function lispm-browser-open-bookmark "lispm-browser-places" (name))
(declare-function lispm-browser-open-from-history "lispm-browser-places" (url))
(declare-function lispm-browser-extensions-press "lispm-browser-extensions" (id))

(defconst lispm-browser-keys
  '(("C-l" . lispm-browser-open-location)
    ("M-l" . lispm-browser-open-location)
    ("M-[" . lispm-browser-back)
    ("M-]" . lispm-browser-forward)
    ("M-r" . lispm-browser-reload)
    ("M-." . lispm-browser-stop)
    ("M-d" . lispm-browser-add-bookmark)
    ("M-b" . lispm-browser-open-bookmark)
    ("M-y" . lispm-browser-open-from-history)
    ("M-t" . lispm-browser-new-tab)
    ("M-}" . lispm-browser-next-tab)
    ("M-{" . lispm-browser-previous-tab)
    ("M-e" . lispm-browser-extensions-press))
  "The keys of a page, Command keys where Command is Meta: Command-L opens an
address, Command-[ and ] go back and forward, Command-D bookmarks the page,
Command-B opens a bookmark, Command-Y a page visited.  Command-T opens a
tab, Command-} and Command-{ go to the next and the previous.  Command-E
presses an extension's button, see
`lispm-browser-extensions-press'.")

(defun lispm-browser-bind-keys (map &optional keys)
  "Bind KEYS, by default `lispm-browser-keys', in keymap MAP."
  (pcase-dolist (`(,key . ,command) (or keys lispm-browser-keys))
    (keymap-set map key command)))

;;;; Each tab's buffer

(defvar lispm-browser-tab-hook nil
  "Hook run in a new tab's buffer once it is set up as a tab.
A program giving the browser chrome of its own sets the buffer's tab line,
header line and mode line here.")

(defun lispm-browser--arrow-pointer (buffer)
  "Show the arrow mouse pointer over the page in tab BUFFER.
Emacs picks the pointer over a window itself, and the page is a character
displaying the WebKit view, so it would otherwise get the text I-beam."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local void-text-area-pointer 'arrow)
      (with-silent-modifications
        (let ((inhibit-read-only t))
          (put-text-property (point-min) (point-max) 'pointer 'arrow))))))

(defun lispm-browser--setup-tab ()
  "Set up a new WebKit page's buffer as a tab, appended to the tab order.
It shows the tabs in its tab line until `lispm-browser-tab-hook' says
otherwise.  The page is inserted after this mode hook runs, so the arrow
pointer is applied once the current command finishes."
  (setq-local tab-line-format '(:eval (lispm-browser-tab-line)))
  (run-at-time 0 nil #'lispm-browser--arrow-pointer (current-buffer))
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (setq lispm-browser--tab-order (append lispm-browser--tab-order (list (current-buffer))))
  (run-hooks 'lispm-browser-tab-hook))

;;;; Late events of closed pages
;;
;; Closing a page could crash Emacs on macOS (Emacs 31.1, NS build): a
;; segmentation fault in print_object, under `xwidget-log', under
;; `xwidget-event-handler'.  The bug is Emacs's.  A page's WebKit view
;; keeps a plain C pointer to its xwidget, in its navigation delegate and
;; in the completion handler of each script it runs, and the garbage
;; collector does not see it.  Killing the page's buffer kills its xwidget,
;; which itself loads about:blank to silence the page, yet WebKit may still
;; call back: a load or a script finishing after the kill posts an
;; `xwidget-event' naming the xwidget, by then perhaps collected.  The
;; handler first logs the event with %S, printing the freed object; the
;; collector, marking the event while it waits to be read, may fault on it
;; even before.  It is a race, lost now and then; stopping the page before
;; killing it would not win it, as the kill loads a page of its own.
;;
;; So the xwidgets of a killed buffer are kept from the collector a minute,
;; which keeps WebKit's pointer valid: its navigation callbacks then find
;; the buffer dead and post nothing, and a finished script's event names a
;; killed but valid xwidget.  And an event whose xwidget is no longer in
;; `xwidget-list' is dropped before the handler runs.  `memq' finds the
;; xwidget there or not without reading it; `xwidget-live-p' would read it,
;; and on macOS a killed xwidget keeps its buffer, which it checks.

(defvar lispm-browser--killed-xwidgets nil
  "Xwidgets of killed buffers, kept from the garbage collector a minute.")

(defun lispm-browser--keep-killed-xwidgets ()
  "Keep the xwidgets of the buffer being killed from the garbage collector.
They are let go a minute later, when WebKit has long called back for the
last time.  This is on `kill-buffer-hook', which runs before the buffer's
xwidgets are killed."
  (when-let* (((fboundp 'get-buffer-xwidgets))
              (xwidgets (get-buffer-xwidgets (current-buffer))))
    (setq lispm-browser--killed-xwidgets
          (append xwidgets lispm-browser--killed-xwidgets))
    (run-at-time 60 nil #'lispm-browser--let-go-xwidgets xwidgets)))

(defun lispm-browser--let-go-xwidgets (xwidgets)
  "Let the garbage collector have XWIDGETS, of a buffer killed a minute ago."
  (dolist (xwidget xwidgets)
    (setq lispm-browser--killed-xwidgets
          (delq xwidget lispm-browser--killed-xwidgets))))

(defun lispm-browser--xwidget-event-live-p (&optional event)
  "Return non-nil unless EVENT is an `xwidget-event' of a killed xwidget.
EVENT defaults to `last-input-event'.  As an advice of
`xwidget-event-handler', this drops the events of killed xwidgets, which
the handler would print although they may have been freed."
  (let ((event (or event last-input-event)))
    (or (not (eq (car-safe event) 'xwidget-event))
        (memq (nth 2 event) (bound-and-true-p xwidget-list)))))

;;;; Callbacks of page scripts
;;
;; A function given to `xwidget-webkit-execute-script' could crash Emacs on
;; macOS (Emacs 31.1, NS build).  The bug is Emacs's.  Only GTK builds keep
;; the function from the garbage collector, saved with the xwidget; on
;; macOS it is held only by the completion handler WebKit runs when the
;; script returns (src/nsxwidget.m), which the collector does not see.  A
;; closure nothing else holds, such as a lambda written at the call, may
;; then be collected while the script runs.  The handler tests the freed
;; object with FUNCTIONP and posts an `xwidget-event' holding it, which
;; `xwidget-event-handler' prints with `xwidget-log' and calls; the
;; collector, marking the event while it waits to be read, may fault on it
;; even before.  A symbol is safe, as an interned symbol is never collected.
;;
;; So pages are sent scripts by `lispm-browser-run-script', which keeps
;; each callback in `lispm-browser--script-callbacks' until it is called,
;; with the page's xwidget, which the event names.  On macOS, WebKit calls
;; back only with a value: not when a script returns null or undefined,
;; fails, or is blocked by the page's policy.  Such callbacks would be kept
;; for ever, so the list is pruned as scripts are sent.  A callback a
;; minute old, long after WebKit would have called it, is let go if its
;; page is closed, its xwidget no longer in `xwidget-list'; of those whose
;; page is open, only the newest few are kept.  A page just closed may
;; still answer, so its callbacks are not let go at once.

(defconst lispm-browser--script-callback-age 60
  "Seconds a script's callback is kept at least, waiting to be called.")

(defconst lispm-browser--script-callbacks-kept 32
  "How many callbacks past that age are kept for open pages, the newest.")

(defvar lispm-browser--script-callbacks nil
  "Callbacks of scripts sent to pages, kept from the garbage collector.
Each is (FUNCTION XWIDGET TIME): the function WebKit calls with the
script's value, the page's xwidget, and when the script was sent.  The
newest comes first.")

(defun lispm-browser--prune-script-callbacks ()
  "Let go of the callbacks of scripts WebKit will not call back for.
A callback a minute old is let go when its page is closed; of those
whose page is open, the newest `lispm-browser--script-callbacks-kept'
are kept."
  (let ((now (float-time))
        (kept 0))
    (setq lispm-browser--script-callbacks
          (cl-remove-if-not
           (lambda (entry)
             (pcase-let ((`(,_ ,xwidget ,time) entry))
               (or (< (- now time) lispm-browser--script-callback-age)
                   (and (memq xwidget (bound-and-true-p xwidget-list))
                        (<= (cl-incf kept) lispm-browser--script-callbacks-kept)))))
           lispm-browser--script-callbacks))))

(defun lispm-browser-run-script (xwidget script &optional callback)
  "Run SCRIPT, JavaScript, in XWIDGET's page; call CALLBACK with its value.
Unlike `xwidget-webkit-execute-script' on macOS, this keeps CALLBACK
from the garbage collector until WebKit calls it.  On macOS WebKit
calls it only with a value, never for null or undefined."
  (if (null callback)
      (xwidget-webkit-execute-script xwidget script)
    (lispm-browser--prune-script-callbacks)
    (let* ((entry (list nil xwidget (float-time)))
           (answered (lambda (value)
                       (setq lispm-browser--script-callbacks
                             (delq entry lispm-browser--script-callbacks))
                       (funcall callback value))))
      (setcar entry answered)
      (push entry lispm-browser--script-callbacks)
      (xwidget-webkit-execute-script xwidget script answered))))

;;;; Setup

(defvar xwidget-webkit-mode-map)
(declare-function lispm-browser-places-setup "lispm-browser-places" ())
(declare-function lispm-browser-hints-setup "lispm-browser-hints" ())
(declare-function lispm-browser-extensions-setup "lispm-browser-extensions" ())

(defun lispm-browser-setup-core ()
  "Make WebKit pages tabs, and keep closing them from crashing Emacs.
`lispm-browser-setup' runs this, and sets the rest of the browser up."
  (add-hook 'xwidget-webkit-mode-hook #'lispm-browser--setup-tab)
  (add-hook 'kill-buffer-hook #'lispm-browser--keep-killed-xwidgets)
  (advice-add 'xwidget-event-handler :before-while #'lispm-browser--xwidget-event-live-p))

(defun lispm-browser-setup (&optional keys)
  "Set the browser up: tabs, history and bookmarks, hints, extensions.
Pages take `lispm-browser-keys' unless KEYS is `none'.  Extensions start
once Emacs has started, so an init file can still turn them off with
`lispm-browser-extensions-enabled'; pages opened before run none."
  (lispm-browser-setup-core)
  (require 'lispm-browser-places)
  (require 'lispm-browser-hints)
  (require 'lispm-browser-extensions)
  (lispm-browser-places-setup)
  (lispm-browser-hints-setup)
  (unless (eq keys 'none)
    (with-eval-after-load 'xwidget
      (lispm-browser-bind-keys xwidget-webkit-mode-map)))
  (if after-init-time
      (lispm-browser-extensions-setup)
    (add-hook 'window-setup-hook #'lispm-browser-extensions-setup -10)))

(provide 'lispm-browser)
;;; lispm-browser.el ends here
