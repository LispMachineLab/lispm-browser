;;; lispm-browser-hints.el --- Pages followed and typed in from the keyboard  -*- lexical-binding: t; -*-

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

;; The browser's pages are used from the keyboard as Vimium uses them.
;; On a page, f labels every link, button and field in sight with a few
;; letters; typing a label's letters follows the link, presses the button
;; or puts the caret in the field.  F opens the link in a new tab instead,
;; and i goes straight to the page's first field.
;;
;; Emacs on macOS cannot hand keys to a page: `xwidget-perform-lispy-event'
;; does nothing there.  So a field is typed in through JavaScript, while
;; `lispm-browser-typing-mode' is on: characters are inserted at the caret,
;; and Emacs's own keys move the caret and delete, as in a buffer.  Return
;; submits, Tab goes to the next field, Escape leaves the field.
;;
;;   f --script--> labels drawn on the page --letters--> element
;;       link: followed   button: pressed   field: typing mode

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'lispm-browser)

(declare-function xwidget-at "xwidget" (pos))
(defvar xwidget-webkit-mode-map)

(defgroup lispm-browser-hints nil
  "Following links and typing in pages from the keyboard."
  :group 'lispm-browser)

(defcustom lispm-browser-hint-characters "sadfjklewcmpgh"
  "The letters labels are made of, the easiest to type first."
  :type 'string
  :group 'lispm-browser-hints)

;;;; The page's side

(defconst lispm-browser--hints-script
  "(function () {
  if (window.__lme) return;
  var L = window.__lme = {els: [], rects: [], box: null};
  var FIELD = /^(text|search|email|url|tel|password|number|date|datetime-local|month|week|time|)$/;
  var CLICKABLE = 'a[href], button, input:not([type=hidden]), textarea, select, summary, ' +
    '[role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], ' +
    '[role=option], [onclick], [contenteditable=\"\"], [contenteditable=true], ' +
    '[tabindex]:not([tabindex=\"-1\"])';
  L.kind = function (el) {
    var tag = el.tagName;
    if (tag === 'TEXTAREA' || el.isContentEditable) return 'field';
    if (tag === 'INPUT')
      return FIELD.test((el.getAttribute('type') || '').toLowerCase()) ? 'field' : 'button';
    if (tag === 'SELECT') return 'select';
    if (tag === 'A' && el.href) return 'link';
    return 'button';
  };
  L.visible = function (el) {
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.right < 0 ||
        r.top > innerHeight || r.left > innerWidth) return null;
    var style = getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none' || +style.opacity === 0)
      return null;
    var x = Math.min(Math.max(r.left + Math.min(r.width / 2, 12), 0), innerWidth - 1);
    var y = Math.min(Math.max(r.top + r.height / 2, 0), innerHeight - 1);
    var hit = document.elementFromPoint(x, y);
    if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) return null;
    return r;
  };
  L.clear = function () { if (L.box) { L.box.remove(); L.box = null; } };
  L.collect = function () {
    L.clear(); L.els = []; L.rects = [];
    document.querySelectorAll(CLICKABLE).forEach(function (el) {
      if (el.disabled) return;
      var r = L.visible(el);
      if (r) { L.els.push(el); L.rects.push(r); }
    });
    return JSON.stringify(L.els.map(function (el) { return L.kind(el); }));
  };
  L.show = function (labels) {
    L.clear();
    var box = L.box = document.createElement('div');
    box.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647';
    labels.forEach(function (label, i) {
      var r = L.rects[i], hint = document.createElement('span');
      hint.dataset.label = label;
      hint.textContent = label.toUpperCase();
      hint.style.cssText = 'position:fixed;left:' + Math.max(r.left - 3, 0) + 'px;top:' +
        Math.max(r.top - 3, 0) + 'px;margin:0;padding:0 3px;font:bold 11px/13px Geneva,' +
        'Helvetica,sans-serif;letter-spacing:0;text-transform:none;color:#000;' +
        'background:#ffffcc;border:1px solid #000;border-radius:2px;box-shadow:1px 1px 0 #777';
      box.appendChild(hint);
    });
    (document.body || document.documentElement).appendChild(box);
  };
  L.filter = function (typed) {
    if (!L.box) return;
    L.box.childNodes.forEach(function (hint) {
      var label = hint.dataset.label;
      hint.style.display = label.indexOf(typed) === 0 ? '' : 'none';
      hint.textContent = '';
      var done = document.createElement('span');
      done.style.color = '#999';
      done.textContent = label.slice(0, typed.length).toUpperCase();
      hint.appendChild(done);
      hint.appendChild(document.createTextNode(label.slice(typed.length).toUpperCase()));
    });
  };
  L.caretToEnd = function (el) {
    try { var n = el.value.length; el.setSelectionRange(n, n); } catch (e) {}
  };
  L.follow = function (i, newTab) {
    var el = L.els[i];
    L.clear();
    if (!el) return 'none';
    var kind = L.kind(el);
    if (kind === 'field' || kind === 'select') {
      el.focus();
      if (kind === 'field') L.caretToEnd(el);
      return kind;
    }
    if (kind === 'link' && newTab) return 'open ' + el.href;
    if (kind === 'link' && el.target && el.target !== '_self') {
      location.href = el.href;
      return kind;
    }
    if (el.focus) el.focus();
    el.click();
    return kind;
  };
  L.firstField = function () {
    var fields = Array.prototype.filter.call(
      document.querySelectorAll('input, textarea, [contenteditable=\"\"], [contenteditable=true]'),
      function (el) { return !el.disabled && L.kind(el) === 'field' && L.visible(el); });
    if (!fields.length) return 'none';
    fields[0].focus();
    L.caretToEnd(fields[0]);
    return 'field';
  };
  L.focused = function () {
    var el = document.activeElement;
    return el && el !== document.body ? L.kind(el) : 'none';
  };
  L.insert = function (text) {
    var field = document.activeElement;
    try {
      if (field && typeof field.setRangeText === 'function') {
        field.setRangeText(text, field.selectionStart, field.selectionEnd, 'end');
        field.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText',
                                                     data: text}));
        return;
      }
    } catch (e) {}
    document.execCommand('insertText', false, text);
  };
  L.move = function (direction, unit) { getSelection().modify('move', direction, unit); };
  L.kill = function (direction, unit) {
    var field = document.activeElement, selection = getSelection();
    if (selection.isCollapsed) selection.modify('extend', direction, unit);
    // A text field deletes through setRangeText: execCommand deletes
    // nothing in one.
    try {
      if (field && typeof field.setRangeText === 'function') {
        var start = field.selectionStart, end = field.selectionEnd;
        if (start !== end) {
          field.setRangeText('', start, end, 'start');
          field.dispatchEvent(new InputEvent('input', {bubbles: true, inputType:
            direction === 'backward' ? 'deleteContentBackward' : 'deleteContentForward'}));
        }
        return;
      }
    } catch (e) {}
    if (!selection.isCollapsed) document.execCommand('delete');
  };
  L.enter = function () {
    var el = document.activeElement;
    if (!el || el === document.body) return 'none';
    var kind = L.kind(el);
    if (el.tagName === 'TEXTAREA') { L.insert('\\n'); return kind; }
    if (el.isContentEditable) { document.execCommand('insertLineBreak'); return kind; }
    if (kind !== 'field') { el.click(); return kind; }
    var key = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
               bubbles: true, cancelable: true};
    var go = el.dispatchEvent(new KeyboardEvent('keydown', key));
    el.dispatchEvent(new KeyboardEvent('keypress', key));
    el.dispatchEvent(new KeyboardEvent('keyup', key));
    if (go && el.form) {
      if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
    }
    return 'submitted';
  };
  L.step = function (n) {
    var all = Array.prototype.filter.call(document.querySelectorAll(CLICKABLE), function (el) {
      return !el.disabled && el.getClientRects().length;
    });
    if (!all.length) return 'none';
    var i = all.indexOf(document.activeElement);
    var next = all[i < 0 ? (n > 0 ? 0 : all.length - 1) : (i + n + all.length) % all.length];
    next.focus();
    if (L.kind(next) === 'field') L.caretToEnd(next);
    next.scrollIntoView({block: 'nearest'});
    return L.kind(next);
  };
  L.choose = function (n) {
    var el = document.activeElement;
    if (!el || el.tagName !== 'SELECT') return;
    el.selectedIndex = Math.max(0, Math.min(el.options.length - 1, el.selectedIndex + n));
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  };
  L.blur = function () {
    var el = document.activeElement;
    if (el && el.blur) el.blur();
  };
})();
"
  "Script giving the page `window.__lme', the functions hints and typing call.
