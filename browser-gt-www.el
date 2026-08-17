;;; browser-gt-www.el --- Web page archiving backend for browser-gt  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser, org
;; URL: https://github.com/dmgerman/browser-gt

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

;; Web page archiving backend for browser-gt.  Registers the SAVE_PAGE
;; WebSocket request handler which saves the main content of any web page
;; to ~/sync/www-archive/<basename>/ as both an HTML file and an org file
;; (converted via pandoc).  Embedded images are extracted to the same
;; directory by pandoc's --extract-media flag.
;;
;; Payload:
;;   { "url": "...", "title": "...", "html": "..." }

;;; Code:

(require 'browser-gt)

;; ── Configuration ────────────────────────────────────────────────────────────

(defvar browser-gt-www-archive-dir "~/sync/www-archive"
  "Directory where saved web pages are stored.")

;; ── Handler ──────────────────────────────────────────────────────────────────

(defun browser-gt-www--handle-save-page (payload)
  "Handle SAVE_PAGE request with PAYLOAD.
Honours :raise after the page has been written to disk — same field as
the interactive handlers, but applied at task completion rather than at
buffer open."
  (browser-gt--require-payload payload)
  (let ((file (browser-gt-www--save payload)))
    (browser-gt--maybe-raise payload)
    (kill-new file)
    (browser-gt--ok (format "Saved to %s (path copied to clipboard)" file))))

;; ── Page saving ───────────────────────────────────────────────────────────────

(defun browser-gt-www--save (payload)
  "Save web page PAYLOAD to a per-item directory under the archive root.
The root is `browser-gt-www-archive-dir'.  Each save creates a new
directory named <timestamp>-<title>/ containing <basename>.org,
<basename>.html, and any extracted images.
Returns the path of the org file written."
  (let* ((url      (plist-get payload :url))
         (title    (or (plist-get payload :title) "web-page"))
         (html     (plist-get payload :html))
         (root     (expand-file-name browser-gt-www-archive-dir))
         (basename (format "%s-%s"
                           (format-time-string "%Y%m%d-%H%M%S")
                           (browser-gt-www--sanitize-title title)))
         (page-dir  (expand-file-name basename root))
         (file      (expand-file-name (concat basename ".org")  page-dir))
         (html-file (expand-file-name (concat basename ".html") page-dir)))
    (unless html
      (error "Payload contains no 'html'"))
    (condition-case err
        (make-directory page-dir t)
      (error
       (error "Could not create directory %s: %s"
              page-dir (error-message-string err))))
    (condition-case err
        (with-temp-file html-file
          (insert html))
      (error
       (browser-gt--warn "could not save HTML file %s: %s"
                            html-file (error-message-string err))))
    (condition-case err
        (with-temp-file file
          (insert (format "#+title: %s\n" (browser-gt--sanitize-org-meta title)))
          (insert (format "#+source_url: %s\n" (browser-gt--sanitize-org-meta url)))
          (insert (format "#+created: %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
          (insert (browser-gt--make-link url title))
          (insert "\n\n")
          (insert (condition-case err
                      ;; Successful pandoc output is rich Org by design — do
                      ;; not sanitize.  The failure fallback inserts page
                      ;; HTML/text as-is, which can hide `* heading' lines;
                      ;; sanitize that path so a captured page cannot break
                      ;; out into the surrounding document structure.
                      (browser-gt-www--html-to-org html page-dir)
                    (error
                     (browser-gt--warn "HTML conversion failed, inserting plain text: %s"
                                          (error-message-string err))
                     (browser-gt--sanitize-org-body html)))))
      (error
       (error "Could not write org file %s: %s"
              file (error-message-string err))))
    file))

(defun browser-gt-www--html-to-org (html media-dir)
  "Convert HTML string to org format via pandoc.
Images are extracted to MEDIA-DIR via pandoc's --extract-media flag.
Signals an error if pandoc is not found or exits non-zero."
  (unless (executable-find browser-gt-pandoc-executable)
    (error "Pandoc not found (set browser-gt-pandoc-executable)"))
  (with-temp-buffer
    (let ((exit-code (call-process-region
                      (browser-gt--strip-svg html) nil
                      browser-gt-pandoc-executable
                      nil t nil
                      "-f" "html" "-t" "org"
                      "--wrap=none"
                      (format "--extract-media=%s" media-dir))))
      (unless (zerop exit-code)
        (error "Pandoc failed (exit %d): %s"
               exit-code (buffer-string)))
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ +<<[^>]+>>\\s-*$" nil t)
        (delete-region (line-beginning-position)
                       (min (1+ (line-end-position)) (point-max))))
      (goto-char (point-min))
      (while (re-search-forward "<<[^>]+>>" nil t)
        (replace-match ""))
      (buffer-string))))

(defun browser-gt-www--sanitize-title (title)
  "Sanitize TITLE for use as a filename component (max 40 chars)."
  (let* ((s (downcase title))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (replace-regexp-in-string "^-+\\|-+$" "" s)))
    (truncate-string-to-width s 40)))

;; ── Register handler ─────────────────────────────────────────────────────────

(browser-gt-register-handler "SAVE_PAGE" #'browser-gt-www--handle-save-page)

(provide 'browser-gt-www)


;; Local Variables:
;; package-lint-main-file: "browser-gt.el"
;; End:

;;; browser-gt-www.el ends here
