;;; browsel-youtube.el --- YouTube backend for browsel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser, org, multimedia
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

;; YouTube backend for browsel.  Registers two request handlers:
;;
;;   YOUTUBE             — capture a video into a configurable org file
;;   YOUTUBE_TRANSCRIPT  — download subtitles and save as an org file
;;                         with clickable timestamp links
;;
;; Required configuration:
;;   (setq browsel-youtube-api-key       "YOUR-API-KEY")
;;   (setq browsel-youtube-videos-file   "~/org/videos.org")
;;   (setq browsel-youtube-transcript-dir "~/sync/youtube")
;;
;; Payload (YOUTUBE):
;;   { "url": "...", "title": "...", "text": "...", "raise": false }
;;
;; Payload (YOUTUBE_TRANSCRIPT):
;;   { "url": "...", "title": "...", "raise": false }

;;; Code:

(require 'browsel)
(require 'url-util)
(require 'json)
(require 'subr-x)
(require 'seq)

;; Forward declarations for dynamic vars and functions from org-capture/org.
;; `org-link-preview-region' was added in org 9.7 and is preferred when
;; available; `org-display-inline-images' is the older API kept for
;; older org versions.  The trailing `t' (FILEONLY) tells
;; `check-declare' to verify only that the file exists — not the
;; function signature — because the exact file that provides each
;; entry point shifts across org versions (ol.el, org.el, org-compat.el).
;; The runtime caller guards with `fboundp' regardless.
(defvar org-capture-templates)
(declare-function org-link-preview-region    "ol"  (&optional arg interactive? beg end) t)
(declare-function org-display-inline-images  "org" (&optional include-linked refresh beg end) t)
(declare-function org-capture                "org-capture" (&optional goto keys))

;; ── Configuration ─────────────────────────────────────────────────────────────

(defvar browsel-youtube-api-key nil
  "YouTube Data API v3 key used to fetch video metadata.
Obtain one at https://console.cloud.google.com/ and set this variable.")

(defvar browsel-youtube-videos-file "~/org/videos.org"
  "Org file where YouTube video entries are captured.")

(defvar browsel-youtube-transcript-dir "~/sync/youtube"
  "Directory where YouTube transcript org files are saved.")

(defvar browsel-youtube-transcript-yt-dlp-executable "yt-dlp"
  "Path to the yt-dlp executable.")

;; ── URL helpers ───────────────────────────────────────────────────────────────

(defconst browsel-youtube--id-regexp "[A-Za-z0-9_-]\\{11\\}"
  "Strict YouTube video-ID shape: 11 chars from the base64url alphabet.
URL-derived IDs are used as path components, glob fragments, and the
yt-dlp output template, so anything outside this set has to be rejected
at the entry point to keep slashes, dots, and globs out of file I/O.")

(defun browsel-youtube--video-id (url)
  "Return the YouTube video ID from URL, or nil.
Returns nil unless the extracted value matches
`browsel-youtube--id-regexp' exactly — `v=../../etc' and similar
path-shaped strings are rejected rather than threaded into transcript
directory names or wildcard expansions."
  (let ((re (concat "\\`" browsel-youtube--id-regexp "\\'")))
    (cond
     ((and (string-match "[?&]v=\\([^&]+\\)" url)
           (string-match-p re (match-string 1 url)))
      (match-string 1 url))
     ((and (string-match "youtu\\.be/\\([^?&]+\\)" url)
           (string-match-p re (match-string 1 url)))
      (match-string 1 url))
     (t nil))))

(defun browsel-youtube--sanitize-title (title)
  "Sanitize TITLE for use as a filename component (max 40 chars)."
  (let* ((s (downcase title))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (replace-regexp-in-string "^-+\\|-+$" "" s)))
    (truncate-string-to-width s 40)))

;; ── Metadata fetching ─────────────────────────────────────────────────────────

(defun browsel-youtube--fetch-oembed (url)
  "Fetch YouTube oEmbed metadata for URL.  Return a hash-table or nil."
  (let ((api-url (format "https://www.youtube.com/oembed?url=%s&format=json"
                         (url-hexify-string url))))
    (with-current-buffer (url-retrieve-synchronously api-url t t 5)
      (goto-char (point-min))
      (re-search-forward "\n\n" nil t)
      (json-parse-buffer))))

(defun browsel-youtube--fetch-api-info (url)
  "Fetch YouTube Data API v3 metadata for URL.
Returns the first item hash-table, or signals an error."
  (let ((video-id (browsel-youtube--video-id url)))
    (unless video-id
      (error "Could not extract video ID from: %s" url))
    (unless browsel-youtube-api-key
      (error "Chrome-server-youtube-api-key is not set"))
    (let* ((api-url (format "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails,statistics&id=%s&key=%s"
                            video-id browsel-youtube-api-key))
           (coding-system-for-read 'binary)
           (buf (url-retrieve-synchronously api-url t t)))
      (unless buf (error "Failed to retrieve YouTube info"))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "\n\n" nil 'move)
            (let* ((raw  (buffer-substring-no-properties (point) (point-max)))
                   (text (decode-coding-string raw 'utf-8)))
              (with-temp-buffer
                (insert text)
                (goto-char (point-min))
                (let ((json-object-type 'hash-table)
                      (json-array-type  'list)
                      (json-key-type    'string))
                  (elt (gethash "items" (json-read)) 0)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; ── Duration / chapter helpers ────────────────────────────────────────────────

(defun browsel-youtube--duration-to-minutes (duration)
  "Convert ISO 8601 DURATION (e.g. PT1H20M19S) to a minutes string.
Returns empty string if DURATION is nil or empty."
  (if (or (not duration) (string-empty-p duration))
      ""
    (let* ((hours   (if (string-match "\\([0-9]+\\)H" duration)
                        (string-to-number (match-string 1 duration)) 0))
           (minutes (if (string-match "\\([0-9]+\\)M" duration)
                        (string-to-number (match-string 1 duration)) 0))
           (seconds (if (string-match "\\([0-9]+\\)S" duration)
                        (string-to-number (match-string 1 duration)) 0)))
      (format "%.1f" (+ (* hours 60.0) minutes (/ seconds 60.0))))))

(defun browsel-youtube--timestamp-to-seconds (ts)
  "Convert a timestamp string TS (e.g. \"1:23:45\" or \"3:55\") to total seconds."
  (let* ((parts (mapcar #'string-to-number (split-string ts ":")))
         (len   (length parts)))
    (cond
     ((= len 1) (nth 0 parts))
     ((= len 2) (+ (* (nth 0 parts) 60) (nth 1 parts)))
     ((= len 3) (+ (* (nth 0 parts) 3600) (* (nth 1 parts) 60) (nth 2 parts)))
     (t 0))))

(defun browsel-youtube--convert-chapters (description url)
  "Convert chapter timestamps in DESCRIPTION into org links pointing to URL.
The chapter label and the surrounding description lines come from a
page-controlled string; the label is sanitized via
`browsel--escape-org-link-desc' so it cannot close the link's
description bracket, and any line in DESCRIPTION not matched as a
chapter is left to the caller's later body-sanitization pass."
  (let* ((video-id (browsel-youtube--video-id url))
         (base-url (format "https://www.youtube.com/watch?v=%s" video-id)))
    (string-join
     (mapcar (lambda (line)
               (if (string-match "^\\([0-9:]+\\)[ \t]+\\(.*\\)$" line)
                   (let* ((ts      (match-string 1 line))
                          (label   (browsel--escape-org-link-desc
                                    (match-string 2 line)))
                          (seconds (browsel-youtube--timestamp-to-seconds ts)))
                     (format "[[%s&t=%ss][%s %s]]" base-url seconds ts label))
                 line))
             (split-string description "\n"))
     "\n")))

;; ── Org entry builder ─────────────────────────────────────────────────────────

(defun browsel-youtube--escape-template (s)
  "Escape S so `org-capture-fill-template' treats every char as literal.
A `%' followed by certain letters (or by `(') is a template directive;
URL-encoded text from a YouTube description can hold such sequences
\(e.g. `%A6' = ellipsis), and `org-capture' would otherwise interpret
them — prompting for a Link description, splicing in `org-store-link'
output, evaluating sexps, etc.  `org-capture''s own escape syntax is
`\\\\' before `%', so double backslashes first, then prepend one
backslash to every `%'."
  (replace-regexp-in-string "%" "\\\\%"
   (replace-regexp-in-string "\\\\" "\\\\\\\\" s)))

(defun browsel-youtube--resolve-title (title oembed api-info)
  "Return the most authoritative title available for the video.
Priority: non-empty TITLE, OEMBED \"title\", API-INFO snippet \"title\",
and finally the empty string."
  (cond
   ((and (stringp title) (not (string-empty-p title))) title)
   ((and oembed (gethash "title" oembed))
    (gethash "title" oembed))
   ((and api-info (gethash "snippet" api-info)
         (gethash "title" (gethash "snippet" api-info)))
    (gethash "title" (gethash "snippet" api-info)))
   (t "")))

(defun browsel-youtube--build-entry (url title selection oembed api-info video-id)
  "Build and return an org capture entry string for a YouTube video.
URL, TITLE, SELECTION, and VIDEO-ID identify and seed the entry.
OEMBED and API-INFO may be nil if the respective fetch failed.
All page- or API-controlled strings are sanitized at the splice point:
single-line metadata (heading, property values) via
`browsel--sanitize-org-meta', multi-line body (description, selection)
via `browsel--sanitize-org-body'.  URL goes into `:URL:' raw — it is
already validated to a YouTube watch URL by `browsel-youtube--video-id'."
  (let* ((title       (browsel-youtube--resolve-title title oembed api-info))
         (title-clean (browsel--sanitize-org-meta
                       (replace-regexp-in-string "|" ":" title t t)))
         (ytline      (if video-id (format "[[yt:%s]]\n" video-id) ""))
         (snippet     (and api-info (gethash "snippet"        api-info)))
         (details     (and api-info (gethash "contentDetails" api-info)))
         (author      (and oembed   (gethash "author_name"    oembed)))
         (author-url  (and oembed   (gethash "author_url"     oembed)))
         (duration    (browsel-youtube--duration-to-minutes
                       (and details (gethash "duration" details))))
         (date        (and snippet (gethash "publishedAt"          snippet)))
         (description (browsel-youtube--sanitize-description
                       (browsel-youtube--convert-chapters
                        (or (and snippet (gethash "description" snippet)) "")
                        url)))
         (category    (and snippet (gethash "categoryId"           snippet)))
         (language    (and snippet (gethash "defaultAudioLanguage" snippet)))
         (sel-text    (if (and selection (not (string-empty-p selection)))
                          (concat "\n"
                                  (browsel--sanitize-org-body selection)
                                  "\n")
                        "")))
    (concat "* TODO " title-clean "\n"
            ":PROPERTIES:\n"
            ":URL: "      url "\n"
            ":LANG: "     (browsel--sanitize-org-meta (or language "")) "\n"
            ":CATEGORY: " (browsel--sanitize-org-meta (or category "")) "\n"
            ":LENGTH: "   (browsel--sanitize-org-meta duration) "\n"
            ":AUTHOR:  "  (browsel--sanitize-org-meta (or author "")) "\n"
            ":CHANNEL:  " (browsel--sanitize-org-meta (or author-url "")) "\n"
            ":PDATE: "    (browsel--sanitize-org-meta (or date "")) "\n"
            ":END:\n\n"
            ytline
            "\nThe *Description*:\n\n"
            description
            sel-text
            "\n")))

(defun browsel-youtube--sanitize-description (desc)
  "Sanitize the chapter-converted YouTube description DESC for body splicing.
`browsel-youtube--convert-chapters' has already produced safe `[[...]]'
chapter links; non-chapter lines remain page-controlled, so pass them
through `browsel--sanitize-org-body' to defuse heading/drawer/keyword
injection without touching the chapter links."
  (mapconcat #'browsel--sanitize-org-body
             (split-string desc "\n")
             "\n"))

;; ── YOUTUBE handler ───────────────────────────────────────────────────────────

(defun browsel-youtube--handle-youtube (payload)
  "Handle YOUTUBE request with PAYLOAD.
Schedules the capture and returns immediately (respond-fast-then-defer)."
  (browsel--require-payload payload)
  (browsel-defer #'browsel-youtube--capture payload)
  (browsel--ok "Video capture started"))

(defun browsel-youtube--capture (payload)
  "Capture a YouTube video from PAYLOAD into `browsel-youtube-videos-file'."
  (condition-case err
      (let ((url   (plist-get payload :url))
            (title (or (plist-get payload :title) ""))
            (text  (or (plist-get payload :text) "")))
        (unless url
          (error "Missing url in payload"))
        (browsel--maybe-raise payload)
        (browsel-youtube--video-for-later url title text))
    (error
     (browsel--warn "youtube capture failed: %s"
                          (error-message-string err)))))

(defun browsel-youtube--refresh-inline-images ()
  "Refresh inline images when visiting `browsel-youtube-videos-file'.
Uses `org-link-preview-region' (org 9.7+) when available and falls
back to `org-display-inline-images' on older org versions."
  (when (string-match (regexp-quote (expand-file-name browsel-youtube-videos-file))
                      (or (buffer-file-name) ""))
    (cond
     ((fboundp 'org-link-preview-region)
      (org-link-preview-region nil nil (point-min) (point-max)))
     ((fboundp 'org-display-inline-images)
      (org-display-inline-images nil nil (point-min) (point-max))))))

(defun browsel-youtube--video-for-later (url title selection)
  "Capture YouTube video URL into `browsel-youtube-videos-file'.
URL is the watch URL.  TITLE is the user-supplied title (falls back to
the oEmbed title if URL was sent in its place).  SELECTION is text
quoted from the page, if any.
Fetches metadata from oEmbed and the YouTube Data API, then runs
`org-capture'."
  (let* ((video-id   (browsel-youtube--video-id url))
         (api-info   (condition-case err
                         (browsel-youtube--fetch-api-info url)
                       (error
                        (browsel--warn "API fetch failed (continuing without): %s"
                                             (error-message-string err))
                        nil)))
         (oembed     (condition-case err
                         (browsel-youtube--fetch-oembed url)
                       (error
                        (browsel--warn "oEmbed fetch failed (continuing without): %s"
                                             (error-message-string err))
                        nil)))
         (entry-text (browsel-youtube--escape-template
                      (browsel-youtube--build-entry
                       url title selection oembed api-info video-id)))
         (org-capture-templates
          `(("v" "Video for later" entry
             (file ,browsel-youtube-videos-file)
             ,entry-text
             :empty-lines-after 1
             :empty-lines-before 1
             :immediate-finish t
             :after-finalize browsel-youtube--refresh-inline-images))))
    (org-capture nil "v")
    (let ((path (expand-file-name browsel-youtube-videos-file)))
      (kill-new path)
      (message "Video appended to %s (path copied to clipboard)" path))))

;; ── YOUTUBE_TRANSCRIPT handler ────────────────────────────────────────────────

(defun browsel-youtube--handle-transcript (payload)
  "Handle YOUTUBE_TRANSCRIPT request with PAYLOAD.
Schedules the transcript fetch and returns immediately
\(respond-fast-then-defer)."
  (browsel--require-payload payload)
  (unless (plist-get payload :url)
    (error "Missing url in payload"))
  (browsel-defer #'browsel-youtube--transcript-download-and-save payload)
  (browsel--ok "Transcript download started"))

;; ── yt-dlp helpers ───────────────────────────────────────────────────────────

(defun browsel-youtube--transcript-get-info (url)
  "Run yt-dlp -J URL and return parsed JSON hash-table."
  (unless (executable-find browsel-youtube-transcript-yt-dlp-executable)
    (error "Yt-dlp not found (set browsel-youtube-transcript-yt-dlp-executable)"))
  (let ((default-directory (expand-file-name "~/")))
    (with-temp-buffer
      (let ((exit-code (call-process browsel-youtube-transcript-yt-dlp-executable
                                     nil t nil "-J" "--no-playlist" url)))
        (unless (zerop exit-code)
          (error "Yt-dlp -J failed (exit %d)" exit-code))
        (goto-char (point-min))
        (let ((json-object-type 'hash-table)
              (json-array-type  'list)
              (json-key-type    'string))
          (json-read))))))

(defun browsel-youtube--transcript-effective-lang (info lang)
  "Return the subtitle language code actually available in INFO for LANG.
Tries exact match first, then base language (e.g. \"en\" for \"en-US\").
Returns nil if nothing is found."
  (let ((manual (gethash "subtitles"          info))
        (auto   (gethash "automatic_captions" info))
        (base   (car (split-string lang "-"))))
    (cond
     ((or (and manual (gethash lang manual))
          (and auto   (gethash lang auto)))  lang)
     ((or (and manual (gethash base manual))
          (and auto   (gethash base auto)))  base)
     (t nil))))

(defun browsel-youtube--transcript-download-vtt (url lang conv-dir video-id)
  "Download VTT subtitles for URL in LANG into CONV-DIR.
VIDEO-ID is used as the output filename stem.
Returns the path of the downloaded VTT file, or nil if not found."
  (let ((default-directory conv-dir))
    (with-temp-buffer
      (call-process browsel-youtube-transcript-yt-dlp-executable
                    nil t nil
                    "--write-sub" "--write-auto-sub"
                    "--sub-lang"    lang
                    "--sub-format"  "vtt"
                    "--skip-download"
                    "--no-playlist"
                    "-o" (expand-file-name video-id conv-dir)
                    url)))
  (car (file-expand-wildcards (format "%s/*.vtt" conv-dir))))

;; ── VTT → Org conversion ─────────────────────────────────────────────────────

(defun browsel-youtube--transcript-vtt-time-to-seconds (ts)
  "Convert VTT timestamp TS (form HH:MM:SS.mmm) to total seconds (integer)."
  (if (string-match "\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\)" ts)
      (+ (* (string-to-number (match-string 1 ts)) 3600)
         (* (string-to-number (match-string 2 ts)) 60)
         (string-to-number (match-string 3 ts)))
    0))

(defun browsel-youtube--transcript-format-timestamp (ts)
  "Format VTT timestamp TS (form HH:MM:SS.mmm) as H:MM:SS for display."
  (if (string-match "\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\)" ts)
      (let ((h (string-to-number (match-string 1 ts)))
            (m (match-string 2 ts))
            (s (match-string 3 ts)))
        (if (zerop h)
            (format "%s:%s" m s)
          (format "%d:%s:%s" h m s)))
    ts))

(defun browsel-youtube--transcript-strip-vtt-tags (text)
  "Strip VTT/HTML markup tags (including word-level timing) from TEXT."
  (string-trim (replace-regexp-in-string "<[^>]+>" "" text)))

(defun browsel-youtube--transcript-cue-text (lines)
  "Extract display text from VTT cue LINES (in document order).
YouTube auto-captions use a rolling 2-line window: line 1 repeats the
previous caption; line 2 carries new content with <c> word-level timing.
When a timing-annotated line is present, use only that line so we get
the new content without the repeated prefix.  For plain subtitles with no
timing tags, join all non-blank lines."
  (let ((timing-line (seq-find (lambda (l) (string-match-p "<c>" l)) lines)))
    (browsel-youtube--transcript-strip-vtt-tags
     (if timing-line
         timing-line
       (string-join (seq-filter (lambda (l) (not (string-empty-p (string-trim l)))) lines)
                    " ")))))

(defun browsel-youtube--transcript-vtt-to-org (vtt-content url)
  "Convert VTT-CONTENT to org lines with clickable timestamp links for URL."
  (let* ((video-id (browsel-youtube--video-id url))
         (base-url (format "https://www.youtube.com/watch?v=%s" video-id))
         (lines    (split-string vtt-content "\n"))
         (result   '())
         (prev-text   nil)
         (current-ts  nil)
         (current-txt '())
         (past-header nil))
    (dolist (line lines)
      (cond
       ((string-match "^WEBVTT" line)
        nil)
       ((and (not past-header) (string-match "^[A-Za-z-]+:" line))
        nil)
       ((string-empty-p line)
        (setq past-header t)
        (when (and current-ts current-txt)
          (let ((text (browsel-youtube--transcript-cue-text (reverse current-txt))))
            (unless (or (string-empty-p text)
                        (string= text prev-text))
              (push (cons current-ts text) result)
              (setq prev-text text)))
          (setq current-ts nil current-txt '())))
       ((string-match "^\\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\.[0-9]+\\) --> " line)
        (setq past-header t)
        (setq current-ts (match-string 1 line)
              current-txt '()))
       ((string-match "^[0-9]+$" line)
        nil)
       (current-ts
        (push line current-txt))))
    (when (and current-ts current-txt)
      (let ((text (browsel-youtube--transcript-cue-text (reverse current-txt))))
        (unless (or (string-empty-p text)
                    (string= text prev-text))
          (push (cons current-ts text) result))))
    (mapconcat
     (lambda (cue)
       ;; The timestamp shown as the link description is constructed
       ;; here so it is trusted.  The trailing cue text is page-
       ;; controlled (a captioner could put `* foo' at column 0 to
       ;; create a heading); sanitize it through
       ;; `browsel--sanitize-org-body' before splicing.
       (let* ((ts      (car cue))
              (text    (cdr cue))
              (seconds (browsel-youtube--transcript-vtt-time-to-seconds ts))
              (display (browsel-youtube--transcript-format-timestamp ts)))
         (format "[[%s&t=%ss][%s]] %s"
                 base-url seconds display
                 (browsel--sanitize-org-body text))))
     (reverse result)
     "\n")))

;; ── Transcript file I/O ───────────────────────────────────────────────────────

(defun browsel-youtube--transcript-find-existing-dir (root video-id)
  "Return existing transcript directory for VIDEO-ID under ROOT.
Returns nil when no matching directory is found.  VIDEO-ID is already
validated by `browsel-youtube--video-id' before reaching this call,
so it is safe to embed in the wildcard pattern."
  (car (seq-filter #'file-directory-p
                   (file-expand-wildcards (format "%s/*-%s-*" root video-id)))))

(defun browsel-youtube--transcript-make-dir (payload info)
  "Create and return the per-transcript directory path for PAYLOAD and INFO."
  (let* ((url      (plist-get payload :url))
         (title    (or (plist-get payload :title)
                       (and info (gethash "title" info))
                       "youtube-transcript"))
         (video-id (or (browsel-youtube--video-id url)
                       (error "Refusing transcript: %s is not a recognized YouTube watch URL"
                              url)))
         (root     (expand-file-name browsel-youtube-transcript-dir))
         (conv-dir (or (browsel-youtube--transcript-find-existing-dir root video-id)
                       (expand-file-name
                        (format "%s-%s-%s"
                                (format-time-string "%Y%m%d-%H%M%S")
                                video-id
                                (browsel-youtube--sanitize-title title))
                        root))))
    (make-directory conv-dir t)
    conv-dir))

(defun browsel-youtube--transcript-write-stub (payload info lang)
  "Write a stub org file noting no transcript was available.
PAYLOAD supplies the URL and title; INFO is the parsed yt-dlp metadata
hash-table (or nil if the call failed); LANG is the requested language
code that turned out to have no captions."
  (condition-case err
      (let* ((url        (plist-get payload :url))
             (title      (or (plist-get payload :title)
                             (and info (gethash "title" info))
                             "YouTube transcript"))
             (manual     (and info (gethash "subtitles"          info)))
             (auto       (and info (gethash "automatic_captions" info)))
             (avail-man  (and manual (hash-table-keys manual)))
             (avail-auto (and auto   (hash-table-keys auto)))
             (conv-dir   (browsel-youtube--transcript-make-dir payload info))
             (basename   (file-name-nondirectory conv-dir))
             (file       (expand-file-name (concat basename ".org") conv-dir)))
        (message "No subs for lang=%s; manual=%S auto=%S"
                 lang avail-man avail-auto)
        (with-temp-file file
          (insert (format "#+title: %s\n" (browsel--sanitize-org-meta title)))
          (insert (format "#+youtube_url: %s\n" (browsel--sanitize-org-meta url)))
          (insert (format "#+created: %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
          (insert (browsel--make-link url "Open in YouTube"))
          (insert "\n\n")
          (insert (format "No transcript available (language: %s).\n"
                          (browsel--sanitize-org-meta lang)))
          (when avail-man
            (insert (format "Manual subtitles available: %s\n"
                            (browsel--sanitize-org-meta
                             (string-join avail-man ", ")))))
          (when avail-auto
            (insert (format "Auto captions available: %s\n"
                            (browsel--sanitize-org-meta
                             (string-join avail-auto ", ")))))))
    (error
     (browsel--warn "could not write stub: %s"
                          (error-message-string err)))))

(defun browsel-youtube--transcript-download-and-save (payload)
  "Fetch info, download transcript for PAYLOAD's URL and save to org.
If no transcript is available, writes a stub org file and logs to *Messages*."
  (condition-case err
      (let* ((url      (plist-get payload :url))
             (title    (or (plist-get payload :title) "YouTube transcript"))
             (info     (browsel-youtube--transcript-get-info url))
             (lang     (or (gethash "language" info) "en"))
             (eff-lang (browsel-youtube--transcript-effective-lang info lang)))
        (if (not eff-lang)
            (progn
              (browsel-youtube--transcript-write-stub payload info lang)
              (message "No transcript for %s (lang: %s)" url lang))
          (let* ((video-id (or (browsel-youtube--video-id url) "unknown"))
                 (title    (or (and info (gethash "title" info)) title))
                 (conv-dir (browsel-youtube--transcript-make-dir payload info))
                 (basename (file-name-nondirectory conv-dir))
                 (org-file (expand-file-name (concat basename ".org") conv-dir))
                 (vtt-path (browsel-youtube--transcript-download-vtt
                            url eff-lang conv-dir video-id)))
            (unless vtt-path
              (error "browsel-youtube: VTT file not found after download"))
            (let* ((vtt-dest    (expand-file-name (concat basename ".vtt") conv-dir))
                   (vtt-content (with-temp-buffer
                                  (insert-file-contents vtt-path)
                                  (buffer-string)))
                   (api-info   (condition-case e
                                   (browsel-youtube--fetch-api-info url)
                                 (error
                                  (browsel--warn "API fetch failed (continuing without): %s"
                                                       (error-message-string e))
                                  nil)))
                   (oembed     (condition-case e
                                   (browsel-youtube--fetch-oembed url)
                                 (error
                                  (browsel--warn "oEmbed fetch failed (continuing without): %s"
                                                       (error-message-string e))
                                  nil)))
                   (title      (browsel-youtube--resolve-title title oembed api-info))
                   (entry      (replace-regexp-in-string
                                "^\\* TODO " "* "
                                (browsel-youtube--build-entry
                                 url title "" oembed api-info video-id))))
              (unless (string= vtt-path vtt-dest)
                (rename-file vtt-path vtt-dest t))
              (with-temp-file org-file
                (insert (format "#+title: %s\n"
                                (browsel--sanitize-org-meta title)))
                (insert (format "#+youtube_url: %s\n"
                                (browsel--sanitize-org-meta url)))
                (insert (format "#+youtube_lang: %s\n"
                                (browsel--sanitize-org-meta eff-lang)))
                (insert (format "#+created: %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
                (insert entry)
                (insert "\n** Transcript\n\n")
                (insert (browsel-youtube--transcript-vtt-to-org vtt-content url))
                (insert "\n")))
            (browsel--maybe-raise payload)
            (kill-new org-file)
            (message "Transcript saved to %s (path copied to clipboard)" org-file))))
    (error
     (browsel--warn "transcript failed: %s" (error-message-string err)))))

;; ── Register handlers ────────────────────────────────────────────────────────

(browsel-register-handler "YOUTUBE"             #'browsel-youtube--handle-youtube)
(browsel-register-handler "YOUTUBE_TRANSCRIPT"  #'browsel-youtube--handle-transcript)

;; ── Emacs-side helpers ──────────────────────────────────────────────────────

(defun browsel-youtube--url-with-timestamp (url seconds)
  "Return URL with any existing `t=' query stripped and `&t=Ns' appended.
SECONDS is truncated to an integer.  The separator (`?' vs `&') is
chosen based on whether the stripped URL still carries a query
string, so the result is always a well-formed URL."
  (let* ((clean (replace-regexp-in-string "[?&]t=[^&]*" "" url))
         (sep   (if (string-match-p "\\?" clean) "&" "?")))
    (format "%s%st=%ds" clean sep (truncate seconds))))

;;;###autoload
(defun browsel-youtube-org-link (&optional client)
  "Insert (or return) an Org link to the active YouTube tab at its current time.
The URL carries a `&t=Ns' parameter so clicking the link resumes
playback at the captured time, and the description appends the
`H:MM:SS' / `M:SS' / `S' timestamp so a reader sees the time
without following the link.  Signals `user-error' when the active
tab is not on youtube.com / youtu.be, or when the page has no
video element.  When called interactively the link is inserted at
point and nil is returned; from Lisp the link string is returned.
CLIENT, when non-nil, names the connected browsel client;
interactively the command prompts when more than one client is
connected."
  (interactive (list (browsel--read-client-interactive)))
  (let* ((tab   (browsel--active-tab client))
         (url   (plist-get tab :url))
         (title (or (plist-get tab :title) url)))
    (unless (and url (string-match-p
                      "\\`https?://\\(www\\.\\)?\\(youtube\\.com\\|youtu\\.be\\)"
                      url))
      (user-error "Browsel: active tab is not on YouTube"))
    (let* ((code "(() => { const v = document.querySelector('video');
                            return v ? v.currentTime : null; })()")
           (seconds (browsel--eval-active code client)))
      (unless (numberp seconds)
        (user-error "Browsel: no video element on the active YouTube tab"))
      (let* ((ts-url  (browsel-youtube--url-with-timestamp url seconds))
             (ts-str  (browsel--format-time-hms seconds))
             (desc    (format "%s @ %s" title ts-str))
             (link    (browsel--make-link ts-url desc)))
        (if (called-interactively-p 'any)
            (progn (insert link) nil)
          link)))))

(provide 'browsel-youtube)


;; Local Variables:
;; package-lint-main-file: "browsel.el"
;; End:

;;; browsel-youtube.el ends here