It defines them once per document; every call to the page sends it first.")

(defun lispm-browser--page-xwidget ()
  "Return the xwidget of the page the browser shows, or nil."
  (when-let* ((window (lispm-browser-window)))
    (with-current-buffer (window-buffer window)
      (xwidget-at (point-min)))))

(defun lispm-browser--page-call (call &optional callback)
  "Evaluate CALL, a JavaScript expression using `__lme', in the shown page.
CALLBACK, when given, is called with its value."
  (when-let* ((xwidget (lispm-browser--page-xwidget)))
    (lispm-browser-run-script xwidget (concat lispm-browser--hints-script call) callback)))

(defun lispm-browser--js (value)
  "Return VALUE written as a JavaScript literal."
  (json-encode value))

(defun lispm-browser--typing (arg)
  "Turn `lispm-browser-typing-mode' on in the shown page when ARG is
positive, else off.  Answers from the page come in whatever buffer is
current, so the page's own buffer is named."
  (when-let* ((window (lispm-browser-window)))
    (with-current-buffer (window-buffer window)
      (lispm-browser-typing-mode arg))))

(defun lispm-browser--set-note (note)
  "Show NOTE in the browser's status bar instead of its page's state."
  (when-let* ((window (lispm-browser-window)))
    (with-current-buffer (window-buffer window)
      (setq lispm-browser-status-note note))
    (force-mode-line-update t)))

