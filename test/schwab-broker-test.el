;;; schwab-broker-test.el --- Tests for schwab-broker.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Every test here mocks the built-in `url-retrieve' -- the sole
;; network entry point in this package (`schwab-broker--http') -- so nothing
;; touches the real network or real credentials.  Canned JSON bodies
;; below are modeled on this package's reference Python-side sibling
;; implementation's own test fixtures (shapes only, values fabricated).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'schwab-broker)

;; -- shared test helpers --

(defun schwab-broker-test--response-buffer (status body)
  "Fill the current buffer to look like a raw HTTP response with
STATUS and BODY, mirroring what `url-retrieve' hands its callback."
  (setq-local url-http-response-status status)
  (insert (format "HTTP/1.1 %s x\r\nContent-Type: application/json\r\n\r\n" status) body))

(defun schwab-broker-test--mock-once (status body)
  "A `url-retrieve' replacement that always answers with STATUS/BODY."
  (lambda (_url callback &rest _args)
    (with-temp-buffer
      (schwab-broker-test--response-buffer status body)
      (funcall callback nil))))

(defun schwab-broker-test--mock-error (error-data)
  "A `url-retrieve' replacement that always answers with a network-level
ERROR-DATA (never reaching an HTTP response at all)."
  (lambda (_url callback &rest _args) (funcall callback (list :error error-data))))

(defun schwab-broker-test--mock-queued (queues)
  "A `url-retrieve' replacement dispatching by URL substring.  QUEUES is
an alist of (URL-SUBSTRING-REGEXP . RESPONSE-LIST), where each
RESPONSE-LIST entry is (STATUS . BODY), consumed in order -- each
matching substring's own queue advances independently, so a
retried call to the same endpoint can answer differently than the
first."
  (lambda (url callback &rest _args)
    (let ((entry (seq-find (lambda (e) (string-match-p (car e) url)) queues)))
      (unless entry (error "schwab-broker-test: no mock queue matches %s" url))
      (let ((response (pop (cdr entry))))
        (unless response (error "schwab-broker-test: mock queue exhausted for %s" url))
        (with-temp-buffer
          (schwab-broker-test--response-buffer (car response) (cdr response))
          (funcall callback nil))))))

(defun schwab-broker-test--fresh-token ()
  "A synthetic token alist whose access AND refresh tokens are both
still live (far-future expiries)."
  '((access_token . "AT.fake-access-token")
    (refresh_token . "RT.fake-refresh-token")
    (access_token_expires_at . "2099-01-01T00:00:00.000000+00:00")
    (refresh_token_expires_at . "2099-01-01T00:00:00.000000+00:00")
    (obtained_at . "2026-01-01T00:00:00.000000+00:00")))

(defmacro schwab-broker-test--with-temp-token-file (&rest body)
  "Run BODY with `schwab-broker-token-file' pointed at a fresh, nonexistent
temp path (and its lock directory) that is removed afterward."
  (declare (indent 0))
  `(let ((schwab-broker-token-file (make-temp-file "schwab-broker-test-token" nil ".json")))
     (delete-file schwab-broker-token-file)
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file schwab-broker-token-file))
       (ignore-errors (delete-directory (concat schwab-broker-token-file ".lock") t)))))

(defmacro schwab-broker-test--with-creds (&rest body)
  "Run BODY with fake app-key/app-secret configured."
  (declare (indent 0))
  `(let ((schwab-broker-app-key "test-app-key") (schwab-broker-app-secret "test-app-secret"))
     ,@body))

;; -- authorize-URL construction --

(ert-deftest schwab-broker-test-authorize-url-has-client-id-redirect-and-response-type ()
  (schwab-broker-test--with-creds
    (let ((schwab-broker-callback-url "https://127.0.0.1:3600"))
      (let ((url (schwab-broker--authorize-url)))
        (should (string-prefix-p "https://api.schwabapi.com/v1/oauth/authorize?" url))
        (should (string-match-p "client_id=test-app-key" url))
        (should (string-match-p "redirect_uri=https%3A%2F%2F127.0.0.1%3A3600" url))
        (should (string-match-p "response_type=code" url))))))

