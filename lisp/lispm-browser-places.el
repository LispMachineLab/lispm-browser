;;; lispm-browser-places.el --- The browser's history and bookmarks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/RyanKung/lispm
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

;; What the browser remembers, as Netscape Communicator remembered it: the
;; pages visited, its History, and the pages kept, its bookmarks.
;;
;;   page --finished loading--> history, a file of its own
;;   Add Bookmark --> Emacs's own bookmarks (bookmark.el), with xwidget's
;;                    handler, so `bookmark-jump' opens them too
;;
;; Both list in a pane at the browser window's left, a tab choosing one:
;; History by day, the most recent first, and bookmarks in the order they
;; were made.  A click opens a page in the shown tab, a middle click in a
;; new one; a right click offers the rest.  Bookmarks also fill the
;; Bookmarks menu, the location toolbar's Bookmarks button and the
;; personal toolbar.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'subr-x)
(require 'lispm-desktop-platinum)
(require 'lispm-browser)

(declare-function xwidget-webkit-uri "xwidget.c" (xwidget))
(declare-function xwidget-webkit-title "xwidget.c" (xwidget))
(declare-function lispm-desktop-popup-menu "lispm-desktop-popup" (items &optional x y align))
(declare-function lispm-desktop-sidebar--toolbar-button "lispm-desktop-sidebar" (label command help row &optional state))

;;;; History

(defcustom lispm-browser-history-file (locate-user-emacs-file "lispm-browser-history.eld")
  "File keeping the pages the browser visited."
  :type 'file
  :group 'lispm-desktop)

(defcustom lispm-browser-history-size 1000
  "How many pages the browser's history keeps, the most recently visited."
  :type 'natnum
  :group 'lispm-desktop)

(defvar lispm-browser--history nil
  "Pages visited, the most recent first: (URL TITLE LAST-VISIT VISITS).
LAST-VISIT is a `float-time'.  Read from `lispm-browser-history-file'
when first wanted.")

(defvar lispm-browser--history-loaded nil
  "Non-nil once the history was read from its file.")

(defvar lispm-browser--history-timer nil
  "Idle timer writing the history to its file after a change.")

(defun lispm-browser--load-history ()
  "Return the history, read from its file the first time."
  (unless lispm-browser--history-loaded
    (setq lispm-browser--history-loaded t
          lispm-browser--history
          (and (file-readable-p lispm-browser-history-file)
               (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents lispm-browser-history-file)
                   (read (current-buffer)))))))
  lispm-browser--history)

(defun lispm-browser--save-history ()
  "Write the history to `lispm-browser-history-file'."
  (setq lispm-browser--history-timer nil)
  (when lispm-browser--history-loaded
    (ignore-errors
      (with-temp-file lispm-browser-history-file
        (let ((print-length nil)
              (print-level nil))
          (insert ";; The pages lispm-desktop's browser visited.  -*- mode: lisp-data -*-\n")
          (prin1 lispm-browser--history (current-buffer))
          (insert "\n"))))))

