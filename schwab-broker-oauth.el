;;; schwab-broker-oauth.el --- Schwab OAuth, token store, and HTTP core -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Credentials, the manual-authorize OAuth flow, the on-disk token
;; store, and the single async HTTP primitive that every Schwab
;; endpoint (in `schwab-broker-marketdata' and `schwab-broker-trader') is built on.
;;
;; Credential resolution order for `schwab-broker-app-key'/`schwab-broker-app-secret'
;; is: (1) the customization variable itself (a literal string, or a
;; function of no arguments you supply to fetch one from your own
;; secret manager); (2) `auth-source', looked up as
;;
;;   machine api.schwabapi.com login app-key password YOUR-CONSUMER-KEY
;;   machine api.schwabapi.com login app-secret password YOUR-CONSUMER-SECRET
;;
;; in `auth-sources' (e.g. ~/.authinfo.gpg); (3) the environment
;; variables `SCHWAB_APP_KEY'/`SCHWAB_SECRET'.  Register an app at
;; https://developer.schwab.com to obtain a Consumer Key/Secret pair.
;;
;; The token file (`schwab-broker-token-file', default
;; ~/.config/schwab/token.json) holds `access_token'/`refresh_token'
;; plus both expiries as ISO-8601 strings, written with file mode 600.
;; Every API call refreshes it first if the access token is stale
;; (skewed 60s early), serialized against concurrent refreshes within
;; this Emacs process by a `mkdir'-based lockfile sitting alongside the
;; token file (TOKEN-FILE.lock).  This is a best-effort, single-process
;; lock: it does not interoperate with a *different* process (e.g. a
;; separate script) refreshing the same token file at the same instant
;; -- only with concurrent refreshes issued from within this same
;; Emacs.
;;
;; The single network primitive every request funnels through is
;; `schwab-broker--http', a thin wrapper around the built-in, asynchronous
;; `url-retrieve'.  Every public entry point in this package has both
;; an async form (its bare name, taking a CALLBACK of (DATA ERR)) and a
;; `-sync' form (blocking, returning DATA or signalling `schwab-broker-error')
;; built on top of the same async form via `schwab-broker--sync-call' -- so
;; mocking `url-retrieve' alone is enough to test both.

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'auth-source)
(require 'browse-url)
(require 'iso8601)

(defgroup schwab-broker nil
  "Charles Schwab Trader & Market Data API client."
  :group 'comm)

(defcustom schwab-broker-app-key nil
  "Schwab app Consumer Key, or a function of no arguments returning it.
Falls back to `auth-source' (host \"api.schwabapi.com\", user
\"app-key\") and then to the SCHWAB_APP_KEY environment variable when
nil.  Obtain a key by registering an app at
https://developer.schwab.com."
  :type '(choice (const :tag "Unset" nil) string function)
  :group 'schwab-broker)

(defcustom schwab-broker-app-secret nil
  "Schwab app Consumer Secret, or a function of no arguments returning it.
Falls back to `auth-source' (host \"api.schwabapi.com\", user
\"app-secret\") and then to the SCHWAB_SECRET environment variable when
nil."
  :type '(choice (const :tag "Unset" nil) string function)
  :group 'schwab-broker)

(defcustom schwab-broker-callback-url "https://127.0.0.1:3600"
  "Redirect URI registered for this app on https://developer.schwab.com.
Must be https, and must match the app's registered callback exactly."
  :type 'string
  :group 'schwab-broker)

(defcustom schwab-broker-token-file "~/.config/schwab/token.json"
  "Path to the on-disk OAuth token store, written with file mode 600.
Uses the same JSON shape (access_token/refresh_token/both expiries) as
this package's Python-side sibling implementation, so both can read
and refresh the same token file."
  :type 'file
  :group 'schwab-broker)

(defcustom schwab-broker-lock-timeout 10
  "Seconds to wait for the token-file lock before signalling `schwab-broker-error'."
  :type 'number
  :group 'schwab-broker)

(defcustom schwab-broker-http-timeout 15
  "Seconds a `-sync' call waits before signalling `schwab-broker-error'.
Bounds `schwab-broker--sync-call' so a callback that never fires cannot hang
Emacs forever."
  :type 'number
  :group 'schwab-broker)

(define-error 'schwab-broker-error "Schwab API error")

;; `url-http-response-status' is `url-http.el''s own runtime dynamic
;; variable, bound in the callback/response buffer -- not defined via a
;; top-level `defvar' there in a way the byte-compiler picks up from a
;; plain `(require \'url-http)', so this free-variable declaration is a
;; byte-compiler satisfier only.
(defvar url-http-response-status)

(defconst schwab-broker--oauth-authorize-url
  "https://api.schwabapi.com/v1/oauth/authorize")
(defconst schwab-broker--oauth-token-url
  "https://api.schwabapi.com/v1/oauth/token")
(defconst schwab-broker--refresh-token-lifetime-seconds (* 7 24 60 60)
  "Schwab does not return a refresh-token expiry in the token response;
the documented lifetime is ~7 days from issuance, reset on every
successful grant (initial or refresh).")
(defconst schwab-broker--access-token-skew-seconds 60
  "Refresh a little before the real access-token expiry, never after.")

;; -- credential resolution --

(defun schwab-broker--auth-source-secret (user)
  "Look up an auth-source secret for Schwab, returning it or nil.
USER is \"app-key\" or \"app-secret\"; the host is always
\"api.schwabapi.com\" (see `auth-source-search')."
  (let* ((found
          (car
           (auth-source-search
            :host "api.schwabapi.com"
            :user user
            :max 1)))
         (secret (plist-get found :secret)))
    (when secret
      (if (functionp secret)
          (funcall secret)
        secret))))

(defun schwab-broker--resolve-credential
    (custom-value auth-source-user env-var label)
  "Resolve a Schwab credential from CUSTOM-VALUE, auth-source, or env.
CUSTOM-VALUE is a string or nullary function; if unset, this falls
back to `auth-source' under AUTH-SOURCE-USER, then the ENV-VAR
environment variable, then a `user-error' naming LABEL."
  (or
   (and custom-value
        (if (functionp custom-value)
            (funcall custom-value)
          custom-value))
   (schwab-broker--auth-source-secret auth-source-user)
   (let ((value (getenv env-var)))
     (and value (not (string-empty-p value)) value))
   (user-error
    "Schwab %s not configured -- set the corresponding customization
variable, add an auth-source entry (machine api.schwabapi.com login %s
password ...), or set $%s.  Register an app at
https://developer.schwab.com to obtain one"
    label auth-source-user env-var)))

(defun schwab-broker--app-key ()
  "Resolve the Schwab app Consumer Key (see `schwab-broker-app-key')."
  (schwab-broker--resolve-credential
   schwab-broker-app-key "app-key" "SCHWAB_APP_KEY" "app key"))

(defun schwab-broker--app-secret ()
  "Resolve the Schwab app Consumer Secret (see `schwab-broker-app-secret')."
  (schwab-broker--resolve-credential
   schwab-broker-app-secret
   "app-secret"
   "SCHWAB_SECRET"
   "app secret"))

;; -- JSON / query-string helpers --

(defun schwab-broker--json (string)
  "Parse STRING, an HTTP response body, as JSON into nested alists.
Returns nil for an empty or blank body."
  (let ((trimmed (string-trim (or string ""))))
    (unless (string-empty-p trimmed)
      (with-temp-buffer
        (insert trimmed)
        (goto-char (point-min))
        (json-parse-buffer
         :object-type 'alist
         :array-type 'list
         :null-object nil)))))

(defun schwab-broker--excerpt (body)
  "Truncate BODY to at most 300 characters, for error messages."
  (let ((text (or body "")))
    (if (> (length text) 300)
        (concat (substring text 0 300) "...")
      text)))

(defun schwab-broker--query-string (params)
  "Build a query string from the alist PARAMS.
Each pair is URL-encoded as \"key=value\"; any pair whose value is nil
is dropped."
  (mapconcat (lambda (pair)
               (concat
                (url-hexify-string (format "%s" (car pair)))
                "="
                (url-hexify-string (format "%s" (cdr pair)))))
             (seq-filter #'cdr params)
             "&"))

(defun schwab-broker--build-url (base-url path params)
  "Build a URL from BASE-URL, PATH, and query PARAMS.
PARAMS is an alist; a query string is appended only when at least one
value in PARAMS is non-nil."
  (let ((query (schwab-broker--query-string params)))
    (concat
     base-url path
     (unless (string-empty-p query)
       (concat "?" query)))))

;; -- the single network primitive --

(defun schwab-broker--http (method url headers data callback)
  "Issue an asynchronous HTTP request and report the outcome to CALLBACK.
METHOD, URL, HEADERS (an alist), and DATA (a pre-encoded request body
string, or nil) describe the request.  CALLBACK is called with a
single RESULT plist: a `:status'/`:body' pair for any completed HTTP
exchange (even a non-2xx one), or an `:error' entry for a
network-level failure with no response at all.  This is the sole
entry point into `url-retrieve' in this package, and the boundary
every test mocks."
  (unless (string-prefix-p "https://" url)
    (signal
     'schwab-broker-error
     (list :insecure-url (format "refusing non-https URL: %s" url))))
  (let ((url-request-method method)
        (url-request-extra-headers headers)
        (url-request-data data))
    (url-retrieve
     url
     (lambda (status)
       (if (plist-get status :error)
           (funcall callback (list :error (plist-get status :error)))
         (let ((buffer (current-buffer)))
           (unwind-protect
               (progn
                 (goto-char (point-min))
                 (let ((code url-http-response-status))
                   (re-search-forward "\r?\n\r?\n" nil 'move)
                   (funcall callback
                            (list
                             :status code
                             :body
                             (buffer-substring
                              (point) (point-max))))))
             (when (buffer-live-p buffer)
               (kill-buffer buffer))))))
     nil t t)))

(defun schwab-broker--sync-call (async-fn)
  "Call ASYNC-FN synchronously and return its result.
ASYNC-FN is a function of one argument, a callback of (DATA ERR).
This helper blocks until that callback fires, returning DATA or
signalling `schwab-broker-error' with ERR; every `-sync' entry point in this
package is implemented in terms of its async sibling via this helper,
bounded by `schwab-broker-http-timeout'."
  (let ((done nil)
        (result nil)
        (err nil)
        (deadline (+ (float-time) schwab-broker-http-timeout)))
    (funcall async-fn
             (lambda (data e)
               (setq
                result data
                err e
                done t)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (cond
     (err
      (signal 'schwab-broker-error err))
     ((not done)
      (signal
       'schwab-broker-error
       (list
        :timeout
        (format "Schwab request timed out after %ss"
                schwab-broker-http-timeout))))
     (t
      result))))

;; -- token file: path, read, write, lock --

(defun schwab-broker-token-file-path ()
  "Return `schwab-broker-token-file' expanded to an absolute path."
  (expand-file-name schwab-broker-token-file))

(defun schwab-broker--lock-path ()
  "Return the sidecar lock directory path for `schwab-broker-token-file-path'."
  (concat (schwab-broker-token-file-path) ".lock"))

(defun schwab-broker--read-token ()
  "Return the parsed token alist from `schwab-broker-token-file'.
Returns nil if the file is absent or unparseable."
  (let ((path (schwab-broker-token-file-path)))
    (when (file-exists-p path)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (json-parse-buffer
             :object-type 'alist
             :array-type 'list
             :null-object nil))
        (error
         nil)))))

(defun schwab-broker--write-token (token)
  "Atomically write TOKEN, an alist, to `schwab-broker-token-file' as chmod 600."
  (let* ((path (schwab-broker-token-file-path))
         (dir (file-name-directory path))
         (tmp (concat path ".tmp")))
    (make-directory dir t)
    (with-temp-file tmp
      (insert (json-serialize token)))
    (set-file-modes tmp #o600)
    (rename-file tmp path t)))

(defun schwab-broker--acquire-lock ()
  "Create and return the token-file lock directory, blocking briefly.
Retries for up to `schwab-broker-lock-timeout' seconds; signals
`schwab-broker-error' with `:lock-timeout' on timeout."
  (let ((lock (schwab-broker--lock-path))
        (deadline (+ (float-time) schwab-broker-lock-timeout)))
    (while (not
            (condition-case nil
                (progn
                  (make-directory lock)
                  t)
              (error
               nil)))
      (when (> (float-time) deadline)
        (signal
         'schwab-broker-error
         (list
          :lock-timeout
          (format
           "timed out waiting %ss for the Schwab token lock at %s"
           schwab-broker-lock-timeout lock))))
      (sleep-for 0.05))
    lock))

(defun schwab-broker--release-lock ()
  "Remove the token-file lock directory, ignoring errors."
  (ignore-errors
    (delete-directory (schwab-broker--lock-path))))

;; -- ISO-8601 timestamps + freshness --

(defun schwab-broker--now-iso ()
  "Return the current UTC time as an ISO-8601 string, microsecond precision."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%6N+00:00" nil t))

(defun schwab-broker--time-plus-iso (seconds)
  "Return the current UTC time plus SECONDS, as an ISO-8601 string."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%6N+00:00"
                      (time-add (current-time) seconds)
                      t))

(defun schwab-broker--iso-to-time (string)
  "Parse the ISO-8601 STRING into an Emacs time value."
  (encode-time (iso8601-parse string)))

(defun schwab-broker--token-fresh-p (token)
  "Return non-nil if TOKEN's access token is still fresh.
\"Fresh\" means not within `schwab-broker--access-token-skew-seconds' of its
own expiry."
  (and token
       (time-less-p
        (current-time)
        (time-subtract
         (schwab-broker--iso-to-time
          (alist-get 'access_token_expires_at token))
         schwab-broker--access-token-skew-seconds))))

(defun schwab-broker--refresh-token-live-p (token)
  "Return non-nil if TOKEN's refresh token has not yet expired."
  (and token
       (time-less-p
        (current-time)
        (schwab-broker--iso-to-time
         (alist-get 'refresh_token_expires_at token)))))

;; -- OAuth: authorize URL, code exchange, refresh --

(defun schwab-broker--authorize-url ()
  "Build the URL to open in a browser to approve access."
  (schwab-broker--build-url
   schwab-broker--oauth-authorize-url ""
   `(("client_id" . ,(schwab-broker--app-key))
     ("redirect_uri"
      .
      ,schwab-broker-callback-url)
     ("response_type" . "code"))))

(defun schwab-broker--extract-code (redirect-url)
  "Extract and URL-decode the `code' parameter from REDIRECT-URL.
REDIRECT-URL is the full URL pasted back after approving access;
signals a `user-error' when no `code=' parameter is present."
  (if (string-match "[?&]code=\\([^&#]+\\)" redirect-url)
      (url-unhex-string (match-string 1 redirect-url))
    (user-error
     "No \"code=\" parameter found in the pasted redirect URL -- paste
the full URL the browser landed on after approving access, not just
the domain")))

(defun schwab-broker--token-from-oauth-response (data)
  "Build this package's on-disk token alist from an `/oauth/token' response.
DATA is that response's parsed JSON body."
  (let ((access-token (alist-get 'access_token data))
        (refresh-token (alist-get 'refresh_token data))
        (expires-in (alist-get 'expires_in data)))
    (unless (and access-token refresh-token (numberp expires-in))
      (signal
       'schwab-broker-error
       (list
        :bad-token-response
        (format
         "oauth token response missing access_token/refresh_token/expires_in: %S"
         data))))
    `((access_token . ,access-token)
      (refresh_token . ,refresh-token)
      (access_token_expires_at
       . ,(schwab-broker--time-plus-iso expires-in))
      (refresh_token_expires_at
       .
       ,(schwab-broker--time-plus-iso
         schwab-broker--refresh-token-lifetime-seconds))
      (obtained_at . ,(schwab-broker--now-iso)))))

(defun schwab-broker--post-oauth-token (grant-params callback)
  "POST GRANT-PARAMS to the Schwab `/oauth/token' endpoint.
Uses HTTP Basic app-key/app-secret auth.  CALLBACK is called with two
arguments, TOKEN-ALIST and ERR."
  (let* ((key (schwab-broker--app-key))
         (secret (schwab-broker--app-secret))
         (basic (base64-encode-string (concat key ":" secret) t)))
    (schwab-broker--http
     "POST" schwab-broker--oauth-token-url
     `(("Content-Type" . "application/x-www-form-urlencoded")
       ("Authorization" . ,(concat "Basic " basic))
       ("Accept" . "application/json"))
     (schwab-broker--query-string grant-params)
     (lambda (result)
       (cond
        ((plist-get result :error)
         (funcall callback
                  nil
                  (list :network-error (plist-get result :error))))
        ((>= (plist-get result :status) 300)
         (funcall callback
                  nil
                  (list
                   :status (plist-get result :status)
                   :body
                   (schwab-broker--excerpt
                    (plist-get result :body)))))
        (t
         (condition-case err
             (funcall callback
                      (schwab-broker--token-from-oauth-response
                       (schwab-broker--json (plist-get result :body)))
                      nil)
           (schwab-broker-error
            (funcall callback nil (cdr err))))))))))

(defun schwab-broker--refresh (token callback)
  "Exchange TOKEN's refresh token for a new token pair.
CALLBACK is called with two arguments, NEW-TOKEN and ERR."
  (schwab-broker--post-oauth-token
   `(("grant_type" . "refresh_token")
     ("refresh_token" . ,(alist-get 'refresh_token token)))
   callback))

(defmacro schwab-broker--refresh-under-lock
    (token-form &rest refresh-body)
  "Acquire the token lock, bind TOKEN from TOKEN-FORM, then run REFRESH-BODY.
REFRESH-BODY must call `schwab-broker--release-lock' itself, exactly once,
from whichever branch it takes -- see callers."
  (declare (indent 1))
  `(progn
     (schwab-broker--acquire-lock)
     (condition-case err
         (let ((token ,token-form))
           ,@refresh-body)
       (error
        (schwab-broker--release-lock)
        (signal (car err) (cdr err))))))

(defun schwab-broker--ensure-fresh-token (callback)
  "Call CALLBACK with a token alist whose access token is fresh.
Refreshes on disk under the single-writer lock first if necessary.
CALLBACK is called with two arguments, TOKEN and ERR."
  (let ((token (schwab-broker--read-token)))
    (cond
     ((null token)
      (funcall
       callback
       nil
       (list
        :not-authenticated "Schwab: not authenticated -- run `schwab-broker-authorize'")))
     ((not (schwab-broker--refresh-token-live-p token))
      (funcall
       callback
       nil
       (list
        :refresh-token-expired "Schwab: refresh token expired -- run `schwab-broker-authorize' again")))
     ((schwab-broker--token-fresh-p token)
      (funcall callback token nil))
     (t
      (schwab-broker--refresh-under-lock (or
                                          (schwab-broker--read-token)
                                          token)
        (if (schwab-broker--token-fresh-p token)
            (progn
              (schwab-broker--release-lock)
              (funcall callback token nil))
          (schwab-broker--refresh
           token
           (lambda (new-token refresh-err)
             (schwab-broker--release-lock)
             (if refresh-err
                 (funcall callback nil refresh-err)
               (schwab-broker--write-token new-token)
               (funcall callback new-token nil))))))))))

(defun schwab-broker--force-refresh (callback)
  "Unconditionally refresh the on-disk token, used after an HTTP 401.
CALLBACK is called with two arguments, NEW-TOKEN and ERR."
  (let ((token (schwab-broker--read-token)))
    (if (null token)
        (funcall
         callback
         nil
         (list
          :not-authenticated "Schwab: not authenticated -- run `schwab-broker-authorize'"))
      (schwab-broker--refresh-under-lock token
        (schwab-broker--refresh
         token
         (lambda (new-token refresh-err)
           (schwab-broker--release-lock)
           (if refresh-err
               (funcall callback nil refresh-err)
             (schwab-broker--write-token new-token)
             (funcall callback new-token nil))))))))

;;;###autoload
(defun schwab-broker-authorize ()
  "Run the Schwab manual-authorize flow.
Opens the consent page in a browser, prompts for the redirect URL
pasted back after approving access, exchanges its `code=' parameter
for tokens, and writes `schwab-broker-token-file'.  Requires
`schwab-broker-app-key'/`schwab-broker-app-secret' (or their
auth-source/environment equivalents) to already be configured."
  (interactive)
  (let ((url (schwab-broker--authorize-url)))
    (browse-url url)
    (message "Schwab: opened %s -- log in and approve access." url)
    (let* ((pasted (read-string "Paste the full redirect URL here: "))
           (code (schwab-broker--extract-code (string-trim pasted))))
      (schwab-broker--sync-call
       (lambda (callback)
         (schwab-broker--post-oauth-token
          `(("grant_type" . "authorization_code")
            ("code" . ,code)
            ("redirect_uri" . ,schwab-broker-callback-url))
          (lambda (token err)
            (if err
                (funcall callback nil err)
              (schwab-broker--write-token token)
              (funcall callback token nil))))))
      (message "Schwab: authorized. Token written to %s"
               (schwab-broker-token-file-path)))))

;;;###autoload
(defun schwab-broker-auth-status ()
  "Show whether Schwab is authenticated and the token's expiries.
Reports via `message' only -- never prints the token values themselves."
  (interactive)
  (let ((token (schwab-broker--read-token)))
    (if (null token)
        (message
         "Schwab: not authenticated (no token file at %s). Run `schwab-broker-authorize'."
         (schwab-broker-token-file-path))
      (message
       "Schwab: token file %s | access token %s (expires %s) | refresh token %s (expires %s)"
       (schwab-broker-token-file-path)
       (if (schwab-broker--token-fresh-p token)
           "valid"
         "expired")
       (alist-get 'access_token_expires_at token)
       (if (schwab-broker--refresh-token-live-p token)
           "valid"
         "EXPIRED")
       (alist-get 'refresh_token_expires_at token)))))

;; -- generic authenticated request, shared by market-data + trader --

(defun schwab-broker--request
    (base-url
     path params callback &optional method data extra-headers)
  "Issue an authenticated request against BASE-URL + PATH and call CALLBACK.
METHOD defaults to \"GET\".  PARAMS is an alist of query parameters,
nil values dropped; DATA is an optional pre-encoded request body;
EXTRA-HEADERS is an optional alist of additional headers.  Refreshes
the access token first if needed and retries once on an HTTP 401 after
a forced refresh.  CALLBACK is called with two arguments, the parsed
JSON and ERR."
  (schwab-broker--ensure-fresh-token
   (lambda (token token-err)
     (if token-err
         (funcall callback nil token-err)
       (schwab-broker--request-with-token
        base-url
        path
        params
        (or method "GET")
        data
        extra-headers
        token
        callback
        t)))))

(defun schwab-broker--request-with-token
    (base-url
     path
     params
     method
     data
     extra-headers
     token
     callback
     retry-on-401)
  "Issue one HTTP attempt for `schwab-broker--request', given a live TOKEN.
BASE-URL, PATH, PARAMS, METHOD, DATA, and EXTRA-HEADERS describe the
request; CALLBACK receives the outcome.  RETRY-ON-401 controls whether
a 401 response triggers one forced refresh-and-retry (nil on the retry
itself, to cap it at one)."
  (let ((url (schwab-broker--build-url base-url path params))
        (headers
         (append
          `(("Authorization" .
             ,(concat "Bearer " (alist-get 'access_token token)))
            ("Accept" . "application/json"))
          extra-headers)))
    (schwab-broker--http
     method url headers data
     (lambda (result)
       (schwab-broker--handle-api-result
        result
        base-url
        path
        params
        method
        data
        extra-headers
        callback
        retry-on-401)))))

(defun schwab-broker--handle-api-result
    (result
     base-url
     path
     params
     method
     data
     extra-headers
     callback
     retry-on-401)
  "Dispatch on RESULT, an `schwab-broker--http' result plist, for CALLBACK.
Forwards a parsed success to CALLBACK, performs the one-shot 401
refresh-and-retry (reissuing the request described by BASE-URL, PATH,
PARAMS, METHOD, DATA, and EXTRA-HEADERS, guarded by RETRY-ON-401), or
forwards an error -- see `schwab-broker--request-with-token'."
  (cond
   ((plist-get result :error)
    (funcall callback
             nil
             (list :network-error (plist-get result :error))))
   ((and retry-on-401 (eql (plist-get result :status) 401))
    (schwab-broker--force-refresh
     (lambda (token err)
       (if err
           (funcall callback nil err)
         (schwab-broker--request-with-token
          base-url
          path
          params
          method
          data
          extra-headers
          token
          callback
          nil)))))
   ((>= (plist-get result :status) 300)
    (funcall callback
             nil
             (list
              :status (plist-get result :status)
              :body
              (schwab-broker--excerpt (plist-get result :body)))))
   (t
    (condition-case err
        (funcall callback
                 (schwab-broker--json (plist-get result :body))
                 nil)
      (error
       (funcall callback
                nil
                (list :parse-error (error-message-string err))))))))

(provide 'schwab-broker-oauth)
;;; schwab-broker-oauth.el ends here