;; -- code extraction from a pasted redirect URL --

(ert-deftest schwab-broker-test-extract-code-from-redirect-url ()
  (should
   (equal
    (schwab-broker--extract-code "https://127.0.0.1:3600/?code=C0.abc123&session=xyz") "C0.abc123"))
  (should
   (equal (schwab-broker--extract-code "https://127.0.0.1:3600/?session=xyz&code=en%2Fcoded")
          "en/coded")))

(ert-deftest schwab-broker-test-extract-code-errors-without-code-param ()
  (should-error (schwab-broker--extract-code "https://127.0.0.1:3600/?session=xyz") :type 'user-error))

;; -- token exchange request shape (authorization_code grant) --

(ert-deftest schwab-broker-test-token-exchange-posts-basic-auth-and-form-body ()
  (schwab-broker-test--with-creds
    (schwab-broker-test--with-temp-token-file
      (let (captured-url captured-method captured-headers captured-data)
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (url callback &rest _args)
                     (setq captured-url url
                           captured-method url-request-method
                           captured-headers url-request-extra-headers
                           captured-data url-request-data)
                     (with-temp-buffer
                       (schwab-broker-test--response-buffer
                        200
                        (json-serialize
                         '((access_token . "AT.new") (refresh_token . "RT.new")
                           (expires_in . 1800))))
                       (funcall callback nil)))))
          (schwab-broker--sync-call
           (lambda (callback)
             (schwab-broker--post-oauth-token
              '(("grant_type" . "authorization_code") ("code" . "the-code")
                ("redirect_uri" . "https://127.0.0.1:3600"))
              callback))))
        (should (equal captured-url "https://api.schwabapi.com/v1/oauth/token"))
        (should (equal captured-method "POST"))
        (should
         (equal
          (alist-get "Authorization" captured-headers nil nil #'equal)
          (concat "Basic " (base64-encode-string "test-app-key:test-app-secret" t))))
        (should
         (equal
          (alist-get "Content-Type" captured-headers nil nil #'equal)
          "application/x-www-form-urlencoded"))
        (should (string-match-p "grant_type=authorization_code" captured-data))
        (should (string-match-p "code=the-code" captured-data))
        (should (string-match-p "redirect_uri=https%3A%2F%2F127.0.0.1%3A3600" captured-data))))))

;; -- refresh request shape --

(ert-deftest schwab-broker-test-refresh-posts-refresh-token-grant ()
  (schwab-broker-test--with-creds
    (let (captured-data)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &rest _args)
                   (setq captured-data url-request-data)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200
                      (json-serialize
                       '((access_token . "AT.refreshed") (refresh_token . "RT.refreshed")
                         (expires_in . 1800))))
                     (funcall callback nil)))))
        (schwab-broker--sync-call
         (lambda (callback)
           (schwab-broker--refresh
            '((refresh_token . "RT.fake-refresh-token")) callback))))
      (should (string-match-p "grant_type=refresh_token" captured-data))
      (should (string-match-p "refresh_token=RT.fake-refresh-token" captured-data)))))

