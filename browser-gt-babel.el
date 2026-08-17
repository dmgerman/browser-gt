;;; browsel-babel.el --- Org Babel integration for browsel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser, org, languages
;; URL: https://github.com/dmgerman/browsel

;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Adds an `org-babel-execute:browsel-js' function so the user can
;; evaluate JavaScript in the browser's active tab from inside an org
;; source block and capture the return value.
;;
;;   #+begin_src browsel-js
;;   document.querySelector('video').currentTime
;;   #+end_src
;;
;; Header arguments:
;;   :world  "USER_SCRIPT" (default) — isolated world; sees the DOM
;;             but not page-defined globals or functions.  Portable
;;             between Chrome and Firefox.
;;           "MAIN" — page's own `window' / state.  Required for
;;             reading page-framework state (e.g.
;;             `window.ytInitialPlayerResponse') or calling
;;             page-defined functions.  Chrome only — not supported
;;             on Firefox MV2.
;;   :tab-id N — execute in this tab id instead of the active tab.
;;   :frames "all" — return the InjectionResult array for every frame
;;           the script ran in.  Default: the first frame's value.
;;   :client NAME — pick which connected browser runs the block when
;;           more than one is connected (e.g. \"chrome\", \"firefox\").
;;           With one client connected the block runs there
;;           automatically and :client may be omitted.
;;
;; The block's body becomes the JS code passed to
;; `chrome.userScripts.execute'.  As with the EVAL_IN_ACTIVE_TAB handler
;; it requires the user to have toggled "Allow User Scripts" on for the
;; extension at chrome://extensions (Chrome enforces this once per
;; extension).
;;
;; C-c ' opens blocks in js-mode for editing/highlighting.

;;; Code:

(require 'browsel)
(require 'org)

;; Forward-declare so we don't pull in the whole babel runtime at load time.
(declare-function org-babel-script-escape "ob-core" (str &optional force))

(defvar org-src-lang-modes)

;; Make C-c ' open browsel-js blocks in javascript-mode for syntax help.
;; Called at load time; if `org-src' has not been loaded yet,
;; `org-src-lang-modes' is forward-declared above and `add-to-list'
;; will define it on first use.
(eval-when-compile (require 'org-src nil t))
(add-to-list 'org-src-lang-modes '("browsel-js" . js))

(defun browsel-babel--first-result (response)
  "Return the JS return value from the first frame in RESPONSE.
RESPONSE is the EVAL_IN_ACTIVE_TAB response payload."
  (let ((frames (plist-get response :result)))
    ;; frames is a vector or list of InjectionResult plists.  Pull the
    ;; first one and extract its :result field.
    (plist-get
     (cond
      ((vectorp frames) (when (> (length frames) 0) (aref frames 0)))
      ((listp frames)   (car frames))
      (t                nil))
     :result)))

;;;###autoload
(defun org-babel-execute:browsel-js (body params)
  "Execute BODY as JavaScript in the active browser tab.
PARAMS is the alist of header arguments from the source block."
  (let* ((world    (or (cdr (assq :world  params)) "USER_SCRIPT"))
         (tab-id   (cdr (assq :tab-id params)))
         (frames   (cdr (assq :frames params)))
         (client   (cdr (assq :client params)))
         (req-payload (append
                       (list :code body :world world)
                       (when tab-id (list :tabId tab-id))))
         (response (browsel-request "EVAL_IN_ACTIVE_TAB"
                                          req-payload client))
         (status   (plist-get response :status)))
    (unless (equal status "ok")
      (error "browsel-js: %s"
             (or (plist-get response :message)
                 "browser returned non-ok status")))
    (if (equal frames "all")
        (plist-get response :result)
      (browsel-babel--first-result response))))

(provide 'browsel-babel)


;; Local Variables:
;; package-lint-main-file: "browsel.el"
;; End:

;;; browsel-babel.el ends here
