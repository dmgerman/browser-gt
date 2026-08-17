;;; browsel-chatgpt.el --- ChatGPT backend for browsel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser, org
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

;; ChatGPT-specific backend for browsel.  Registers the CHATGPT
;; WebSocket request handler, which saves a full ChatGPT conversation to
;; ~/sync/chatgpt/<basename>/ as an org file, converting HTML turns via
;; pandoc.  Embedded images are extracted to the same directory.
;; Recapturing the same conversation refreshes the existing directory.
;;
;; Payload:
;;   { "url": "...", "title": "...",
;;     "turns": [ { "role": "...", "html": "...", "text": "..." } ] }

;;; Code:

(require 'browsel)
(require 'subr-x)
(require 'seq)

;; ── Configuration ────────────────────────────────────────────────────────────

(defvar browsel-chatgpt-dir "~/sync/chatgpt"
  "Directory where ChatGPT conversation org files are saved.")
;; browsel-pandoc-executable is defined in browsel.el (shared with -www).

;; ── HTML → Org conversion ─────────────────────────────────────────────────────

(defun browsel-chatgpt--min-heading-level (html)
  "Return the smallest HTML heading level (1-6) found in HTML, or nil if none."
  (let ((case-fold-search t))
    (with-temp-buffer
      (insert html)
      (goto-char (point-min))
      (let ((min-level nil))
        (while (re-search-forward "<h\\([1-6]\\)\\b" nil t)
          (let ((lvl (string-to-number (match-string 1))))
            (when (or (null min-level) (< lvl min-level))
              (setq min-level lvl))))
        min-level))))

(defun browsel-chatgpt--html-to-org (html media-dir)
  "Convert HTML string to org format via pandoc.
Images are extracted to MEDIA-DIR via pandoc's --extract-media flag.
Headings are shifted so the topmost heading in HTML becomes org level 3,
keeping pandoc output nested under the surrounding level-2 turn heading.
Signals an error if pandoc is not found or exits non-zero."
  (unless (executable-find browsel-pandoc-executable)
    (error "Pandoc not found (set browsel-pandoc-executable)"))
  (with-temp-buffer
    (let* ((min-lvl (browsel-chatgpt--min-heading-level html))
           (shift   (if min-lvl (- 3 min-lvl) 0))
           (exit-code (call-process-region (browsel--strip-svg html) nil
                                          browsel-pandoc-executable
                                          nil t nil
                                          "-f" "html" "-t" "org"
                                          "--wrap=none"
                                          (format "--shift-heading-level-by=%d" shift)
                                          (format "--extract-media=%s" media-dir))))
      (unless (zerop exit-code)
        (error "Pandoc failed (exit %d): %s"
               exit-code (buffer-string)))
      ;; Remove headings that contain only org radio targets (e.g. "** <<_r_nh_>>")
      ;; and strip inline radio targets — both come from invisible HTML anchors
      ;; that pandoc converts to org <<target>> syntax.
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ +<<[^>]+>>\\s-*$" nil t)
        (delete-region (line-beginning-position)
                       (min (1+ (line-end-position)) (point-max))))
      (goto-char (point-min))
      (while (re-search-forward "<<[^>]+>>" nil t)
        (replace-match ""))
      (buffer-string))))

;; ── Handler ──────────────────────────────────────────────────────────────────

(defun browsel-chatgpt--handle-chatgpt (payload)
  "Handle CHATGPT request with PAYLOAD.
Honours :raise after the conversation has been written to disk."
  (browsel--require-payload payload)
  (let ((file (browsel-chatgpt--save payload)))
    (browsel--maybe-raise payload)
    (kill-new file)
    (browsel--ok (format "Saved to %s (path copied to clipboard)" file))))

;; ── Conversation saving ───────────────────────────────────────────────────────

(defun browsel-chatgpt--id (url)
  "Extract the conversation ID from a ChatGPT URL, or nil if not found.
Handles both direct conversations (chatgpt.com/c/<id>) and project
conversations (chatgpt.com/g/<project>/c/<id>)."
  (when (string-match "chatgpt\\.com/\\(?:g/[^/?#]+/\\)?c/\\([^/?#]+\\)" url)
    (match-string 1 url)))

(defun browsel-chatgpt--sanitize-title (title)
  "Sanitize TITLE for use as a filename component (max 40 chars)."
  (let* ((s (downcase title))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (replace-regexp-in-string "^-+\\|-+$" "" s)))
    (truncate-string-to-width s 40)))

(defun browsel-chatgpt--find-existing-dir (root id)
  "Return the full path of an existing conversation directory for ID under ROOT.
Returns nil when ID is \"unknown\" (to avoid false matches) or when not found."
  (unless (string= id "unknown")
    (car (seq-filter #'file-directory-p
                     (file-expand-wildcards (format "%s/*-%s-*" root id))))))

(defun browsel-chatgpt--format-turn (turn conv-dir)
  "Format a conversation TURN as org text.
User turns: ** heading from first line, remaining lines as body.
  If the first line exceeds 100 characters the heading is truncated with
  ellipsis and the full first line is prepended to the body.
Assistant turns: plain body text.
Converts :html via pandoc (extracting images to CONV-DIR); falls back to :text.
Headings are routed through `browsel--sanitize-org-meta'.  Pandoc output
is treated as rich Org by design (it produces nested headings, lists,
links — sanitizing would break the format).  The plain-text fallback
path is page-controlled and DOES get `browsel--sanitize-org-body' so a
`* heading' or `:PROPERTIES:' line in the raw text cannot break out."
  (let* ((role      (plist-get turn :role))
         (html      (plist-get turn :html))
         (raw       (plist-get turn :text))
         (rich-body (and html (not (string-empty-p html))
                         (condition-case err
                             (browsel-chatgpt--html-to-org html conv-dir)
                           (error
                            (browsel--warn "HTML conversion failed, using plain text: %s"
                                                 (error-message-string err))
                            nil))))
         (body      (string-trim
                     (or rich-body
                         (browsel--sanitize-org-body (or raw ""))))))
    (if (string= role "user")
        (let* ((lines      (split-string body "\n" t))
               (first-line (or (car lines) ""))
               (rest       (cdr lines))
               (heading    (browsel--sanitize-org-meta
                            (if (> (length first-line) 100)
                                (concat (substring first-line 0 100) "…")
                              first-line)))
               (body-lines (if (> (length first-line) 100)
                               (cons first-line rest)
                             rest)))
          (if body-lines
              (format "** %s\n\n%s\n\n" heading (string-join body-lines "\n"))
            (format "** %s\n\n" heading)))
      (format "%s\n\n" body))))

(defun browsel-chatgpt--save-html (messages file)
  "Save raw HTML of MESSAGES to FILE as a minimal HTML document."
  (with-temp-file file
    (insert "<!DOCTYPE html>\n<html><body>\n")
    (dolist (turn messages)
      (let ((role (plist-get turn :role))
            (html (plist-get turn :html)))
        (insert (format "<section data-role=\"%s\">\n%s\n</section>\n\n"
                        role (or html "")))))
    (insert "</body></html>\n")))

(defun browsel-chatgpt--save (payload)
  "Save ChatGPT conversation PAYLOAD to a per-item directory.
Refreshes the directory if a conversation with the same id already
exists.  Each conversation lives in <root>/<basename>/<basename>.{org,html}
plus any extracted images.  Returns the path of the org file written."
  (let* ((url   (plist-get payload :url))
         (title (or (plist-get payload :title) "chatgpt-conversation"))
         (turns (plist-get payload :turns))
         (id    (or (browsel-chatgpt--id url)
                    (progn
                      (message "Could not extract ID from URL: %s" url)
                      "unknown")))
         (root  (expand-file-name browsel-chatgpt-dir))
         (conv-dir (or (browsel-chatgpt--find-existing-dir root id)
                       (expand-file-name
                        (format "%s-%s-%s"
                                (format-time-string "%Y%m%d-%H%M%S")
                                id
                                (browsel-chatgpt--sanitize-title title))
                        root)))
         (basename  (file-name-nondirectory conv-dir))
         (file      (expand-file-name (concat basename ".org")  conv-dir))
         (html-file (expand-file-name (concat basename ".html") conv-dir)))
    (condition-case err
        (make-directory conv-dir t)
      (error
       (error "Could not create directory %s: %s"
              conv-dir (error-message-string err))))
    (unless turns
      (error "Payload contains no 'turns'"))
    (condition-case err
        (browsel-chatgpt--save-html turns html-file)
      (error
       (browsel--warn "could not save HTML file %s: %s"
                            html-file (error-message-string err))))
    (condition-case err
        (with-temp-file file
          (insert (format "#+title: %s\n" (browsel--sanitize-org-meta title)))
          (insert (format "#+chatgpt_id: %s\n" (browsel--sanitize-org-meta id)))
          (insert (format "#+chatgpt_url: %s\n" (browsel--sanitize-org-meta url)))
          (insert (format "#+created: %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
          (insert (browsel--make-link url "Open in ChatGPT"))
          (insert "\n\n")
          (insert (format "* %s\n\n" (browsel--sanitize-org-meta title)))
          (dolist (turn turns)
            (insert (browsel-chatgpt--format-turn turn conv-dir))))
      (error
       (error "Could not write org file %s: %s"
              file (error-message-string err))))
    file))

;; ── Register handler ─────────────────────────────────────────────────────────

(browsel-register-handler "CHATGPT" #'browsel-chatgpt--handle-chatgpt)

(provide 'browsel-chatgpt)


;; Local Variables:
;; package-lint-main-file: "browsel.el"
;; End:

;;; browsel-chatgpt.el ends here