(ert-deftest schwab-broker-test-token-from-oauth-response-signals-on-bad-shape ()
  (should-error (schwab-broker--token-from-oauth-response '((access_token . "x"))) :type 'schwab-broker-error))

;; -- token file round-trip, mode 600, expiry logic --

(ert-deftest schwab-broker-test-token-file-round-trips-and-is-mode-600 ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (should (equal (schwab-broker--read-token) (schwab-broker-test--fresh-token)))
    (should (= (logand (file-modes (schwab-broker-token-file-path)) #o777) #o600))))

(ert-deftest schwab-broker-test-read-token-nil-when-file-absent ()
  (schwab-broker-test--with-temp-token-file (should-not (schwab-broker--read-token))))

(ert-deftest schwab-broker-test-token-freshness-predicates ()
  (let ((fresh (schwab-broker-test--fresh-token))
        (stale
         '((access_token . "AT.old") (refresh_token . "RT.old")
           (access_token_expires_at . "2000-01-01T00:00:00.000000+00:00")
           (refresh_token_expires_at . "2000-01-01T00:00:00.000000+00:00"))))
    (should (schwab-broker--token-fresh-p fresh))
    (should (schwab-broker--refresh-token-live-p fresh))
    (should-not (schwab-broker--token-fresh-p stale))
    (should-not (schwab-broker--refresh-token-live-p stale))
    (should-not (schwab-broker--token-fresh-p nil))
    (should-not (schwab-broker--refresh-token-live-p nil))))

;; -- lockfile --

(ert-deftest schwab-broker-test-lock-acquire-then-release-round-trips ()
  (schwab-broker-test--with-temp-token-file
    (let ((lock (schwab-broker--acquire-lock)))
      (should (file-directory-p lock))
      (schwab-broker--release-lock)
      (should-not (file-exists-p lock)))))

(ert-deftest schwab-broker-test-lock-contention-times-out ()
  (schwab-broker-test--with-temp-token-file
    (let ((schwab-broker-lock-timeout 0.2))
      (make-directory (schwab-broker--lock-path))
      (unwind-protect
          (let ((err (should-error (schwab-broker--acquire-lock) :type 'schwab-broker-error)))
            (should (eq (car (cdr err)) :lock-timeout)))
        (ignore-errors (delete-directory (schwab-broker--lock-path)))))))

;; -- generic request plumbing: query-string / param mapping helpers --

(ert-deftest schwab-broker-test-query-string-drops-nil-values-and-hexifies ()
  (should
   (equal (schwab-broker--query-string '(("a" . "1") ("b" . nil) ("c" . "x y"))) "a=1&c=x%20y")))

(ert-deftest schwab-broker-test-bool-and-number-params ()
  (should (equal (schwab-broker--bool-param t) "true"))
  (should (equal (schwab-broker--bool-param :false) "false"))
  (should-not (schwab-broker--bool-param nil))
  (should (equal (schwab-broker--number-param 5) "5"))
  (should-not (schwab-broker--number-param nil)))

;; -- option-chain: full param-surface mapping --

(ert-deftest schwab-broker-test-option-chain-maps-full-param-surface ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 200 "{\"symbol\":\"AAPL\"}")
                     (funcall callback nil)))))
        (schwab-broker-option-chain-sync
         "aapl" :contract-type "CALL" :strike-count 5 :include-underlying-quote t
         :strategy "SINGLE" :interval 5 :strike 190 :range "ITM" :from-date "2026-10-01"
         :to-date "2026-10-31" :volatility 29 :underlying-price 191.52 :interest-rate 5.2
         :days-to-expiration 32 :exp-month "OCT" :option-type "S"))
      (should (string-prefix-p "https://api.schwabapi.com/marketdata/v1/chains?" captured-url))
      (dolist (expected
               '("symbol=AAPL" "contractType=CALL" "strikeCount=5"
                 "includeUnderlyingQuote=true" "strategy=SINGLE" "interval=5" "strike=190"
                 "range=ITM" "fromDate=2026-10-01" "toDate=2026-10-31" "volatility=29"
                 "underlyingPrice=191.52" "interestRate=5.2" "daysToExpiration=32"
                 "expMonth=OCT" "optionType=S"))
        (should (string-match-p (regexp-quote expected) captured-url))))))

;; -- 401 refresh-and-retry --

(ert-deftest schwab-broker-test-401-triggers-one-refresh-and-retry ()
  (schwab-broker-test--with-creds
    (schwab-broker-test--with-temp-token-file
      (schwab-broker--write-token (schwab-broker-test--fresh-token))
      (cl-letf (((symbol-function 'url-retrieve)
                 (schwab-broker-test--mock-queued
                  `(("/oauth/token"
                     . ((200
                        .
                        ,(json-serialize
                          '((access_token . "AT.rotated") (refresh_token . "RT.rotated")
                            (expires_in . 1800))))))
                    ("/AAPL/quotes"
                     .
                     ((401 . "{\"error\":\"unauthorized\"}")
                      (200
                       .
                       "{\"AAPL\":{\"quote\":{\"lastPrice\":191.52,\"mark\":191.52}}}")))))))
        (let ((result (schwab-broker-quote-sync "AAPL")))
          (should (equal (alist-get 'lastPrice (alist-get 'quote result)) 191.52))))
      ;; The rotated token from the refresh must have been persisted.
      (should (equal (alist-get 'access_token (schwab-broker--read-token)) "AT.rotated")))))

(ert-deftest schwab-broker-test-401-after-forced-refresh-signals ()
  (schwab-broker-test--with-creds
    (schwab-broker-test--with-temp-token-file
      (schwab-broker--write-token (schwab-broker-test--fresh-token))
      (cl-letf (((symbol-function 'url-retrieve)
                 (schwab-broker-test--mock-queued
                  `(("/oauth/token"
                     . ((200
                        .
                        ,(json-serialize
                          '((access_token . "AT.rotated") (refresh_token . "RT.rotated")
                            (expires_in . 1800))))))
                    ("/AAPL/quotes" . ((401 . "nope") (401 . "still nope")))))))
        (let ((err (should-error (schwab-broker-quote-sync "AAPL") :type 'schwab-broker-error)))
          (should (eq (car (cdr err)) :status)))))))

;; -- network-level failure --

(ert-deftest schwab-broker-test-network-error-signals-schwab-broker-error ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (cl-letf (((symbol-function 'url-retrieve)
               (schwab-broker-test--mock-error '(error "connection refused"))))
      (let ((err (should-error (schwab-broker-quote-sync "AAPL") :type 'schwab-broker-error)))
        (should (eq (car (cdr err)) :network-error))))))

(ert-deftest schwab-broker-test-not-authenticated-signals-without-network ()
  (schwab-broker-test--with-temp-token-file
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _) (error "must not be called"))))
      (let ((err (should-error (schwab-broker-quote-sync "AAPL") :type 'schwab-broker-error)))
        (should (eq (car (cdr err)) :not-authenticated))))))

;; -- sync timeout --

(ert-deftest schwab-broker-test-sync-call-times-out-when-callback-never-fires ()
  (let ((schwab-broker-http-timeout 0.1))
    (let ((err (should-error (schwab-broker--sync-call (lambda (_callback) nil)) :type 'schwab-broker-error)))
      (should (eq (car (cdr err)) :timeout)))))

;; -- parsing against canned JSON modeled on the reference fixtures --

(ert-deftest schwab-broker-test-quote-parses-reference-shaped-fixture ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (cl-letf (((symbol-function 'url-retrieve)
               (schwab-broker-test--mock-once
                200
                (json-serialize
                 '((AAPL
                    .
                    ((assetMainType . "EQUITY") (symbol . "AAPL")
                     (quote
                      .
                      ((lastPrice . 191.52) (mark . 191.52) (bidPrice . 191.5)
                       (askPrice . 191.55)))
                     (reference . ((exchangeName . "NASDAQ"))))))))))
      (let ((quote-data (schwab-broker-quote-sync "AAPL")))
        (should (equal (alist-get 'symbol quote-data) "AAPL"))
        (should (equal (alist-get 'lastPrice (alist-get 'quote quote-data)) 191.52))
        (should
         (equal (alist-get 'exchangeName (alist-get 'reference quote-data)) "NASDAQ"))))))

(ert-deftest schwab-broker-test-price-history-parses-reference-shaped-fixture ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (cl-letf (((symbol-function 'url-retrieve)
               (schwab-broker-test--mock-once
                200
                (json-serialize
                 '((symbol . "AAPL") (empty . :false)
                   (candles
                    .
                    [((open . 189.5) (high . 190.2) (low . 189.1) (close . 190.0)
                      (volume . 1234567) (datetime . 1757790000000))]))))))
      (let ((history
             (schwab-broker-price-history-sync
              "aapl" :period-type "month" :period 1 :frequency-type "daily" :frequency 1)))
        (should (equal (alist-get 'symbol history) "AAPL"))
        (should (= (length (alist-get 'candles history)) 1))
        (should
         (= (alist-get 'close (car (alist-get 'candles history))) 190.0))))))

(ert-deftest schwab-broker-test-account-numbers-parses-reference-shaped-fixture ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (cl-letf (((symbol-function 'url-retrieve)
               (schwab-broker-test--mock-once
                200
                (json-serialize
                 [((accountNumber . "12345678")
                   (hashValue . "ABCDEF0123456789ABCDEF0123456789"))]))))
      (let ((result (schwab-broker-account-numbers-sync)))
        (should (equal (alist-get 'accountNumber (car result)) "12345678"))))))

(ert-deftest schwab-broker-test-accounts-with-positions-parses-and-flattens ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200
                      (json-serialize
                       [((securitiesAccount
                          .
                          ((type . "MARGIN") (accountNumber . "12345678")
                           (positions
                            .
                            [((longQuantity . 10) (averagePrice . 150.25)
                              (instrument . ((symbol . "AAPL"))))])
                           (currentBalances . ((liquidationValue . 15234.75))))))]))
                     (funcall callback nil)))))
        (let ((positions (schwab-broker-positions-sync)))
          (should (string-match-p "fields=positions" captured-url))
          (should (= (length positions) 1))
          (should (equal (alist-get 'accountNumber (car positions)) "12345678"))
          (should
           (equal (alist-get 'symbol (alist-get 'instrument (car positions))) "AAPL")))))))

;; -- auth-status never prints secret values --

(ert-deftest schwab-broker-test-auth-status-reports-without-secrets ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (shown)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
        (schwab-broker-auth-status))
      (should (string-match-p "valid" shown))
      (should-not (string-match-p "AT.fake-access-token" shown))
      (should-not (string-match-p "RT.fake-refresh-token" shown)))))

(ert-deftest schwab-broker-test-auth-status-reports-when-absent ()
  (schwab-broker-test--with-temp-token-file
    (let (shown)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
        (schwab-broker-auth-status))
      (should (string-match-p "not authenticated" shown)))))

;; -- schwab-broker-authorize end-to-end (browser + paste + exchange + write) --

(ert-deftest schwab-broker-test-authorize-writes-token-from-pasted-redirect ()
  (schwab-broker-test--with-creds
    (schwab-broker-test--with-temp-token-file
      (let (browsed-url)
        (cl-letf (((symbol-function 'browse-url) (lambda (url) (setq browsed-url url)))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) "https://127.0.0.1:3600/?code=the-pasted-code"))
                  ((symbol-function 'url-retrieve)
                   (schwab-broker-test--mock-once
                    200
                    (json-serialize
                     '((access_token . "AT.authorized") (refresh_token . "RT.authorized")
                       (expires_in . 1800))))))
          (schwab-broker-authorize))
        (should (string-match-p "oauth/authorize" browsed-url))
        (should (equal (alist-get 'access_token (schwab-broker--read-token)) "AT.authorized"))))))

;; -- show-quote demo command --

(ert-deftest schwab-broker-test-show-quote-messages-last-price ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (cl-letf (((symbol-function 'url-retrieve)
               (schwab-broker-test--mock-once
                200
                (json-serialize
                 '((AAPL . ((quote . ((lastPrice . 191.52) (mark . 191.5))))))))))
      (let (shown)
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
          (schwab-broker-show-quote "AAPL"))
        (should (string-match-p "191.52" shown))))))

;; -- order-spec builders (pure functions, no network) --

(ert-deftest schwab-broker-test-order-spec-generic-shape ()
  (let ((spec
         (schwab-broker-order-spec
          :order-type "MARKET"
          :legs
          (list
           (schwab-broker--order-leg
            "BUY" 1 (schwab-broker--equity-instrument "aapl"))))))
    (should (equal (alist-get 'orderType spec) "MARKET"))
    (should (equal (alist-get 'session spec) "NORMAL"))
    (should (equal (alist-get 'duration spec) "DAY"))
    (should (equal (alist-get 'orderStrategyType spec) "SINGLE"))
    (should-not (alist-get 'price spec))
    (should-not (alist-get 'stopPrice spec))
    (let ((leg (aref (alist-get 'orderLegCollection spec) 0)))
      (should (equal (alist-get 'instruction leg) "BUY"))
      (should (= (alist-get 'quantity leg) 1))
      (should
       (equal (alist-get 'symbol (alist-get 'instrument leg)) "AAPL"))
      (should
       (equal (alist-get 'assetType (alist-get 'instrument leg)) "EQUITY")))))

(ert-deftest schwab-broker-test-order-equity-market-shape ()
  (let ((spec (schwab-broker-order-equity-market "aapl" "BUY" 10)))
    (should (equal (alist-get 'orderType spec) "MARKET"))
    (should-not (alist-get 'price spec))
    (should
     (equal
      (alist-get
       'symbol
       (alist-get
        'instrument (aref (alist-get 'orderLegCollection spec) 0)))
      "AAPL"))))

(ert-deftest schwab-broker-test-order-equity-limit-shape ()
  (let ((spec (schwab-broker-order-equity-limit "aapl" "BUY" 10 150.25)))
    (should (equal (alist-get 'orderType spec) "LIMIT"))
    (should (= (alist-get 'price spec) 150.25))))

(ert-deftest schwab-broker-test-order-equity-stop-shape ()
  (let ((spec (schwab-broker-order-equity-stop "aapl" "SELL" 10 140.0)))
    (should (equal (alist-get 'orderType spec) "STOP"))
    (should (= (alist-get 'stopPrice spec) 140.0))
    (should-not (alist-get 'price spec))))

(ert-deftest schwab-broker-test-order-equity-stop-limit-shape ()
  (let ((spec
         (schwab-broker-order-equity-stop-limit "aapl" "SELL" 10 140.0 139.5)))
    (should (equal (alist-get 'orderType spec) "STOP_LIMIT"))
    (should (= (alist-get 'stopPrice spec) 140.0))
    (should (= (alist-get 'price spec) 139.5))))

(ert-deftest schwab-broker-test-order-option-market-shape ()
  (let ((spec
         (schwab-broker-order-option-market
          "aapl  251017c00150000" "BUY_TO_OPEN" 1)))
    (should (equal (alist-get 'orderType spec) "MARKET"))
    (should
     (equal
      (alist-get
       'assetType
       (alist-get
        'instrument (aref (alist-get 'orderLegCollection spec) 0)))
      "OPTION"))))

(ert-deftest schwab-broker-test-order-option-limit-shape ()
  (let ((spec
         (schwab-broker-order-option-limit
          "AAPL  251017C00150000" "SELL_TO_CLOSE" 1 2.5)))
    (should (equal (alist-get 'orderType spec) "LIMIT"))
    (should (= (alist-get 'price spec) 2.5))))

;; -- single account --

(ert-deftest schwab-broker-test-account-fetches-by-hash ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200
                      (json-serialize
                       '((securitiesAccount
                          . ((type . "MARGIN") (accountNumber . "12345678"))))))
                     (funcall callback nil)))))
        (let ((result (schwab-broker-account-sync "HASH123" :positions t)))
          (should
           (string-prefix-p
            "https://api.schwabapi.com/trader/v1/accounts/HASH123?"
            captured-url))
          (should (string-match-p "fields=positions" captured-url))
          (should
           (equal
            (alist-get
             'accountNumber (alist-get 'securitiesAccount result))
            "12345678")))))))

;; -- orders: list per-account, get one, and across all accounts --

(ert-deftest schwab-broker-test-orders-for-account-maps-params ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 200 "[]")
                     (funcall callback nil)))))
        (schwab-broker-orders-for-account-sync
         "HASH123" :max-results 5 :from-entered-time "2026-09-01T00:00:00.000Z"
         :to-entered-time "2026-09-28T00:00:00.000Z" :status "WORKING"))
      (should
       (string-prefix-p
        "https://api.schwabapi.com/trader/v1/accounts/HASH123/orders?"
        captured-url))
      (dolist (expected
               '("maxResults=5" "fromEnteredTime=" "toEnteredTime="
                 "status=WORKING"))
        (should (string-match-p (regexp-quote expected) captured-url))))))

(ert-deftest schwab-broker-test-order-fetches-single-order-by-id ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((orderId . 987) (status . "FILLED"))))
                     (funcall callback nil)))))
        (let ((result (schwab-broker-order-sync "HASH123" 987)))
          (should
           (equal
            captured-url
            "https://api.schwabapi.com/trader/v1/accounts/HASH123/orders/987"))
          (should (equal (alist-get 'status result) "FILLED")))))))

(ert-deftest schwab-broker-test-orders-across-all-accounts-maps-params ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 200 "[]")
                     (funcall callback nil)))))
        (schwab-broker-orders-sync
         :from-entered-time "2026-09-01T00:00:00.000Z"
         :to-entered-time "2026-09-28T00:00:00.000Z"))
      (should
       (string-prefix-p
        "https://api.schwabapi.com/trader/v1/orders?" captured-url)))))

;; -- order safety gate: place/replace/cancel --

(ert-deftest schwab-broker-test-place-order-refuses-without-allow-orders ()
  (schwab-broker-test--with-temp-token-file
    (let ((schwab-broker-allow-orders nil))
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (&rest _) (error "must not be called"))))
        (should-error
         (schwab-broker-place-order-sync
          "HASH123" (schwab-broker-order-equity-market "AAPL" "BUY" 1))
         :type 'user-error)))))

(ert-deftest schwab-broker-test-replace-order-refuses-without-allow-orders ()
  (schwab-broker-test--with-temp-token-file
    (let ((schwab-broker-allow-orders nil))
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (&rest _) (error "must not be called"))))
        (should-error
         (schwab-broker-replace-order-sync
          "HASH123" 987 (schwab-broker-order-equity-market "AAPL" "BUY" 1))
         :type 'user-error)))))

(ert-deftest schwab-broker-test-cancel-order-refuses-without-allow-orders ()
  (schwab-broker-test--with-temp-token-file
    (let ((schwab-broker-allow-orders nil))
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (&rest _) (error "must not be called"))))
        (should-error
         (schwab-broker-cancel-order-sync "HASH123" 987) :type 'user-error)))))

(ert-deftest schwab-broker-test-place-order-posts-json-body-when-allowed ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let ((schwab-broker-allow-orders t)
          captured-url captured-method captured-headers captured-data)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url
                         captured-method url-request-method
                         captured-headers url-request-extra-headers
                         captured-data url-request-data)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 201 "")
                     (funcall callback nil)))))
        (schwab-broker-place-order-sync
         "HASH123" (schwab-broker-order-equity-market "AAPL" "BUY" 1)))
      (should
       (equal
        captured-url
        "https://api.schwabapi.com/trader/v1/accounts/HASH123/orders"))
      (should (equal captured-method "POST"))
      (should
       (equal
        (alist-get "Content-Type" captured-headers nil nil #'equal)
        "application/json"))
      (should (string-match-p "\"orderType\":\"MARKET\"" captured-data))
      (should (string-match-p "\"symbol\":\"AAPL\"" captured-data)))))

(ert-deftest schwab-broker-test-replace-order-puts-json-body-when-allowed ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let ((schwab-broker-allow-orders t)
          captured-url captured-method)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url captured-method url-request-method)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 200 "")
                     (funcall callback nil)))))
        (schwab-broker-replace-order-sync
         "HASH123" 987 (schwab-broker-order-equity-limit "AAPL" "BUY" 1 150.0)))
      (should
       (equal
        captured-url
        "https://api.schwabapi.com/trader/v1/accounts/HASH123/orders/987"))
      (should (equal captured-method "PUT")))))

(ert-deftest schwab-broker-test-cancel-order-deletes-when-allowed ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let ((schwab-broker-allow-orders t)
          captured-url captured-method)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url captured-method url-request-method)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 200 "")
                     (funcall callback nil)))))
        (schwab-broker-cancel-order-sync "HASH123" 987))
      (should
       (equal
        captured-url
        "https://api.schwabapi.com/trader/v1/accounts/HASH123/orders/987"))
      (should (equal captured-method "DELETE")))))

;; -- preview order: never gated --

(ert-deftest schwab-broker-test-preview-order-never-gated ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let ((schwab-broker-allow-orders nil)
          captured-url captured-method)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url captured-method url-request-method)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((orderValue . 150.0))))
                     (funcall callback nil)))))
        (let ((result
               (schwab-broker-preview-order-sync
                "HASH123" (schwab-broker-order-equity-market "AAPL" "BUY" 1))))
          (should
           (equal
            captured-url
            "https://api.schwabapi.com/trader/v1/accounts/HASH123/previewOrder"))
          (should (equal captured-method "POST"))
          (should (= (alist-get 'orderValue result) 150.0)))))))

;; -- transactions --

(ert-deftest schwab-broker-test-transactions-maps-params ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer 200 "[]")
                     (funcall callback nil)))))
        (schwab-broker-transactions-sync
         "HASH123" :start-date "2026-09-01T00:00:00.000Z"
         :end-date "2026-09-28T00:00:00.000Z" :symbol "AAPL" :types "TRADE"))
      (should
       (string-prefix-p
        "https://api.schwabapi.com/trader/v1/accounts/HASH123/transactions?"
        captured-url))
      (dolist (expected '("startDate=" "endDate=" "symbol=AAPL" "types=TRADE"))
        (should (string-match-p (regexp-quote expected) captured-url))))))

(ert-deftest schwab-broker-test-transaction-fetches-single-by-id ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((activityId . 555))))
                     (funcall callback nil)))))
        (let ((result (schwab-broker-transaction-sync "HASH123" 555)))
          (should
           (equal
            captured-url
            "https://api.schwabapi.com/trader/v1/accounts/HASH123/transactions/555"))
          (should (= (alist-get 'activityId result) 555)))))))

;; -- user preference --

(ert-deftest schwab-broker-test-user-preference-fetches ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200
                      (json-serialize
                       '((accounts . [((accountNumber . "12345678"))]))))
                     (funcall callback nil)))))
        (let ((result (schwab-broker-user-preference-sync)))
          (should
           (equal
            captured-url "https://api.schwabapi.com/trader/v1/userPreference"))
          (should
           (equal
            (alist-get
             'accountNumber (car (alist-get 'accounts result)))
            "12345678")))))))

;; -- market data: expiration chain, single market, instruments --

(ert-deftest schwab-broker-test-expiration-chain-fetches-by-symbol ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((status . "SUCCESS"))))
                     (funcall callback nil)))))
        (schwab-broker-expiration-chain-sync "aapl"))
      (should
       (string-prefix-p
        "https://api.schwabapi.com/marketdata/v1/expirationchain?"
        captured-url))
      (should (string-match-p "symbol=AAPL" captured-url)))))

(ert-deftest schwab-broker-test-market-fetches-single-market-id ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((equity . ((isOpen . t))))))
                     (funcall callback nil)))))
        (schwab-broker-market-sync "equity" :date "2026-09-28"))
      (should
       (string-prefix-p
        "https://api.schwabapi.com/marketdata/v1/markets/equity?"
        captured-url))
      (should (string-match-p "date=2026-09-28" captured-url)))))

(ert-deftest schwab-broker-test-instruments-searches-by-symbol-and-projection ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((instruments . []))))
                     (funcall callback nil)))))
        (schwab-broker-instruments-sync "AAPL" "symbol-search"))
      (should
       (string-prefix-p
        "https://api.schwabapi.com/marketdata/v1/instruments?" captured-url))
      (should (string-match-p "symbol=AAPL" captured-url))
      (should (string-match-p "projection=symbol-search" captured-url)))))

(ert-deftest schwab-broker-test-instrument-fetches-by-cusip ()
  (schwab-broker-test--with-temp-token-file
    (schwab-broker--write-token (schwab-broker-test--fresh-token))
    (let (captured-url)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (url callback &rest _args)
                   (setq captured-url url)
                   (with-temp-buffer
                     (schwab-broker-test--response-buffer
                      200 (json-serialize '((cusip . "037833100"))))
                     (funcall callback nil)))))
        (let ((result (schwab-broker-instrument-sync "037833100")))
          (should
           (equal
            captured-url
            "https://api.schwabapi.com/marketdata/v1/instruments/037833100"))
          (should (equal (alist-get 'cusip result) "037833100")))))))

(provide 'schwab-broker-test)
;;; schwab-broker-test.el ends here
