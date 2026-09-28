;;; schwab-broker-live-test.el --- LIVE tests against the real Schwab API -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests hit Schwab's REAL production API, with REAL credentials,
;; against a REAL brokerage account -- there is no sandbox.  Every test
;; here skips itself (via `ert-skip') unless a token file with a
;; still-live refresh token exists at `schwab-broker-token-file'
;; (default ~/.config/schwab/token.json); nothing in this file ever
;; touches the network without one.  This file MUST NEVER run in CI --
;; .github/workflows/test.yml only ever loads
;; test/schwab-broker-test.el, never anything under test/live/.
;;
;; HARD RULES enforced by construction:
;;   - every read endpoint is exercised live;
;;   - `schwab-broker-preview-order' is exercised live with a realistic
;;     order spec -- Schwab's own `/previewOrder' only simulates and
;;     places nothing;
;;   - `schwab-broker-place-order'/`schwab-broker-replace-order'/
;;     `schwab-broker-cancel-order' are NEVER called anywhere in this
;;     file, full stop.  Their request shape is instead covered by the
;;     mocked ERT suite in test/schwab-broker-test.el, and this file's
;;     `schwab-broker-live-test-preview-order' exercises the same kind
;;     of order spec end-to-end against the real API without ever
;;     placing it.
;;
;; Run via test/live/run-live-tests.sh, which resolves
;; SCHWAB_APP_KEY/SCHWAB_SECRET from David's credential resolver and
;; exports them only into this file's Emacs subprocess, or by hand:
;;
;;   SCHWAB_APP_KEY=... SCHWAB_SECRET=... \
;;     emacs -Q --batch -L . -L test -L test/live \
;;       -l test/live/schwab-broker-live-test.el \
;;       -f ert-run-tests-batch-and-exit
;;
;; If `M-x schwab-broker-auth-status' reports the refresh token
;; expired, run `M-x schwab-broker-authorize' interactively first --
;; the authorization code it needs expires in ~30s, so that step
;; cannot be scripted headlessly.  Never printed anywhere in this
;; file: token contents, app key, or app secret.

;;; Code:

(require 'ert)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../.." here)))
(require 'schwab-broker)

(defvar schwab-broker-live-test--symbol "AAPL"
  "Symbol used for live market-data reads.")

(defvar schwab-broker-live-test--cusip "037833100"
  "A real CUSIP (AAPL's) used for the live single-instrument read.")

(defvar schwab-broker-live-test--account-hash-cache nil
  "Cached first account hash, resolved once per batch run.")

(defun schwab-broker-live-test--iso-days-ago (days)
  "Return an ISO-8601 UTC timestamp DAYS days before now."
  (format-time-string
   "%Y-%m-%dT%H:%M:%S.000Z" (- (float-time) (* days 86400)) t))

(defun schwab-broker-live-test--iso-now ()
  "Return the current time as an ISO-8601 UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S.000Z" nil t))

(defun schwab-broker-live-test--skip-unless-authenticated ()
  "Skip the current test unless a live-refresh-token token file exists."
  (let ((token (schwab-broker--read-token)))
    (unless (and token (schwab-broker--refresh-token-live-p token))
      (ert-skip
       (format
        "schwab-broker live: no live refresh token at %s -- run `M-x schwab-broker-authorize'"
        (schwab-broker-token-file-path))))))

(defun schwab-broker-live-test--account-hash ()
  "Return the first account's hash value, fetching and caching it once."
  (or schwab-broker-live-test--account-hash-cache
      (let* ((accounts (schwab-broker-account-numbers-sync))
             (hash (alist-get 'hashValue (car accounts))))
        (unless hash
          (ert-fail
           "schwab-broker live: no account hash from /accounts/accountNumbers"))
        (setq schwab-broker-live-test--account-hash-cache hash))))

(defmacro schwab-broker-live-test-deftest (name &rest body)
  "Define a live ERT test NAME that auto-skips without a live token.
BODY, the test's actual assertions, runs only once authenticated."
  (declare (indent 1))
  `(ert-deftest ,name ()
     (schwab-broker-live-test--skip-unless-authenticated)
     ,@body))

;; -- market data: quotes, history, chains, movers, market hours,
;;    instruments --

(schwab-broker-live-test-deftest schwab-broker-live-test-quote
  (let ((result (schwab-broker-quote-sync schwab-broker-live-test--symbol)))
    (should (alist-get 'quote result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-quotes
  (let ((result
         (schwab-broker-quotes-sync
          (list schwab-broker-live-test--symbol "MSFT"))))
    (should (alist-get (intern schwab-broker-live-test--symbol) result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-price-history
  (let ((result
         (schwab-broker-price-history-sync
          schwab-broker-live-test--symbol
          :period-type "month" :period 1 :frequency-type "daily"
          :frequency 1)))
    (should (alist-get 'candles result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-option-chain
  (let ((result
         (schwab-broker-option-chain-sync
          schwab-broker-live-test--symbol :contract-type "CALL"
          :strike-count 3)))
    (should (alist-get 'symbol result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-expiration-chain
  (let ((result
         (schwab-broker-expiration-chain-sync schwab-broker-live-test--symbol)))
    (should result)))

(schwab-broker-live-test-deftest schwab-broker-live-test-movers
  (let ((result (schwab-broker-movers-sync "$SPX")))
    (should result)))

(schwab-broker-live-test-deftest schwab-broker-live-test-market-hours
  (let ((result (schwab-broker-market-hours-sync '("equity"))))
    (should (alist-get 'equity result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-market
  (let ((result (schwab-broker-market-sync "equity")))
    (should (alist-get 'equity result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-instruments
  (let ((result
         (schwab-broker-instruments-sync
          schwab-broker-live-test--symbol "symbol-search")))
    (should (alist-get 'instruments result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-instrument
  (let ((result
         (schwab-broker-instrument-sync schwab-broker-live-test--cusip)))
    (should result)))

;; -- accounts / positions --

(schwab-broker-live-test-deftest schwab-broker-live-test-account-numbers
  (let ((result (schwab-broker-account-numbers-sync)))
    (should result)
    (should (alist-get 'hashValue (car result)))))

(schwab-broker-live-test-deftest schwab-broker-live-test-accounts
  (let ((result (schwab-broker-accounts-sync)))
    (should result)))

(schwab-broker-live-test-deftest schwab-broker-live-test-account
  (let ((result
         (schwab-broker-account-sync (schwab-broker-live-test--account-hash))))
    (should (alist-get 'securitiesAccount result))))

(schwab-broker-live-test-deftest schwab-broker-live-test-positions
  ;; May legitimately be empty; must simply not error.
  (schwab-broker-positions-sync)
  (should t))

;; -- orders: list only, never place/replace/cancel --

(schwab-broker-live-test-deftest schwab-broker-live-test-orders-for-account
  (schwab-broker-orders-for-account-sync
   (schwab-broker-live-test--account-hash)
   :from-entered-time (schwab-broker-live-test--iso-days-ago 7)
   :to-entered-time (schwab-broker-live-test--iso-now))
  (should t))

(schwab-broker-live-test-deftest schwab-broker-live-test-orders-all-accounts
  (schwab-broker-orders-sync
   :from-entered-time (schwab-broker-live-test--iso-days-ago 7)
   :to-entered-time (schwab-broker-live-test--iso-now))
  (should t))

;; -- previewOrder: simulates only, safe to run live --

(schwab-broker-live-test-deftest schwab-broker-live-test-preview-order
  (let* ((spec
          (schwab-broker-order-equity-limit
           schwab-broker-live-test--symbol "BUY" 1 1.00))
         (result
          (schwab-broker-preview-order-sync
           (schwab-broker-live-test--account-hash) spec)))
    (should result)))

;; -- transactions --

(schwab-broker-live-test-deftest schwab-broker-live-test-transactions
  (schwab-broker-transactions-sync
   (schwab-broker-live-test--account-hash)
   :start-date (schwab-broker-live-test--iso-days-ago 30)
   :end-date (schwab-broker-live-test--iso-now))
  (should t))

;; -- user preference --

(schwab-broker-live-test-deftest schwab-broker-live-test-user-preference
  (let ((result (schwab-broker-user-preference-sync)))
    (should result)))

(provide 'schwab-broker-live-test)
;;; schwab-broker-live-test.el ends here