(defun lispm-browser--clipboard-text ()
  "Return the text last killed or copied, from the system's clipboard
when `interprogram-paste-function' reads it, or nil."
  (ignore-errors (current-kill 0 t)))

(defvar lispm-browser-clipboard-function #'lispm-browser--clipboard-text
  "Function returning the text pasting in a page's field inserts, or nil.")

;;;; Hints

(defun lispm-browser-hint-labels (count)
  "Return COUNT labels made of `lispm-browser-hint-characters'.
All are as long, so none is the beginning of another."
  (let* ((letters (string-to-list lispm-browser-hint-characters))
         (base (length letters))
         (width (max 1 (cl-loop for width from 1
                                when (>= (expt base width) count) return width))))
    (cl-loop for n below count
             collect (let ((label nil) (rest n))
                       (dotimes (_ width)
                         (push (nth (% rest base) letters) label)
                         (setq rest (/ rest base)))
                       (concat label)))))

(defvar lispm-browser--hints nil
  "The hints drawn on the page: (LABELS TYPED NEW-TAB), or nil.")

(defvar lispm-browser--hints-exit nil
  "The function taking away the keymap held while hints are drawn, or nil.")

(defun lispm-browser--hints-end (&optional keep-page)
  "Take the hints off the page, and their keymap away, at once: a keymap
left until the next key would take that key for a hint's letter.
KEEP-PAGE leaves the page alone, as following a hint clears it itself."
  (let ((exit lispm-browser--hints-exit))
    (setq lispm-browser--hints-exit nil)
    (when lispm-browser--hints
      (setq lispm-browser--hints nil)
      (lispm-browser--set-note nil)
      (unless keep-page
        (lispm-browser--page-call "__lme.clear()")))
    (when exit (funcall exit))))

