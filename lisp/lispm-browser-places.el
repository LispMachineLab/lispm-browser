;;; lispm-browser-places.el --- The browser's history and bookmarks  -*- lexical-binding: t; -*-

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

;; What the browser remembers, as Netscape Communicator remembered it: the
;; pages visited, its History, and the pages kept, its bookmarks.
;;
;;   page --finished loading--> history, a file of its own
;;   Add Bookmark --> Emacs's own bookmarks (bookmark.el), with xwidget's
;;                    handler, so `bookmark-jump' opens them too
;;
;; Opening an address (C-l) completes from both; M-b opens a bookmark and
;; M-y a page visited.  What lists them is told of every change through
;; `lispm-browser-places-changed-hook'.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'subr-x)
(require 'lispm-browser)

(declare-function xwidget-webkit-uri "xwidget.c" (xwidget))
(declare-function xwidget-webkit-title "xwidget.c" (xwidget))

(defvar lispm-browser-places-changed-hook nil
  "Hook run when the history or the bookmarks changed.")

(defun lispm-browser--places-changed ()
  "Tell what lists the history or the bookmarks that they changed."
  (run-hooks 'lispm-browser-places-changed-hook))

;;;; History

(defcustom lispm-browser-history-file (locate-user-emacs-file "lispm-browser-history.eld")
  "File keeping the pages the browser visited."
  :type 'file
  :group 'lispm-browser)

(defcustom lispm-browser-history-size 1000
  "How many pages the browser's history keeps, the most recently visited."
  :type 'natnum
  :group 'lispm-browser)

(defvar lispm-browser--history nil
  "Pages visited, the most recent first: (URL TITLE LAST-VISIT VISITS).
LAST-VISIT is a `float-time'.  Read from `lispm-browser-history-file'
when first wanted.")

(defvar lispm-browser--history-loaded nil
  "Non-nil once the history was read from its file.")

(defvar lispm-browser--history-timer nil
  "Idle timer writing the history to its file after a change.")

(defun lispm-browser-history ()
  "Return the pages visited, the most recent first: (URL TITLE LAST-VISIT
VISITS), LAST-VISIT a `float-time'.  The history is read from its file
the first time."
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
          (insert ";; The pages lispm-browser visited.  -*- mode: lisp-data -*-\n")
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
    (let* ((history (lispm-browser-history))
           (old (assoc url history))
           (title (if (string-empty-p (or title "")) (or (nth 1 old) url) title)))
      (setq lispm-browser--history
            (seq-take (cons (list url title (float-time) (1+ (or (nth 3 old) 0)))
                            (delq old history))
                      lispm-browser-history-size))
      (lispm-browser--history-changed))))

(defun lispm-browser-history-remove (url)
  "Forget the visits to the page at URL."
  (setq lispm-browser--history (assoc-delete-all url (lispm-browser-history)))
  (lispm-browser--history-changed))

(defun lispm-browser-clear-history ()
  "Forget every page visited, after asking."
  (interactive)
  (when (yes-or-no-p "Forget every page the browser visited? ")
    (lispm-browser-history)
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

(defun lispm-browser-history-day (time)
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
  (let* ((buffer (lispm-browser-shown-buffer))
         (url (and buffer (lispm-browser-uri buffer))))
    (unless url
      (user-error "No page is shown"))
    (if (rassoc url (lispm-browser-bookmarks))
        (message "Already bookmarked: %s" url)
      (let ((name (lispm-browser--bookmark-name (lispm-browser-title buffer))))
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

;;;; Opening them

(defvar lispm-browser--location-history nil
  "Addresses typed to `lispm-browser-open-location', for the minibuffer.")

(defun lispm-browser-open-location (input)
  "Visit INPUT, an address or words to search for, in the shown tab.
The addresses of the pages visited and bookmarked complete it."
  (interactive
   (list (completing-read "Open location: "
                          (delete-dups (append (mapcar #'cdr (lispm-browser-bookmarks))
                                               (mapcar #'car (lispm-browser-history))))
                          nil nil (lispm-browser-uri) 'lispm-browser--location-history)))
  (unless (string-empty-p (string-trim input))
    (lispm-browser-open-url (lispm-browser-input-url (string-trim input)))))

(defun lispm-browser-open-bookmark (name)
  "Open the page of the bookmark NAME in the shown tab."
  (interactive
   (let ((bookmarks (lispm-browser-bookmarks)))
     (unless bookmarks
       (user-error "No bookmarks yet: M-d bookmarks the page shown"))
     (list (completing-read "Bookmark: " bookmarks nil t))))
  (when-let* ((url (cdr (assoc name (lispm-browser-bookmarks)))))
    (lispm-browser-open-url url)))

(defun lispm-browser-open-from-history (url)
  "Open URL, a page visited, in the shown tab."
  (interactive
   (let ((history (lispm-browser-history)))
     (unless history
       (user-error "No pages visited yet"))
     (let ((pages (mapcar (pcase-lambda (`(,url ,title . ,_))
                            (cons (format "%s  %s" (or title url) (propertize url 'face 'shadow)) url))
                          history)))
       (list (cdr (assoc (completing-read "Visited: " pages nil t) pages))))))
  (when url
    (lispm-browser-open-url url)))

(defun lispm-browser-places-setup ()
  "Keep the browser's history as pages load, and write it when Emacs quits."
  (advice-add 'xwidget-webkit-callback :after #'lispm-browser--note-load)
  (add-hook 'kill-emacs-hook #'lispm-browser--save-history))

(provide 'lispm-browser-places)
;;; lispm-browser-places.el ends here
