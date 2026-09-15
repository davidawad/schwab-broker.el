;;; schwab-broker-oauth.el --- Schwab OAuth, token store, and HTTP core -*- lexical-binding: t; -*-

;; Author: David Awad
;; Keywords: comm, tools, finance

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
;;
;; `schwab-broker-authorize-listen' is a callback-LISTENER variant of
;; `schwab-broker-authorize': Schwab's `code=' expires in
;; ~30s and the manual paste round-trip can lose that race.  As of this
;; writing it cannot actually serve HTTPS -- Emacs's built-in GnuTLS only
;; supports client-mode TLS -- so it signals a clear `user-error'
;; instead of pretending to work; see
;; `schwab-broker--listener-ensure-tls-available's docstring for the
;; investigation, and this package's README for the full story
;; (including the working alternatives: the paste flow here, or the
;; Python-side `tradeboards auth schwab --listen').  The request-
;; parsing/exchange/one-shot/timeout machinery it would use is
;; implemented and tested regardless, ready for whenever real
;; server-role TLS support exists.

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

(defcustom schwab-broker-tls-cert-file nil
  "TLS certificate file for `schwab-broker-authorize-listen'.
Paired with `schwab-broker-tls-key-file' (both must be set together);
leave nil to auto-generate an ephemeral self-signed cert via `openssl'
instead.  As of this writing `schwab-broker-authorize-listen' cannot
actually use either -- see its docstring."
  :type '(choice (const :tag "Auto-generate via openssl" nil) file)
  :group 'schwab-broker)

(defcustom schwab-broker-tls-key-file nil
  "TLS private key file paired with `schwab-broker-tls-cert-file'."
  :type '(choice (const :tag "Auto-generate via openssl" nil) file)
  :group 'schwab-broker)

(defcustom schwab-broker-listener-timeout 600
  "Seconds `schwab-broker-authorize-listen' would wait for the OAuth callback.
Only takes effect once it can actually listen -- see its docstring."
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

;; -- schwab-broker-authorize-listen: callback listener building blocks --
;;
;; Investigated 2026-09-15: Emacs's built-in GnuTLS
;; cannot terminate an INBOUND (server-role) TLS connection.  Two pieces
;; of evidence, against the Emacs used for this investigation (30.2;
;; this restriction is not new/version-specific -- `gnutls-boot' has
;; documented "client mode only" for the lifetime of Emacs's built-in
;; GnuTLS support):
;;
;;   1. `gnutls-boot's own docstring: "Initialize GnuTLS client for
;;      process PROC ... Currently only client mode is supported."
;;
;;   2. Live-tested: a `make-network-process' `:server t' process with
;;      `:tls-parameters' accepts connections and hands its filter the
;;      raw, STILL-ENCRYPTED ClientHello bytes verbatim -- no handshake
;;      is attempted at all.  Connecting to it with a real TLS client
;;      (`openssl s_client') gets back our plaintext HTTP reply, which
;;      the client correctly rejects as a TLS protocol violation
;;      ("wrong version number") -- proof no server-side negotiation
;;      ever happens.  `:tls-parameters' is a CLIENT-mode-only facility
;;      (built for `open-network-stream'); pairing it with `:server t'
;;      is silently a no-op on the accepted socket, not a working
;;      listener.
;;
;; Schwab's registered callback URL must be `https', so a plaintext
;; listener cannot complete the browser's handshake either -- there is
;; no fallback that "mostly works".  Per this investigation,
;; `schwab-broker-authorize-listen' signals a clear `user-error' via
;; `schwab-broker--listener-ensure-tls-available' rather than hanging or
;; silently failing.  Everything else below it -- cert resolution,
;; request-line parsing, the code/exchange/token-write path (reusing
;; `schwab-broker--post-oauth-token'/`schwab-broker--write-token'
;; verbatim, exactly like `schwab-broker-authorize' does), one-shot
;; semantics, and the timeout bound -- is implemented for real and
;; covered by tests against a real (plaintext) loopback socket, ready to
;; be wired to a real TLS backend the moment one exists.

(defun schwab-broker--listener-host-port ()
  "Return (HOST . PORT) parsed from `schwab-broker-callback-url'.
The SAME URL `schwab-broker--authorize-url' embeds as its `redirect_uri'."
  (let ((url (url-generic-parse-url schwab-broker-callback-url)))
    (cons (or (url-host url) "127.0.0.1") (or (url-port url) 443))))

(defun schwab-broker--listener-tls-dir ()
  "Directory for the auto-generated ephemeral TLS cert/key.
Sits alongside `schwab-broker-token-file'."
  (expand-file-name "tls"
                    (file-name-directory
                     (schwab-broker-token-file-path))))

(defun schwab-broker--listener-ephemeral-cert-paths ()
  "Return (CERT-PATH . KEY-PATH) for the auto-generated ephemeral cert."
  (let ((dir (schwab-broker--listener-tls-dir)))
    (cons
     (expand-file-name "listener-cert.pem" dir)
     (expand-file-name "listener-key.pem" dir))))

(defun schwab-broker--listener-cert-valid-p (cert-path)
  "Non-nil if CERT-PATH exists and will not expire soon.
\"Soon\" means within the next hour, per `openssl x509 -checkend'.
Never signals -- any openssl/IO failure is just treated as \"not
valid, regenerate\"."
  (and (file-exists-p cert-path)
       (executable-find "openssl")
       (ignore-errors
         (= 0
            (call-process "openssl"
                          nil
                          nil
                          nil
                          "x509"
                          "-in"
                          cert-path
                          "-noout"
                          "-checkend"
                          "3600")))))

(defun schwab-broker--listener-generate-ephemeral-cert (host)
  "Generate a self-signed TLS cert for HOST via `openssl req -x509'.
Writes into `schwab-broker--listener-ephemeral-cert-paths' (mode 600)
and returns that same (CERT-PATH . KEY-PATH).  Signals `user-error' if
`openssl' fails."
  (let* ((paths (schwab-broker--listener-ephemeral-cert-paths))
         (cert-path (car paths))
         (key-path (cdr paths))
         (ip-literal-p
          (string-match-p "\\`[0-9]+\\(\\.[0-9]+\\)\\{3\\}\\'" host)))
    (make-directory (schwab-broker--listener-tls-dir) t)
    (with-temp-buffer
      (unless (= 0
                 (call-process "openssl"
                               nil
                               t
                               nil
                               "req"
                               "-x509"
                               "-newkey"
                               "rsa:2048"
                               "-nodes"
                               "-keyout"
                               key-path
                               "-out"
                               cert-path
                               "-days"
                               "825"
                               "-subj"
                               (format "/CN=%s" host)
                               "-addext"
                               (format "subjectAltName=%s"
                                       (if ip-literal-p
                                           (format "IP:%s" host)
                                         (format "DNS:%s" host)))))
        (user-error "TLS cert generation via openssl failed: %s"
                    (string-trim (buffer-string)))))
    (set-file-modes key-path #o600)
    (set-file-modes cert-path #o600)
    paths))

(defun schwab-broker--listener-resolve-tls-cert ()
  "TLS cert/key resolution for `schwab-broker-authorize-listen'.
In order: `schwab-broker-tls-cert-file'/`schwab-broker-tls-key-file'
\(both must be set together); an ephemeral self-signed cert
auto-generated via `openssl' into `schwab-broker--listener-tls-dir'
\(reused across calls while still valid, per
`schwab-broker--listener-cert-valid-p'); or an actionable `user-error'
naming both options plus `schwab-broker-authorize', the always-working
paste flow.  `openssl' is an optional runtime convenience here, never a
package dependency.  Returns (CERT-PATH . KEY-PATH)."
  (cond
   ((or schwab-broker-tls-cert-file schwab-broker-tls-key-file)
    (unless (and schwab-broker-tls-cert-file
                 schwab-broker-tls-key-file)
      (user-error
       "Both schwab-broker-tls-cert-file and schwab-broker-tls-key-file must be set together"))
    (unless (and (file-exists-p schwab-broker-tls-cert-file)
                 (file-exists-p schwab-broker-tls-key-file))
      (user-error "TLS cert/key file not found: %s / %s"
                  schwab-broker-tls-cert-file
                  schwab-broker-tls-key-file))
    (cons schwab-broker-tls-cert-file schwab-broker-tls-key-file))
   ((not (executable-find "openssl"))
    (user-error
     "No TLS cert available for schwab-broker-authorize-listen: set schwab-broker-tls-cert-file/schwab-broker-tls-key-file, or install openssl (an optional runtime convenience, not a dependency of this package -- not found on PATH) so one can be auto-generated, or use `schwab-broker-authorize' instead"))
   (t
    (let ((paths (schwab-broker--listener-ephemeral-cert-paths)))
      (if (and (schwab-broker--listener-cert-valid-p (car paths))
               (file-exists-p (cdr paths)))
          paths
        (schwab-broker--listener-generate-ephemeral-cert
         (car (schwab-broker--listener-host-port))))))))

(defun schwab-broker--listener-extract-code (request-line)
  "Extract and URL-decode the `code=' query parameter from REQUEST-LINE.
REQUEST-LINE is the request line of an incoming HTTP request (e.g.
\"GET /?code=abc123&session=xyz HTTP/1.1\").  Returns nil if
REQUEST-LINE has no `code=' parameter (e.g. a browser's stray
/favicon.ico request)."
  (when (string-match "\\`[A-Z]+ \\([^ ]+\\) HTTP/" request-line)
    (let ((path (match-string 1 request-line)))
      (when (string-match "[?&]code=\\([^&#[:space:]]+\\)" path)
        (url-unhex-string (match-string 1 path))))))

(defun schwab-broker--listener-exchange-and-respond (code)
  "Exchange CODE for a Schwab token pair and write it to disk.
CODE is a `code=' value extracted from an incoming request, or nil.
Uses the SAME `schwab-broker--post-oauth-token'/`schwab-broker--write-token'
functions `schwab-broker-authorize' uses -- no duplicated
exchange/token-shape logic.  Returns a (STATUS . BODY) cons: 404 when
CODE is nil (no `code=' on the request at all -- e.g. a browser's
stray /favicon.ico); otherwise 200, with BODY distinguishing a
successful exchange from a failed one (a failed exchange is reported
in the response body, never a crash -- matching this package's
Python-side sibling listener's contract)."
  (if (null code)
      (cons 404 "no code= parameter on this request")
    (condition-case err
        (let ((token
               (schwab-broker--sync-call
                (lambda (callback)
                  (schwab-broker--post-oauth-token
                   `(("grant_type" . "authorization_code")
                     ("code" . ,code)
                     ("redirect_uri" . ,schwab-broker-callback-url))
                   callback)))))
          (schwab-broker--write-token token)
          (cons
           200
           "Schwab token captured and stored. You can close this tab."))
      (schwab-broker-error
       (cons 200 (format "Token exchange FAILED: %S" (cdr err)))))))

(defun schwab-broker--listener-http-response (status body)
  "Build a raw HTTP/1.1 response string for STATUS and BODY.
STATUS is 200 or 404; BODY is a plain-text string."
  (concat
   (format "HTTP/1.1 %d %s\r\n"
           status
           (if (= status 200)
               "OK"
             "Not Found"))
   "Content-Type: text/plain; charset=utf-8\r\n"
   (format "Content-Length: %d\r\n" (string-bytes body))
   "Connection: close\r\n\r\n"
   body))

(defvar schwab-broker--listener-result nil
  "Internal: the (STATUS . BODY) outcome of the current listener run.
Dynamically bound by `schwab-broker--listener-run'; nil while still
waiting.  Set by `schwab-broker--listener-filter' and read by
`schwab-broker--listener-run' across the async filter-callback boundary
-- this is why it is a real `defvar' (a dynamic/special variable), not
a lexical `let' binding local to either function.")

(defun schwab-broker--listener-filter (proc chunk)
  "Process filter for one accepted `schwab-broker--listener-run' connection.
Buffers CHUNK (in PROC's process plist) until a full request line is
seen, then extracts its `code=' parameter (if any), exchanges/writes it
via `schwab-broker--listener-exchange-and-respond', sends the HTTP
response, and closes PROC.  A `code='-bearing request (successful
exchange or not) is recorded into `schwab-broker--listener-result'; a
request with no `code=' (e.g. a browser's stray /favicon.ico) is
answered 404 and otherwise ignored -- the listener keeps waiting for
the real callback."
  (process-put
   proc
   :schwab-broker-buffer
   (concat (or (process-get proc :schwab-broker-buffer) "") chunk))
  (let ((buffer (process-get proc :schwab-broker-buffer)))
    (when (string-match "\r?\n" buffer)
      (let* ((request-line (substring buffer 0 (match-beginning 0)))
             (code
              (schwab-broker--listener-extract-code request-line))
             (outcome
              (schwab-broker--listener-exchange-and-respond code)))
        (ignore-errors
          (process-send-string
           proc
           (schwab-broker--listener-http-response
            (car outcome) (cdr outcome))))
        (ignore-errors
          (delete-process proc))
        (unless (= (car outcome) 404)
          (setq schwab-broker--listener-result outcome))))))

(defun schwab-broker--listener-run
    (host port timeout &optional tls-parameters on-listening)
  "Run a one-shot OAuth callback listener on HOST:PORT.
Waits up to TIMEOUT seconds.  Returns the (STATUS . BODY) outcome of
the first request carrying a `code=' parameter (successful or failed
exchange alike), or signals `schwab-broker-error' with `:timeout' if
none arrives in time.  TLS-PARAMETERS, if non-nil, is passed to
`make-network-process' as
`:tls-parameters' -- see `schwab-broker--listener-ensure-tls-available'
for why `schwab-broker-authorize-listen' never actually supplies one
today; tests exercise this function with TLS-PARAMETERS nil, over a
real plaintext loopback socket.  ON-LISTENING, if non-nil, is called
with the bound server process before blocking -- a test hook."
  (let ((schwab-broker--listener-result nil)
        (server
         (apply #'make-network-process
                :name "schwab-broker-listener"
                :server t
                :host host
                :service port
                :filter #'schwab-broker--listener-filter
                (when tls-parameters
                  (list :tls-parameters tls-parameters)))))
    (unwind-protect
        (progn
          (when on-listening
            (funcall on-listening server))
          (let ((deadline (+ (float-time) timeout)))
            (while (and (not schwab-broker--listener-result)
                        (< (float-time) deadline))
              (accept-process-output nil 0.2))
            (or
             schwab-broker--listener-result
             (signal
              'schwab-broker-error
              (list
               :timeout
               (format
                "Schwab OAuth callback listener timed out after %ss waiting for the redirect"
                timeout))))))
      (ignore-errors
        (delete-process server)))))

(defun schwab-broker--listener-ensure-tls-available ()
  "Signal `user-error': Emacs cannot terminate an inbound TLS connection.
Emacs's built-in GnuTLS integration only supports client-mode TLS, so
`schwab-broker-authorize-listen' cannot actually listen for Schwab's
`https' callback.  See the investigation notes above
`schwab-broker--listener-host-port' in this file for the evidence.  Use
`schwab-broker-authorize' (the paste flow) instead, or, if you also
have the tradeboards Python CLI installed, `tradeboards auth schwab
--listen' -- it uses Python's `ssl' module, which DOES support
server-role TLS."
  (user-error
   "Emacs's built-in GnuTLS only supports client-mode TLS (see `gnutls-boot's docstring) -- a genuine HTTPS-terminating OAuth callback listener is not implementable in pure Elisp today.  Use `schwab-broker-authorize' (the paste flow), or `tradeboards auth schwab --listen' from the tradeboards Python CLI if you have it installed"))

;;;###autoload
(defun schwab-broker-authorize-listen ()
  "Like `schwab-broker-authorize', but attempts to serve the callback directly.
Instead of prompting you to paste the redirect URL back -- Schwab's
`code=' parameter expires in about 30 seconds, and the paste
round-trip can lose that race (this happened live once, 2026-09-15,
motivating this command and its Python-CLI-side sibling `tradeboards
auth schwab --listen').

As of this writing, the LISTEN half of this command cannot actually
succeed: Emacs's built-in GnuTLS integration only supports client-mode
TLS, so it cannot terminate the inbound HTTPS connection Schwab's
callback URL requires -- see `schwab-broker--listener-ensure-tls-available'
and the investigation notes above `schwab-broker--listener-host-port' in
this file for the evidence.  This command still does the useful,
WORKING half -- opens the SAME authorize URL `schwab-broker-authorize'
would (`schwab-broker--authorize-url', no duplicated URL construction)
-- and then signals a clear `user-error' pointing you at
`schwab-broker-authorize' rather than hanging or silently failing
against a browser you have already sent to the consent page.  The
request-parsing/exchange/one-shot/timeout machinery this command would
use once real TLS support exists (`schwab-broker--listener-run' and its
siblings) is implemented and tested regardless."
  (interactive)
  (let ((url (schwab-broker--authorize-url)))
    (browse-url url)
    (message "Schwab: opened %s -- log in and approve access." url))
  (schwab-broker--listener-ensure-tls-available))

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