(defun lispm-browser--followed (result)
  "Act on RESULT, what following a hint did in the page."
  (cond ((not (stringp result)))
        ((string-prefix-p "open " result)
         (lispm-browser-new-tab (substring result 5)))
        ((member result '("field" "select"))
         (lispm-browser--typing 1))))

(defun lispm-browser--hint-key ()
  "Narrow the hints by the letter just typed, and follow the one it names."
  (interactive)
  (pcase-let* ((`(,labels ,typed ,new-tab) lispm-browser--hints)
               (typed (concat typed (string (downcase last-command-event))))
               (matches (seq-filter (lambda (label) (string-prefix-p typed label)) labels)))
    (cond ((null matches) (ding))
          ((and (null (cdr matches)) (equal (car matches) typed))
           (lispm-browser--hints-end t)
           (lispm-browser--page-call (format "__lme.follow(%d, %s)"
                                             (seq-position labels typed)
                                             (if new-tab "true" "false"))
                                     #'lispm-browser--followed))
          (t (setf (nth 1 lispm-browser--hints) typed)
             (lispm-browser--page-call (format "__lme.filter(%s)" (lispm-browser--js typed)))))))

(defun lispm-browser--hint-back ()
  "Take back the last letter typed for a hint."
  (interactive)
  (let ((typed (nth 1 lispm-browser--hints)))
    (when (> (length typed) 0)
      (setf (nth 1 lispm-browser--hints) (substring typed 0 -1))
      (lispm-browser--page-call (format "__lme.filter(%s)"
                                        (lispm-browser--js (nth 1 lispm-browser--hints)))))))

(defun lispm-browser--hint-map ()
  "Return the keymap held while hints are on the page: their letters, and
Delete to take one back.  Any other key, Escape and C-g among them,
takes the hints away."
  (let ((map (make-sparse-keymap)))
    (dolist (char (string-to-list lispm-browser-hint-characters))
      (define-key map (vector char) #'lispm-browser--hint-key)
      (define-key map (vector (upcase char)) #'lispm-browser--hint-key))
    (define-key map (kbd "DEL") #'lispm-browser--hint-back)
    (define-key map (kbd "<escape>") #'ignore)
    (define-key map (kbd "C-g") #'ignore)
    map))

(defun lispm-browser--show-hints (new-tab kinds)
  "Draw a label on each of KINDS' elements, then read their letters.
NEW-TAB opens the link chosen in a new tab."
  (let* ((kinds (and (stringp kinds) (ignore-errors (json-parse-string kinds))))
         (labels (lispm-browser-hint-labels (length kinds))))
    (if (null labels)
        (message "Nothing to follow in sight")
      (setq lispm-browser--hints (list labels "" new-tab))
      (lispm-browser--page-call (format "__lme.show(%s)" (lispm-browser--js (vconcat labels))))
      (lispm-browser--set-note (if new-tab "Type a link's letters to open it in a new tab"
                                 "Type the letters of a link, button or field"))
      (setq lispm-browser--hints-exit
            (set-transient-map (lispm-browser--hint-map)
                               (lambda ()
                                 (and lispm-browser--hints
                                      (memq this-command '(lispm-browser--hint-key
                                                           lispm-browser--hint-back))))
                               #'lispm-browser--hints-end)))))

(defun lispm-browser-follow-hint (&optional new-tab)
  "Label the links, buttons and fields in sight, and follow the one whose
letters are typed then.  NEW-TAB, given by \\[lispm-browser-follow-hint-new-tab],
opens a link in a new tab."
  (interactive)
  (unless (lispm-browser--page-xwidget)
    (user-error "No page is shown"))
  (lispm-browser--hints-end)
  (lispm-browser--typing -1)
  (lispm-browser--page-call "__lme.collect()"
                            (lambda (kinds) (lispm-browser--show-hints new-tab kinds))))

(defun lispm-browser-follow-hint-new-tab ()
  "Label the links in sight, and open the one whose letters are typed in a
new tab."
  (interactive)
  (lispm-browser-follow-hint t))

(defun lispm-browser-first-field ()
  "Put the caret in the page's first field in sight, to type in it."
  (interactive)
  (lispm-browser--page-call "__lme.firstField()"
                            (lambda (result)
                              (if (equal result "field")
                                  (lispm-browser--typing 1)
                                (message "No field in sight")))))

;;;; Typing in a field

(defun lispm-browser--type (call)
  "Run CALL, a JavaScript expression using `__lme', in the page's field."
  (lispm-browser--page-call call))

(defun lispm-browser-type-char ()
  "Insert the character typed at the caret of the page's field."
  (interactive)
  (when (characterp last-command-event)
    (lispm-browser--type (format "__lme.insert(%s)"
                                 (lispm-browser--js (string last-command-event))))))

(defun lispm-browser-type-paste ()
  "Paste the clipboard at the caret of the page's field."
  (interactive)
  (when-let* ((text (funcall lispm-browser-clipboard-function)))
    (lispm-browser--type (format "__lme.insert(%s)" (lispm-browser--js text)))))

(defmacro lispm-browser--typing-command (name doc call)
  "Define NAME, a command running CALL in the page's field, described by DOC."
  `(defun ,name ()
     ,doc
     (interactive)
     (lispm-browser--type ,call)))

(lispm-browser--typing-command lispm-browser-type-forward-char "Move the caret a character on."
                               "__lme.move('forward', 'character')")
(lispm-browser--typing-command lispm-browser-type-backward-char "Move the caret a character back."
                               "__lme.move('backward', 'character')")
(lispm-browser--typing-command lispm-browser-type-forward-word "Move the caret a word on."
                               "__lme.move('forward', 'word')")
(lispm-browser--typing-command lispm-browser-type-backward-word "Move the caret a word back."
                               "__lme.move('backward', 'word')")
(lispm-browser--typing-command lispm-browser-type-line-start "Move the caret to the line's start."
                               "__lme.move('backward', 'lineboundary')")
(lispm-browser--typing-command lispm-browser-type-line-end "Move the caret to the line's end."
                               "__lme.move('forward', 'lineboundary')")
(lispm-browser--typing-command lispm-browser-type-delete-backward "Delete the character before."
                               "__lme.kill('backward', 'character')")
(lispm-browser--typing-command lispm-browser-type-delete-forward "Delete the character after."
                               "__lme.kill('forward', 'character')")
(lispm-browser--typing-command lispm-browser-type-kill-word "Delete to the word's end."
                               "__lme.kill('forward', 'word')")
(lispm-browser--typing-command lispm-browser-type-backward-kill-word "Delete to the word's start."
                               "__lme.kill('backward', 'word')")
(lispm-browser--typing-command lispm-browser-type-kill-line "Delete to the line's end."
                               "__lme.kill('forward', 'lineboundary')")

(defun lispm-browser-type-next-line ()
  "Move the caret a line down, or choose a menu's next option."
  (interactive)
  (lispm-browser--type "__lme.choose(1); __lme.move('forward', 'line')"))

(defun lispm-browser-type-previous-line ()
  "Move the caret a line up, or choose a menu's previous option."
  (interactive)
  (lispm-browser--type "__lme.choose(-1); __lme.move('backward', 'line')"))

(defun lispm-browser-type-return ()
  "Press Return in the page's field: a field submits its form, a text area
breaks the line, a button is pressed.  A field submitted is left."
  (interactive)
  (lispm-browser--page-call "__lme.enter()"
                            (lambda (result)
                              (unless (member result '("field" "select"))
                                (lispm-browser--typing -1)))))

(defun lispm-browser--stepped (kind)
  "Keep typing when Tab went to a field, KIND being what it went to."
  (unless (member kind '("field" "select"))
    (lispm-browser--set-note (and (stringp kind) (not (equal kind "none"))
                                  "Return presses it; Tab goes on, Escape leaves"))))

(defun lispm-browser-type-next-field ()
  "Go to the page's next field, link or button, as Tab does in a browser."
  (interactive)
  (lispm-browser--page-call "__lme.step(1)" #'lispm-browser--stepped))

(defun lispm-browser-type-previous-field ()
  "Go to the page's previous field, link or button."
  (interactive)
  (lispm-browser--page-call "__lme.step(-1)" #'lispm-browser--stepped))

(defun lispm-browser-type-leave ()
  "Leave the page's field: keys move about the page again."
  (interactive)
  (lispm-browser--type "__lme.blur()")
  (lispm-browser--typing -1))

(defvar-keymap lispm-browser-typing-mode-map
  :doc "Keys typing in a page's field, see `lispm-browser-typing-mode'."
  "<remap> <self-insert-command>" #'lispm-browser-type-char
  "DEL" #'lispm-browser-type-delete-backward
  "C-d" #'lispm-browser-type-delete-forward
  "M-DEL" #'lispm-browser-type-backward-kill-word
  "M-d" #'lispm-browser-type-kill-word
  "C-k" #'lispm-browser-type-kill-line
  "C-f" #'lispm-browser-type-forward-char
  "C-b" #'lispm-browser-type-backward-char
  "M-f" #'lispm-browser-type-forward-word
  "M-b" #'lispm-browser-type-backward-word
  "C-a" #'lispm-browser-type-line-start
  "C-e" #'lispm-browser-type-line-end
  "C-n" #'lispm-browser-type-next-line
  "C-p" #'lispm-browser-type-previous-line
  "C-y" #'lispm-browser-type-paste
  "M-v" #'lispm-browser-type-paste
  "RET" #'lispm-browser-type-return
  "TAB" #'lispm-browser-type-next-field
  "<backtab>" #'lispm-browser-type-previous-field
  "<escape>" #'lispm-browser-type-leave
  "C-g" #'lispm-browser-type-leave)

;; The page's own keys for letters and the space are not self-inserting:
;; every printable character types.
(cl-loop for char from ?\s to ?~
         do (define-key lispm-browser-typing-mode-map (vector char) #'lispm-browser-type-char))

(define-minor-mode lispm-browser-typing-mode
  "Type in the field of the page that has the caret.
Characters go into the field and Emacs's keys move and delete in it, see
`lispm-browser-typing-mode-map'; Escape leaves the field.  The page is
typed in through JavaScript, as Emacs on macOS cannot hand it keys.
\\{lispm-browser-typing-mode-map}"
  :lighter " Typing"
  (setq lispm-browser-status-note
        (when lispm-browser-typing-mode
          "Typing in the page: Return submits, Tab goes on, Escape leaves"))
  (force-mode-line-update t))

(defun lispm-browser-hints-setup ()
  "Give pages the keys following their links and typing in their fields."
  (with-eval-after-load 'xwidget
    (keymap-set xwidget-webkit-mode-map "f" #'lispm-browser-follow-hint)
    (keymap-set xwidget-webkit-mode-map "F" #'lispm-browser-follow-hint-new-tab)
    (keymap-set xwidget-webkit-mode-map "i" #'lispm-browser-first-field)))

(provide 'lispm-browser-hints)
;;; lispm-browser-hints.el ends here