(defun lispm-browser--history-changed ()
  "Write the history once Emacs is idle, and redraw what lists it."
  (unless lispm-browser--history-timer
    (setq lispm-browser--history-timer
          (run-with-idle-timer 2 nil #'lispm-browser--save-history)))
  (lispm-browser--places-changed))

(defun lispm-browser-history-add (url title)
  "Note that the page at URL, titled TITLE, was visited just now.
Only web and file pages are kept, each once, at its latest visit."
  (when (and (stringp url) (string-match-p "\\`\\(https?\\|file\\|ftp\\):" url))
    (let* ((history (lispm-browser--load-history))
           (old (assoc url history))
           (title (if (string-empty-p (or title "")) (or (nth 1 old) url) title)))
      (setq lispm-browser--history
            (seq-take (cons (list url title (float-time) (1+ (or (nth 3 old) 0)))
                            (delq old history))
                      lispm-browser-history-size))
      (lispm-browser--history-changed))))

(defun lispm-browser-history-remove (url)
  "Forget the visits to the page at URL."
  (setq lispm-browser--history (assoc-delete-all url (lispm-browser--load-history)))
  (lispm-browser--history-changed))

(defun lispm-browser-clear-history ()
  "Forget every page visited, after asking."
  (interactive)
  (when (yes-or-no-p "Forget every page the browser visited? ")
    (lispm-browser--load-history)
    (setq lispm-browser--history nil)
    (lispm-browser--history-changed)))

(defun lispm-browser--note-load (xwidget type)
  "Add the page XWIDGET finished loading to the history.
This follows `xwidget-webkit-callback' with its arguments, XWIDGET and
the event TYPE: xwidget has no hook of its own for a finished load."
  (when (and (eq type 'load-changed)
             (equal (nth 3 last-input-event) "load-finished"))
    (lispm-browser-history-add (ignore-errors (xwidget-webkit-uri xwidget))
                                       (ignore-errors (xwidget-webkit-title xwidget)))))

(defun lispm-browser--history-day (time)
  "Return the heading TIME, a `float-time', is listed under in the History."
  (let ((days (- (time-to-days (current-time)) (time-to-days time))))
    (cond ((<= days 0) "Today")
          ((= days 1) "Yesterday")
          ((< days 7) (format-time-string "%A" time))
          ((< days 14) "Last Week")
          (t "Earlier"))))

;;;; Bookmarks

(defun lispm-browser--bookmark-p (bookmark)
  "Return non-nil when BOOKMARK, a bookmark record, is a web page's."
  (and (bookmark-prop-get bookmark 'page)
       (eq (bookmark-prop-get bookmark 'handler) 'xwidget-webkit-bookmark-jump-handler)))

(defun lispm-browser-bookmarks ()
  "Return the browser's bookmarks, in the order they were made: (NAME . URL)."
  (bookmark-maybe-load-default-file)
  (mapcar (lambda (bookmark)
            (cons (bookmark-name-from-full-record bookmark) (bookmark-prop-get bookmark 'page)))
          (reverse (seq-filter #'lispm-browser--bookmark-p bookmark-alist))))

(defun lispm-browser--bookmark-name (title)
  "Return a name for a bookmark titled TITLE that no bookmark has yet."
  (let ((name (if (string-empty-p title) "Untitled" title))
        (count 1))
    (while (bookmark-get-bookmark name 'noerror)
      (setq count (1+ count)
            name (format "%s <%d>" title count)))
    name))

(defun lispm-browser-add-bookmark ()
  "Bookmark the shown page under its title, as Netscape's Add Bookmark did.
A page already bookmarked is not bookmarked twice."
  (interactive)
  (let* ((buffer (lispm-browser--shown-buffer))
         (url (and buffer (lispm-browser--uri buffer))))
    (unless url
      (user-error "No page is shown"))
    (if (rassoc url (lispm-browser-bookmarks))
        (message "Already bookmarked: %s" url)
      (let ((name (lispm-browser--bookmark-name (lispm-browser--title buffer))))
        (bookmark-store name
                        `((page . ,url)
                          (handler . xwidget-webkit-bookmark-jump-handler)
                          (last-modified . ,(current-time)))
                        nil)
        (message "Bookmarked: %s" name)))
    (lispm-browser--places-changed)))

(defun lispm-browser-delete-bookmark (name)
  "Delete the bookmark NAME."
  (bookmark-delete name)
  (lispm-browser--places-changed))

(defun lispm-browser-rename-bookmark (name)
  "Rename the bookmark NAME, asking for its new name."
  (let ((new (string-trim (read-string (format "Rename “%s” to: " name) name))))
    (unless (or (string-empty-p new) (equal new name))
      (bookmark-rename name new)
      (lispm-browser--places-changed))))

(defun lispm-browser--bookmark-items ()
  "Return the items of the Bookmarks menu: Add Bookmark and Edit Bookmarks,
then a bookmark each, as Netscape's Bookmarks menu had them."
  (let ((bookmarks (lispm-browser-bookmarks)))
    `((:label "Add Bookmark" :action lispm-browser-add-bookmark
              :enabled ,(and (lispm-browser--shown-buffer) t)
              :key ,(lispm-browser--key 'lispm-browser-add-bookmark))
      (:label "Edit Bookmarks…" :action lispm-browser-edit-bookmarks
              :checked ,(eq (lispm-browser--places-shown) 'bookmarks)
              :key ,(lispm-browser--key 'lispm-browser-edit-bookmarks))
      separator
      ,@(if bookmarks
            (mapcar (pcase-lambda (`(,name . ,url))
                      (list :label (truncate-string-to-width name 48 nil nil "…")
                            :action (lambda () (lispm-browser-open-url url))))
                    bookmarks)
          '((:label "No Bookmarks" :action ignore :enabled nil))))))

;;;; The personal toolbar

(defun lispm-browser--ribbon ()
  "Return the bookmark ribbon, one icon wide."
  (propertize " " 'display
              (lispm-browser--image
               '(ribbon)
               (lambda ()
                 (lispm-browser--svg
                  16 16
                  (format "<g transform='scale(0.66)'>%s</g>"
                          (format-spec (alist-get 'bookmarks lispm-browser--icons)
                                       (lispm-browser--ink t))))))))

(defun lispm-browser--personal-toolbar ()
  "Return the personal toolbar, the address window's mode line: a button
per bookmark, as Netscape's personal toolbar held them."
  (let ((bookmarks (lispm-browser-bookmarks)))
    (concat
     (propertize " " 'display '(space :width (8) :height (26) :ascent 70))
     (if bookmarks
         (mapconcat (pcase-lambda (`(,name . ,url))
                      (lispm-desktop-sidebar--toolbar-button
                       (concat " " (lispm-browser--ribbon) " "
                               (truncate-string-to-width name 22 nil nil "…") " ")
                       (lambda () (interactive) (lispm-browser-open-url url))
                       url 'mode-line 'lispm-desktop-platinum-button))
                    bookmarks " ")
       (propertize "Bookmarks you add show here." 'face 'lispm-desktop-platinum-toolbar-label)))))

;;;; The pane

(defconst lispm-browser-places-buffer-name " *Browser Places*"
  "Name of the buffer of the browser's History and Bookmarks pane.")

(defconst lispm-browser-places-width 280
  "Width in pixels of the History and Bookmarks pane.")

(defvar-local lispm-browser--places-view 'bookmarks
  "What the pane lists: `bookmarks' or `history'.")

(defun lispm-browser--places-window ()
  "Return the pane's window in the browser, or nil."
  (get-buffer-window lispm-browser-places-buffer-name
                     (and (lispm-browser-floating-p) lispm-browser--frame)))

(defun lispm-browser--places-shown ()
  "Return what the pane lists while it is shown, `bookmarks' or `history'."
  (when-let* ((window (lispm-browser--places-window)))
    (buffer-local-value 'lispm-browser--places-view (window-buffer window))))

(defvar-keymap lispm-browser-places-tab-map
  :doc "Keymap of a tab of the pane."
  "<tab-line> <down-mouse-1>" #'ignore
  "<tab-line> <mouse-1>" #'lispm-browser-places-tab-click)

(defun lispm-browser-places-tab-click (event)
  "Show the list whose tab EVENT clicked."
  (interactive "e")
  (let ((position (event-start event)))
    (when-let* ((view (get-text-property (cdr (posn-string position)) 'lispm-browser-view
                                         (car (posn-string position)))))
      (with-current-buffer (window-buffer (posn-window position))
        (setq lispm-browser--places-view view)
        (lispm-browser--render-places)))))

(defun lispm-browser--places-tab (view label)
  "Return the pane's tab for VIEW named LABEL, in front when shown, as
`lispm-desktop-platinum-tabs' takes it."
  (list label (eq view lispm-browser--places-view)
        'lispm-browser-view view 'keymap lispm-browser-places-tab-map
        'pointer 'arrow 'help-echo (format "Show the %s" label)))

(defun lispm-browser--places-tabs ()
  "Return the pane's tab line: a tab each for Bookmarks and History, and a
button closing the pane."
  (let ((close (lispm-desktop-sidebar--toolbar-button "✕" #'lispm-browser-hide-places
                                                      "Close the pane" 'tab-line)))
    (concat (lispm-desktop-platinum-tabs
             (list (lispm-browser--places-tab 'bookmarks "Bookmarks")
                   (lispm-browser--places-tab 'history "History"))
             (- (window-pixel-width) (window-right-divider-width) (string-pixel-width close) 6))
            (propertize " " 'display '(space :width (3)))
            close)))

(defun lispm-browser--place-line (url text &rest properties)
  "Return a pane row for the page at URL showing TEXT, with PROPERTIES."
  (apply #'propertize (concat text "\n")
         'lispm-browser-url url 'mouse-face 'highlight 'help-echo url
         properties))

(defun lispm-browser--places-count (count noun)
  "Return COUNT NOUNs in words."
  (format "%d %s%s" count noun (if (= count 1) "" "s")))

(defun lispm-browser--render-places ()
  "List the bookmarks or the history in the pane's buffer."
  (when-let* ((buffer (get-buffer lispm-browser-places-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (pcase lispm-browser--places-view
          ('bookmarks
           (let ((bookmarks (lispm-browser-bookmarks)))
             (dolist (bookmark bookmarks)
               (insert (lispm-browser--place-line (cdr bookmark)
                                                          (concat " " (lispm-browser--ribbon) " " (car bookmark))
                                                          'lispm-browser-bookmark (car bookmark))))
             (unless bookmarks
               (insert (propertize "\n  No bookmarks yet: Bookmarks › Add Bookmark\n  keeps the page shown.\n"
                                   'face 'shadow)))
             (setq lispm-desktop-platinum-info (lispm-browser--places-count (length bookmarks) "bookmark"))))
          (_
           (let ((history (lispm-browser--load-history))
                 (heading nil))
             (dolist (entry history)
               (pcase-let ((`(,url ,title ,time) entry))
                 (let ((day (lispm-browser--history-day time)))
                   (unless (equal day heading)
                     (setq heading day)
                     (insert (propertize (concat " " day "\n") 'face 'bold)))
                   (insert (lispm-browser--place-line
                            url (concat "   " (or title url)
                                        (propertize (format-time-string "  %H:%M" time)
                                                    'face 'shadow)))))))
             (unless history
               (insert (propertize "\n  No pages visited yet.\n" 'face 'shadow)))
             (setq lispm-desktop-platinum-info (lispm-browser--places-count (length history) "page")))))
        (goto-char (point-min))
        (forward-line (1- line))
        (force-mode-line-update)))))

(defun lispm-browser--places-changed ()
  "Redraw what lists the bookmarks or the history: the pane, the personal
toolbar."
  (lispm-browser--render-places)
  (when-let* ((buffer (get-buffer lispm-browser-address-buffer-name)))
    (with-current-buffer buffer
      (force-mode-line-update))))

(defun lispm-browser--place-at (&optional position)
  "Return the address of the pane row at POSITION, by default point."
  (get-text-property (or position (point)) 'lispm-browser-url))

(defun lispm-browser-places-open (&optional new-tab)
  "Open the page of the row at point, in a new tab when NEW-TAB."
  (interactive "P")
  (when-let* ((url (lispm-browser--place-at)))
    (lispm-browser-open-url url new-tab)))

(defun lispm-browser-places-open-new-tab ()
  "Open the page of the row at point in a new tab."
  (interactive)
  (lispm-browser-places-open t))

(defun lispm-browser-places-click (event)
  "Open the page of the row EVENT clicked; a middle click opens a new tab."
  (interactive "e")
  (let ((position (event-start event)))
    (when-let* ((point (posn-point position)))
      (with-selected-window (posn-window position)
        (goto-char point)
        (lispm-browser-places-open (eq (event-basic-type event) 'mouse-2))))))

(defun lispm-browser-places-delete ()
  "Delete the bookmark, or forget the page, of the row at point."
  (interactive)
  (when-let* ((url (lispm-browser--place-at)))
    (if-let* ((name (get-text-property (point) 'lispm-browser-bookmark)))
        (lispm-browser-delete-bookmark name)
      (lispm-browser-history-remove url))))

(defun lispm-browser-places-rename ()
  "Rename the bookmark of the row at point."
  (interactive)
  (if-let* ((name (get-text-property (point) 'lispm-browser-bookmark)))
      (lispm-browser-rename-bookmark name)
    (user-error "Only a bookmark can be renamed")))

(defun lispm-browser-places-context-menu (event)
  "Pop up what can be done with the row EVENT clicked."
  (interactive "e")
  (let ((position (event-start event)))
    (with-selected-window (posn-window position)
      (when (posn-point position)
        (goto-char (posn-point position)))
      (when-let* ((url (lispm-browser--place-at)))
        (let ((bookmark (get-text-property (point) 'lispm-browser-bookmark)))
          (lispm-desktop-popup-menu
           `((:label "Open" :action lispm-browser-places-open)
             (:label "Open in New Tab" :action lispm-browser-places-open-new-tab)
             separator
             (:label "Copy Address" :action ,(lambda () (kill-new url) (message "Copied %s" url)))
             ,@(if bookmark
                   '((:label "Rename…" :action lispm-browser-places-rename)
                     (:label "Delete Bookmark" :action lispm-browser-places-delete))
                 '((:label "Forget Page" :action lispm-browser-places-delete)
                   separator
                   (:label "Clear History…" :action lispm-browser-clear-history))))))))))

(defun lispm-browser-places-switch ()
  "Show the other list, bookmarks or history."
  (interactive)
  (setq lispm-browser--places-view (if (eq lispm-browser--places-view 'bookmarks) 'history 'bookmarks))
  (lispm-browser--render-places))

(defvar-keymap lispm-browser-places-mode-map
  :doc "Keymap of the browser's History and Bookmarks pane."
  "RET" #'lispm-browser-places-open
  "M-RET" #'lispm-browser-places-open-new-tab
  "<mouse-1>" #'lispm-browser-places-click
  "<mouse-2>" #'lispm-browser-places-click
  "<mouse-3>" #'lispm-browser-places-context-menu
  "d" #'lispm-browser-places-delete
  "DEL" #'lispm-browser-places-delete
  "<delete>" #'lispm-browser-places-delete
  "r" #'lispm-browser-places-rename
  "g" #'lispm-browser--render-places
  "TAB" #'lispm-browser-places-switch
  "n" #'next-line
  "p" #'previous-line
  "q" #'lispm-browser-hide-places)

(define-derived-mode lispm-browser-places-mode special-mode "Places"
  "Major mode of the browser's History and Bookmarks pane.
\\{lispm-browser-places-mode-map}"
  (setq-local tab-line-format '(:eval (lispm-browser--places-tabs))
              ;; A window growing gives its width to the page, not the pane.
              window-size-fixed 'width
              header-line-format nil
              truncate-lines t
              cursor-type nil
              lispm-desktop-platinum-title "Bookmarks")
  (visual-line-mode -1)
  (setq-local truncate-lines t)
  (face-remap-add-relative 'default 'lispm-desktop-platinum-list)
  (hl-line-mode 1)
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1)))

(defun lispm-browser--places-buffer ()
  "Return the pane's buffer, made when missing."
  (or (get-buffer lispm-browser-places-buffer-name)
      (with-current-buffer (get-buffer-create lispm-browser-places-buffer-name)
        (lispm-browser-places-mode)
        (current-buffer))))

(defun lispm-browser--show-places (view)
  "Show the pane listing VIEW, `bookmarks' or `history', at the browser
window's left, the browser shown first when it is not.  Asked for from
the keyboard, the pane takes the keyboard, so its keys work at once."
  (unless (lispm-browser--window)
    (lispm-browser-show))
  (with-current-buffer (lispm-browser--places-buffer)
    (setq lispm-browser--places-view view)
    (lispm-browser--render-places))
  (unless (lispm-browser--places-window)
    (when-let* ((page (lispm-browser--window)))
      (let ((window (split-window page (- lispm-browser-places-width) 'left t)))
        (set-window-buffer window (lispm-browser--places-buffer))
        (set-window-dedicated-p window t)
        (set-window-parameter window 'lispm-desktop-chrome t)
        (set-window-parameter window 'no-other-window t))))
  (when (and (lispm-desktop-typed-event-p last-input-event) (lispm-browser--places-window))
    (select-window (lispm-browser--places-window))))

(defun lispm-browser-hide-places ()
  "Close the History and Bookmarks pane; the page takes the keyboard back."
  (interactive)
  (when-let* ((window (lispm-browser--places-window)))
    (let ((selected (eq window (selected-window))))
      (delete-window window)
      (when (and selected (lispm-browser--window))
        (select-window (lispm-browser--window))))))

(defun lispm-browser-show-history ()
  "Show the pages visited in the pane, or close the pane when it shows them."
  (interactive)
  (if (eq (lispm-browser--places-shown) 'history)
      (lispm-browser-hide-places)
    (lispm-browser--show-places 'history)))

(defun lispm-browser-edit-bookmarks ()
  "Show the bookmarks in the pane, where they are opened, renamed and
deleted, or close the pane when it shows them."
  (interactive)
  (if (eq (lispm-browser--places-shown) 'bookmarks)
      (lispm-browser-hide-places)
    (lispm-browser--show-places 'bookmarks)))

(defun lispm-desktop-setup-browser-places ()
  "Keep the browser's history as pages load, and write it when Emacs quits."
  (advice-add 'xwidget-webkit-callback :after #'lispm-browser--note-load)
  (add-hook 'kill-emacs-hook #'lispm-browser--save-history))

(provide 'lispm-browser-places)
;;; lispm-browser-places.el ends here
