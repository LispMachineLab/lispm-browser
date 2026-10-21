;;; lispm-browser-proxy.el --- The proxy the pages load through  -*- lexical-binding: t; -*-

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

;; The browser's pages can load through a proxy, an HTTP one or a SOCKS5
;; one:
;;
;;   (lispm-browser-set-proxy "socks5://127.0.0.1:7890")
;;
;; WebKit, not Emacs, makes the pages' connections, so neither url.el's
;; proxy nor the environment's http_proxy reaches them.  WebKit takes a
;; proxy per website data store, the one Emacs's page views share, on
;; macOS 14 and later; the module of lispm-browser-extensions.el hands it
;; over, and is built for that when it is missing.  Elsewhere the pages
;; connect directly.
;;
;; LispM Desktop sets it to the proxy every connection of LispM goes
;; through.

;;; Code:

(require 'subr-x)
(require 'lispm-browser-extensions)

(declare-function lispm-browser-webext-module-proxy "lispm-browser-webext-module"
                  (kind host port exceptions))

(defun lispm-browser-proxy--customize (symbol value)
  "Set SYMBOL to VALUE, and make the pages follow, as Customize does."
  (set-default symbol value)
  (lispm-browser-proxy-follow))

(defcustom lispm-browser-proxy nil
  "The proxy the pages load through, or nil to connect directly.
A URL: http://HOST:PORT for an HTTP proxy, which HTTPS goes through
with CONNECT, or socks5://HOST:PORT for a SOCKS5 one.  Set it with
`lispm-browser-set-proxy' or Customize."
  :type '(choice (const :tag "None" nil) (string :tag "URL"))
  :initialize #'custom-initialize-default
  :set #'lispm-browser-proxy--customize
  :group 'lispm-browser)

(defcustom lispm-browser-proxy-exceptions '("localhost" "127.0.0.1" "::1")
  "Hosts the pages reach directly, not through `lispm-browser-proxy'."
  :type '(repeat string)
  :initialize #'custom-initialize-default
  :set #'lispm-browser-proxy--customize
  :group 'lispm-browser)

(defvar lispm-browser-proxy--followed nil
  "What the module was last handed, as (PROXY . EXCEPTIONS); nil before
it was handed anything, the pages connecting directly.")

(defun lispm-browser-proxy-parse (url)
  "Return the proxy at URL as (KIND HOST PORT), KIND \"http\" or
\"socks5\", or nil when URL names none.  socks5h:// is socks5://: a
SOCKS5 proxy of WebKit's always looks the names up."
  (when (and url
             (string-match (rx bos (group (or "http" "socks5" "socks5h")) "://"
                               (or (seq "[" (group (+ (not (any "]")))) "]")
                                   (group (+ (not (any ":/[]")))))
                               ":" (group (+ digit)) (? "/") eos)
                           url))
    (let ((port (string-to-number (match-string 4 url))))
      (when (<= 1 port 65535)
        (list (if (string-prefix-p "socks" (match-string 1 url)) "socks5" "http")
              (or (match-string 2 url) (match-string 3 url))
              port)))))

(defun lispm-browser-proxy--hand-over ()
  "Hand the module `lispm-browser-proxy'; return non-nil once the pages
follow it.  A module built before it took proxies cannot."
  (when (fboundp 'lispm-browser-webext-module-proxy)
    (pcase-let ((`(,kind ,host ,port) (lispm-browser-proxy-parse lispm-browser-proxy)))
      (lispm-browser-webext-module-proxy (or kind "none") (or host "") (or port 0)
                                         (string-join lispm-browser-proxy-exceptions ",")))
    (setq lispm-browser-proxy--followed (cons lispm-browser-proxy lispm-browser-proxy-exceptions))
    t))

(defun lispm-browser-proxy-follow ()
  "Make the pages load through `lispm-browser-proxy': at once when the
module is loaded, else once it is, built first when need be.  With no
proxy and no module, nothing is to do: WebKit connects directly."
  (cond ((lispm-browser-extensions-module-loaded-p) (lispm-browser-proxy--hand-over))
        (lispm-browser-proxy (lispm-browser-extensions-with-module #'lispm-browser-proxy--hand-over))))

(defun lispm-browser-proxy-followed-p ()
  "Return non-nil when the pages load through `lispm-browser-proxy', or
directly when it is nil."
  (if lispm-browser-proxy--followed
      (equal lispm-browser-proxy--followed (cons lispm-browser-proxy lispm-browser-proxy-exceptions))
    (null lispm-browser-proxy)))

;;;###autoload
(defun lispm-browser-set-proxy (url &optional exceptions)
  "Make the pages load through the proxy at URL, or directly when URL is nil.
URL is http://HOST:PORT or socks5://HOST:PORT, see `lispm-browser-proxy'.
EXCEPTIONS, when given, are the hosts reached directly instead of
`lispm-browser-proxy-exceptions'.  Pages follow it from their next
connection; where the module must be built first, once it is."
  (interactive (list (let ((url (string-trim (read-string "Proxy (http:// or socks5://, empty for none): "
                                                          lispm-browser-proxy))))
                       (unless (string-empty-p url)
                         (unless (lispm-browser-proxy-parse url)
                           (user-error "Write the proxy as http://HOST:PORT or socks5://HOST:PORT"))
                         url))))
  (setq lispm-browser-proxy url)
  (when exceptions
    (setq lispm-browser-proxy-exceptions exceptions))
  (lispm-browser-proxy-follow))

(provide 'lispm-browser-proxy)
;;; lispm-browser-proxy.el ends here
