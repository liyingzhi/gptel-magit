;;; gptel-magit.el --- Generate commit messages for magit using gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Authors
;; SPDX-License-Identifier: Apache-2.0

;; Author: Ragnar Dahlén <r.dahlen@gmail.com>
;; Version: 1.0
;; Package-Requires: ((emacs "28.1") (magit "4.0") (gptel "0.9.8"))
;; Keywords: vc, convenience
;; URL: https://github.com/ragnard/gptel-magit

;;; Commentary:

;; This package uses the gptel library to add LLM integration into
;; magit. Currently, it adds functionality for generating commit
;; messages.

;;; Code:

(require 'gptel)
(require 'magit)

(defconst gptel-magit-prompt-gnu-style
  "You are an expert at writing Git commits in the GNU/Emacs ChangeLog style.
Your job is to write a detailed, clear commit message that summarizes the changes with technical precision.

### TRIVIAL CHANGES RULE:
- If the change is trivial (e.g., fixing a typo, adjusting indentation, or purely cosmetic), START the commit message with a semicolon (;).
- For trivial changes, provide only a concise one-line summary.
- Example: \"; gptel: Fix typo in docstring\"
- DO NOT use the bulleted ChangeLog format for trivial changes.

### FUNCTIONAL CHANGES RULE:

For all non-trivial changes, use the following structure:

    <component>: <short summary>

    * <file-name> (<function-name>): <detailed description of changes>.
    [optional additional entries for other files/functions]

- MANDATORY: Use asterisk (*) ONLY at the start of a file entry.
- MANDATORY: Indent continuation lines. NEVER start a line with an asterisk unless it's a NEW file/function.
- DO NOT repeat the filename at the end of paragraphs.
- The first line (subject) MUST start with the component or file prefix followed by a colon.
- The subject line MUST be in the imperative mood and max 66 characters.
- DO NOT use conventional commit prefixes like fix: or feat:.
- The body MUST use the ChangeLog format: asterisk, filename, function name in parentheses, and the why/how.
- If multiple functions or files changed, provide a separate bullet point for each.
- Do not end the subject line with any punctuation.
- Use a professional, technical, and descriptive tone."
  "Prompt for GNU/Emacs ChangeLog-style commit messages.")

(defconst gptel-magit-prompt-zed
  "You are an expert at writing Git commits. Your job is to write a short clear commit message that summarizes the changes.

If you can accurately express the change in just the subject line, don't include anything in the message body. Only use the body when it is providing *useful* information.

Don't repeat information from the subject line in the message body.

Only return the commit message in your response. Do not include any additional meta-commentary about the task. Do not include the raw diff output in the commit message.

Follow good Git style:

- Separate the subject from the body with a blank line
- Try to limit the subject line to 50 characters
- Capitalize the subject line
- Do not end the subject line with any punctuation
- Use the imperative mood in the subject line
- Wrap the body at 68 characters
- Keep the body short and concise (omit it entirely if not useful)"
  "A prompt adapted from Zed (https://github.com/zed-industries/zed/blob/main/crates/git_ui/src/commit_message_prompt.txt).")

(defconst gptel-magit-prompt-conventional-commits
  "You are an expert at writing Git commits. Write a short clear commit message that summarizes the changes.

Format:

    <type>(<optional scope>): <description>

    [optional body]

Rules:
- MUST be prefixed with a type: build, chore, ci, docs, feat, fix, perf, refactor, style, test
- MUST use `feat` for new features
- MUST use `fix` for bug fixes
- Scope is optional and goes in parentheses, describing modified section of the codebase, e.g. `fix(parser):`
- A short description of changes MUST immediately follow the type/scope prefix, e.g., `fix: array parsing issue with multiple spaces`
- Keep the subject imperative, capitalized, and under 60 characters
- Do not end the subject line with punctuation
- MAY add a body separated by one blank line after the short description, providing additional contextual infomation about changes.
- Keep the body short and concise (omit it entirely if not useful)"
  "A prompt adapted from Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/).")

(defcustom gptel-magit-commit-styles-alist
  `(("GNU Style" . ,gptel-magit-prompt-gnu-style)
    ("ZED Style" . ,gptel-magit-prompt-zed)
    ("Conventional Commits" . ,gptel-magit-prompt-conventional-commits))
  "Alist of named commit-message styles.

Each element maps a style name to the prompt text used when
generating commit messages."
  :type '(repeat (cons (string :tag "Style Name")
                       (string :tag "Prompt Text")))
  :group 'gptel-magit)

(defcustom gptel-magit-body-length nil
  "Maximum character length for commit message body lines.

If nil, no body-length guidance is added to the prompt."
  :type '(choice (const :tag "No constraint" nil)
                 (integer :tag "Character limit"))
  :group 'gptel-magit)

(defcustom gptel-magit-commit-prompt
  gptel-magit-prompt-conventional-commits
  "The prompt to use for generating a commit message.
The prompt should consider that the input will be a diff of all
staged changes."
  :type 'string
  :group 'gptel-magit)

(defcustom gptel-magit-diff-explain-prompt
  "You are an expert at understanding and explaining code changes by reading diff output. Your job is to write a short clear summary explanation of the changes the changes. Answer in Markdown format."
  "The prompt to use for explaining diff changes.
The prompt should consider that the input will be a diff some changes."
  :type 'string
  :group 'gptel-magit)

(defcustom gptel-magit-streaming t
  "Whether to request streaming responses from the LLM.

When non-nil, streamed commit generation inserts chunks into the
commit buffer as they arrive and replaces them with the formatted
message when the stream completes."
  :type 'boolean
  :group 'gptel-magit)

(custom-declare-variable
 'gptel-magit-model nil
 "The gptel model to use, defaults to `gptel-model` if nil.

See `gptel-model` for documentation.

If set to a model that uses a different backend than
`gptel-backend`, also requires `gptel-magit-backend' to be set to
the correct backend."
 :type (get 'gptel-model 'custom-type)
 :group 'gptel-magit)

(custom-declare-variable
 'gptel-magit-backend nil
 "The gptel backend to use, defaults to `gptel-backend` if nil.

See `gptel-backend` for documentation."
 :type (get 'gptel-backend 'custom-type)
 :group 'gptel-magit)


(defvar gptel-magit-rationale-buffer "*gptel-magit Rationale*"
  "Buffer name used to collect rationale before commit generation.")

(defvar gptel-magit--current-commit-buffer nil
  "Commit message buffer associated with rationale input.")

(defvar-local gptel-magit--generation-overlay nil
  "Overlay used to show commit message generation progress.")


(defun gptel-magit-set-commit-style (style-name)
  "Set `gptel-magit-commit-prompt` from STYLE-NAME.

STYLE-NAME must exist in `gptel-magit-commit-styles-alist`."
  (interactive
   (list
    (completing-read "Choose commit style for gptel-magit: "
                     (mapcar #'car gptel-magit-commit-styles-alist)
                     nil t)))
  (let ((style (assoc style-name gptel-magit-commit-styles-alist)))
    (unless style
      (user-error "Unknown commit style: %s" style-name))
    (setq gptel-magit-commit-prompt (cdr style))
    (message "gptel-magit commit style set to '%s'" style-name)))


(defun gptel-magit--get-commit-prompt ()
  "Return the effective prompt for commit generation."
  (if (and gptel-magit-body-length
           (string= gptel-magit-commit-prompt
                    gptel-magit-prompt-conventional-commits))
      (concat gptel-magit-prompt-conventional-commits
              (format "\n- Try to limit body lines to %d characters"
                      gptel-magit-body-length))
    gptel-magit-commit-prompt))


(defun gptel-magit--request-error (info)
  "Display an error message derived from request INFO."
  (message "gptel-magit error: %s"
           (or (plist-get info :status) "unknown status")))


(defun gptel-magit--format-commit-message (message)
  "Format commit message MESSAGE nicely."
  (with-temp-buffer
    (insert message)
    (text-mode)
    (setq fill-column git-commit-summary-max-length)
    (goto-char (point-min))
    (let ((end-of-first-line (progn (end-of-line) (point))))
      (fill-region (point-min) end-of-first-line))
    (buffer-string)))

(defun gptel-magit--commit-message-comment-regexps ()
  "Return regexps matching Git's generated commit comment lines."
  (delq nil
        (list
         (when (and comment-start-skip
                    (not (string= comment-start-skip "")))
           (concat "^[ \t]*" comment-start-skip))
         (when (and comment-start
                    (not (string= comment-start "")))
           (concat "^[ \t]*" (regexp-quote comment-start)))
         "^[ \t]*#")))

(defun gptel-magit--commit-message-end ()
  "Return the end of editable commit message text."
  (save-excursion
    (catch 'end
      (dolist (comment-regexp (gptel-magit--commit-message-comment-regexps))
        (goto-char (point-min))
        (when (re-search-forward comment-regexp nil t)
          (throw 'end (line-beginning-position))))
      (point-max))))

(defun gptel-magit--clear-commit-message ()
  "Delete existing editable commit message text.

Git's generated comment/instruction section is preserved."
  (let ((inhibit-read-only t))
    (delete-region (point-min) (gptel-magit--commit-message-end))
    (goto-char (point-min))
    (when (not (eobp))
      (insert "\n\n")
      (goto-char (point-min)))))

(defun gptel-magit--insert-commit-message (message)
  "Insert generated commit MESSAGE at point.

If Git's generated comments follow point, keep them on a separate line."
  (let ((inhibit-read-only t))
    (insert message)
    (when (and (not (bolp))
               (not (eobp))
               (not (looking-at-p "\n")))
      (insert "\n"))))

(defun gptel-magit--replace-commit-message (message)
  "Replace existing editable commit message text with MESSAGE."
  (gptel-magit--clear-commit-message)
  (gptel-magit--insert-commit-message message))

(defun gptel-magit--delete-generation-overlay ()
  "Delete any active commit generation progress overlay."
  (when (overlayp gptel-magit--generation-overlay)
    (delete-overlay gptel-magit--generation-overlay))
  (setq gptel-magit--generation-overlay nil))

(defun gptel-magit--show-generation-overlay ()
  "Show a temporary commit generation progress overlay."
  (gptel-magit--delete-generation-overlay)
  (setq gptel-magit--generation-overlay
        (make-overlay (point-min) (if (< (point-min) (point-max))
                                      (1+ (point-min))
                                    (point-min))
                      nil nil t))
  (overlay-put gptel-magit--generation-overlay
               'before-string
               (propertize "Generating..." 'face 'shadow)))

(defun gptel-magit--prepare-commit-message-replacement ()
  "Clear commit text and return markers around generated text."
  (gptel-magit--clear-commit-message)
  (cons (copy-marker (point-min)) (copy-marker (point-min))))

(defun gptel-magit--prepare-commit-message-generation ()
  "Prepare commit buffer for generation and show progress.

Return markers around generated text."
  (let ((markers (gptel-magit--prepare-commit-message-replacement)))
    (gptel-magit--show-generation-overlay)
    markers))

(defun gptel-magit--finish-commit-message-generation
    (message start-marker end-marker)
  "Replace generated text between START-MARKER and END-MARKER with MESSAGE."
  (let ((inhibit-read-only t))
    (gptel-magit--delete-generation-overlay)
    (delete-region start-marker end-marker)
    (goto-char start-marker)
    (gptel-magit--insert-commit-message message)))

(defun gptel-magit--request (&rest args)
  "Call `gptel-request` with ARGS.

Respects configured model/backend options."
  (declare (indent 1))
  (let* ((gptel-backend (or gptel-magit-backend gptel-backend))
         (gptel-model (or gptel-magit-model gptel-model))
         (gptel-include-reasoning 'ignore))
    (apply #'gptel-request args)))

(defun gptel-magit--generate (callback &optional rationale)
  "Generate a commit message for current magit repo.
Invokes CALLBACK with the generated message when done.

Optional RATIONALE provides extra context for why the change was made."
  (let* ((diff (magit-git-output "diff" "--cached"))
         (prompt (if (and rationale (not (string-empty-p rationale)))
                     (format "Why this change was made: %s\n\nCode changes:\n%s"
                             rationale diff)
                   diff))
         (commit-buffer (magit-commit-message-buffer))
         (acc "")
         (commit-message-cleared nil)
         (start-marker nil)
         (end-marker nil))
    (when commit-buffer
      (with-current-buffer commit-buffer
        (save-excursion
          (let ((markers (gptel-magit--prepare-commit-message-generation)))
            (setq start-marker (car markers))
            (setq end-marker (cdr markers))
            (setq commit-message-cleared t)))))
    (gptel-magit--request prompt
      :system (gptel-magit--get-commit-prompt)
      :context nil
      :stream gptel-magit-streaming
      :callback
      (lambda (response info)
        (cond
         ((stringp response)
          (setq acc (concat acc response))
          (cond
           ((and commit-buffer (plist-get info :stream))
            (when (buffer-live-p commit-buffer)
              (with-current-buffer commit-buffer
                (save-excursion
                  (let ((inhibit-read-only t))
                    (unless commit-message-cleared
                      (let ((markers
                             (gptel-magit--prepare-commit-message-replacement)))
                        (setq start-marker (car markers))
                        (setq end-marker (cdr markers))
                        (setq commit-message-cleared t)))
                    (gptel-magit--delete-generation-overlay)
                    (goto-char end-marker)
                    (insert response)
                    (set-marker end-marker (point)))))))
           ((plist-get info :stream)
            nil)
           (t
            (let ((message (gptel-magit--format-commit-message acc)))
              (if (and commit-buffer start-marker end-marker)
                  (when (buffer-live-p commit-buffer)
                    (with-current-buffer commit-buffer
                      (save-excursion
                        (gptel-magit--finish-commit-message-generation
                         message start-marker end-marker))))
                (funcall callback message))))))
         ((eq response t)
          (let ((message (gptel-magit--format-commit-message acc)))
            (if (and commit-buffer start-marker end-marker)
                (when (buffer-live-p commit-buffer)
                  (with-current-buffer commit-buffer
                    (save-excursion
                      (unless commit-message-cleared
                        (let ((markers
                               (gptel-magit--prepare-commit-message-replacement)))
                          (setq start-marker (car markers))
                          (setq end-marker (cdr markers))
                          (setq commit-message-cleared t)))
                      (gptel-magit--finish-commit-message-generation
                       message start-marker end-marker))))
              (funcall callback message))))
         ((and (consp response) (eq (car response) 'reasoning))
          nil)
         ((or (null response) (eq response 'abort))
          (when (and commit-buffer (buffer-live-p commit-buffer))
            (with-current-buffer commit-buffer
              (gptel-magit--delete-generation-overlay)))
          (gptel-magit--request-error info)))))))

(defun gptel-magit-generate-message ()
  "Generate a commit message when in the git commit buffer."
  (interactive)
  (unless (magit-commit-message-buffer)
    (user-error "No commit in progress"))
  (gptel-magit--generate (lambda (message)
                           (let ((buffer (magit-commit-message-buffer)))
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (save-excursion
                                   (gptel-magit--replace-commit-message
                                    message)))))))
  (message "magit-gptel: Generating commit message..."))

(defun gptel-magit-commit-generate (&optional args)
  "Create a new commit with a generated commit message.
Uses ARGS from transient mode."
  (interactive (list (magit-commit-arguments)))
  (gptel-magit--generate
   (lambda (message)
     (magit-commit-create (append args `("--message" ,message "--edit")))))
  (message "magit-gptel: Generating commit..."))

(defun gptel-magit--show-diff-explain (text)
  "Popup a buffer with diff explanation TEXT."
  (let ((buffer-name "*gptel-magit diff-explain*"))
    (when-let ((existing-buffer (get-buffer buffer-name)))
      (kill-buffer existing-buffer))
    (let ((buffer (get-buffer-create buffer-name)))
      (with-current-buffer buffer
        (insert text)
        (setq fill-column 72)
        (fill-region (point-min) (point-max))
        (markdown-view-mode)
        (goto-char (point-min)))
      (pop-to-buffer buffer))))

(defun gptel-magit--do-diff-request (diff)
  "Send request for an explanation of DIFF."
  (gptel-magit--request diff
    :system gptel-magit-diff-explain-prompt
    :context nil
    :callback (lambda (response info)
                (cond
                 ((stringp response)
                  (gptel-magit--show-diff-explain response))
                 ((and (consp response) (eq (car response) 'reasoning))
                  nil)
                 ((or (null response) (eq response 'abort))
                  (gptel-magit--request-error info)))))
  (message "magit-gptel: Explaining diff..."))

(defun gptel-magit-diff-explain (&optional arg)
  "Ask for an explanation of diff at current section."
  (interactive "P")
  (if arg
      (gptel-magit--do-diff-request (buffer-string))
    (when-let* ((section (magit-current-section))
                (start (oref section content))
                (end (oref section end))
                (content (buffer-substring start end)))
      (gptel-magit--do-diff-request content))))


(define-derived-mode gptel-magit-rationale-mode text-mode "gptel-magit-Rationale"
  "Major mode for entering commit rationale."
  (local-set-key (kbd "C-c C-c") #'gptel-magit--submit-rationale)
  (local-set-key (kbd "C-c C-k") #'gptel-magit--cancel-rationale))


(defun gptel-magit--setup-rationale-buffer ()
  "Prepare the rationale buffer with usage instructions."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert ";;; WHY are you making these changes? (optional)\n")
    (insert ";;; Press C-c C-c to generate commit message, C-c C-k to cancel\n")
    (insert ";;; Leave empty to generate without rationale\n\n")
    (add-text-properties (point-min) (point)
                         '(face font-lock-comment-face read-only t))
    (goto-char (point-max))))


(defun gptel-magit--rationale-text ()
  "Return the editable rationale text from the current buffer."
  (string-trim
   (buffer-substring-no-properties
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp))
                  (get-text-property (point) 'read-only))
        (forward-char))
      (point))
    (point-max))))


(defun gptel-magit--submit-rationale ()
  "Submit the rationale buffer and generate a commit message."
  (interactive)
  (let ((rationale (gptel-magit--rationale-text)))
    (quit-window t)
    (gptel-magit--generate
     (lambda (message)
       (when (buffer-live-p gptel-magit--current-commit-buffer)
         (with-current-buffer gptel-magit--current-commit-buffer
           (save-excursion
             (gptel-magit--replace-commit-message message)))))
     rationale)
    (message "magit-gptel: Generating commit message with rationale...")))


(defun gptel-magit--cancel-rationale ()
  "Cancel rationale input."
  (interactive)
  (quit-window t)
  (message "Commit generation canceled."))


(defun gptel-magit-generate-message-with-rationale ()
  "Generate a commit message with an optional rationale."
  (interactive)
  (unless (magit-commit-message-buffer)
    (user-error "No commit in progress"))
  (setq gptel-magit--current-commit-buffer (magit-commit-message-buffer))
  (let ((buffer (get-buffer-create gptel-magit-rationale-buffer)))
    (with-current-buffer buffer
      (gptel-magit-rationale-mode)
      (gptel-magit--setup-rationale-buffer))
    (pop-to-buffer buffer)))


(defun gptel-magit-commit-generate-with-rationale (&optional args)
  "Create a commit with a generated message and optional rationale.

Uses ARGS from transient mode."
  (interactive (list (magit-commit-arguments)))
  (setq gptel-magit--current-commit-buffer nil)
  (let ((buffer (get-buffer-create gptel-magit-rationale-buffer)))
    (with-current-buffer buffer
      (gptel-magit-rationale-mode)
      (gptel-magit--setup-rationale-buffer)
      (local-set-key
       (kbd "C-c C-c")
       (lambda ()
         (interactive)
         (let ((rationale (gptel-magit--rationale-text)))
           (quit-window t)
           (gptel-magit--generate
            (lambda (message)
              (magit-commit-create
               (append args `("--message" ,message "--edit"))))
            rationale)
           (message "magit-gptel: Generating commit with rationale...")))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun gptel-magit-install ()
  "Install gptel-magit functionality."
  (define-key git-commit-mode-map (kbd "M-g") 'gptel-magit-generate-message)
  (define-key git-commit-mode-map (kbd "M-r")
    'gptel-magit-generate-message-with-rationale)
  (transient-append-suffix 'magit-commit #'magit-commit-create
    '("g" "Generate commit" gptel-magit-commit-generate))
  (transient-append-suffix 'magit-commit #'gptel-magit-commit-generate
    '("r" "Generate with rationale" gptel-magit-commit-generate-with-rationale))
  (transient-append-suffix 'magit-diff #'magit-stash-show
    '("x" "Explain" gptel-magit-diff-explain)))

(provide 'gptel-magit)
;;; gptel-magit.el ends here
