;;; schwab-broker-margin-test.el --- Tests for schwab-broker-margin.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline, pure.  Vectors come from the CBOE "Margin Requirement
;; Examples" PDF (AAPL close 127.83 on 2021-01-19; the CBOE figures are
;; NET of option credit) and Schwab's published tables.  See
;; docs/margin.md.

;;; Code:

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
(require 'schwab-broker-margin)

(defun schwab-broker-margin-test--near (a b &optional tol)
  "Non-nil when A and B differ by at most TOL (default 0.01)."
  (<= (abs (- a b)) (or tol 0.01)))

(ert-deftest schwab-broker-margin-short-put-cboe-aapl ()
  "CBOE: short 100 AAPL Mar 130 puts @ 8.94 -> $255,660 (net)."
  (let ((r (schwab-broker-margin-short-put :strike 130 :premium 8.94
                                           :underlying 127.83 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get r :net) 255660.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get r :gross) 345060.0 0.5))))

(ert-deftest schwab-broker-margin-short-call-cboe-aapl ()
  "CBOE: short 100 AAPL Mar 130 calls @ 6.65 -> $233,960 (net)."
  (let ((r (schwab-broker-margin-short-call :strike 130 :premium 6.65
                                            :underlying 127.83 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get r :net) 233960.0 0.5))))

(ert-deftest schwab-broker-margin-short-put-otm-nvda ()
  "Research note: NVDA 175.99, Nov13 170P @2.97 -> gross 3,217.8, net 2,920.8."
  (let ((r (schwab-broker-margin-short-put :strike 170 :premium 2.97
                                           :underlying 175.99)))
    (should (schwab-broker-margin-test--near (plist-get r :leg-pct) 3217.8))
    (should (schwab-broker-margin-test--near (plist-get r :leg-min) 1997.0))
    (should (schwab-broker-margin-test--near (plist-get r :gross) 3217.8))
    (should (schwab-broker-margin-test--near (plist-get r :net) 2920.8))))

(ert-deftest schwab-broker-margin-short-put-min-leg-binds ()
  "Deep OTM: the 10%-of-strike leg binds."
  (let ((r (schwab-broker-margin-short-put :strike 50 :premium 0.10
                                           :underlying 100)))
    (should (schwab-broker-margin-test--near (plist-get r :gross) 510.0))))

(ert-deftest schwab-broker-margin-covered-call-cboe-aapl ()
  "CBOE: long 10,000 AAPL @127.83 + short 100 Mar 130C @6.65 -> $572,650.
Stock initial 50% less the call credit."
  (let* ((st (schwab-broker-margin-stock-long :price 127.83 :qty 10000))
         (cc (schwab-broker-margin-covered-call :strike 130 :premium 6.65
                                                :underlying 127.83 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get st :initial) 639150.0 0.5))
    (should (schwab-broker-margin-test--near
             (- (+ (plist-get st :initial) (plist-get cc :initial))
                (plist-get cc :credit))
             572650.0 0.5))))

(ert-deftest schwab-broker-margin-csp-reserve ()
  "NVDA 170P @2.97: reserve 17,000 - 297 = 16,703; no margin requirement."
  (let ((r (schwab-broker-margin-cash-secured-put :strike 170 :premium 2.97)))
    (should (schwab-broker-margin-test--near (plist-get r :cash-reserve) 16703.0))
    (should (= 0.0 (plist-get r :maintenance)))))

(ert-deftest schwab-broker-margin-long-option ()
  "Paid in full by default; FINRA 75% minimum applies only beyond 9 months."
  (let ((a (schwab-broker-margin-long-option :price 6.33 :qty 100))
        (b (schwab-broker-margin-long-option :price 20 :months-to-expiry 12
                                             :leaps-margin-pct 0.75))
        (c (schwab-broker-margin-long-option :price 20 :months-to-expiry 6
                                             :leaps-margin-pct 0.75)))
    (should (schwab-broker-margin-test--near (plist-get a :initial) 63300.0))
    (should (schwab-broker-margin-test--near (plist-get b :initial) 1500.0))
    (should (schwab-broker-margin-test--near (plist-get b :loan-value) 500.0))
    (should (schwab-broker-margin-test--near (plist-get c :initial) 2000.0))))

(ert-deftest schwab-broker-margin-stock-long ()
  "Schwab: 50% initial, 25% maintenance; house 50%; < $3 is 100%."
  (let ((r (schwab-broker-margin-stock-long :price 127.83 :qty 10000))
        (h (schwab-broker-margin-stock-long :price 100 :qty 10 :house-pct 0.5))
        (p (schwab-broker-margin-stock-long :price 2 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get r :maintenance) 319575.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get h :maintenance) 500.0))
    (should (schwab-broker-margin-test--near (plist-get p :initial) 200.0))))

(ert-deftest schwab-broker-margin-stock-short ()
  "Schwab short-sale maintenance tiers."
  (should (schwab-broker-margin-test--near
           (plist-get (schwab-broker-margin-stock-short :price 100 :qty 10) :maintenance) 300.0))
  (should (schwab-broker-margin-test--near
           (plist-get (schwab-broker-margin-stock-short :price 10 :qty 10) :maintenance) 50.0))
  (should (schwab-broker-margin-test--near
           (plist-get (schwab-broker-margin-stock-short :price 3 :qty 10) :maintenance) 30.0))
  (should (schwab-broker-margin-test--near
           (plist-get (schwab-broker-margin-stock-short :price 2 :qty 10) :maintenance) 25.0))
  (should (schwab-broker-margin-test--near
           (plist-get (schwab-broker-margin-stock-short :price 100 :qty 10) :initial) 500.0)))

(ert-deftest schwab-broker-margin-account-simple ()
  "Cash 10,000 + long 100 sh @100: equity 20,000, init 5,000, maint 2,500."
  (let ((a (schwab-broker-margin-account
            :cash 10000.0
            :positions (list (schwab-broker-margin-stock-long :price 100 :qty 100)))))
    (should (schwab-broker-margin-test--near (plist-get a :equity) 20000.0))
    (should (schwab-broker-margin-test--near (plist-get a :maintenance-excess) 17500.0))
    (should (schwab-broker-margin-test--near (plist-get a :option-bp) 15000.0))
    (should (schwab-broker-margin-test--near (plist-get a :stock-bp) 30000.0))
    (should (schwab-broker-margin-test--near (plist-get a :intraday-bp) 70000.0))
    (should-not (plist-get a :margin-call))))

(ert-deftest schwab-broker-margin-account-margin-call ()
  "Maintenance excess below zero flags a call and zeroes intraday BP."
  (let ((a (schwab-broker-margin-account
            :cash -9000.0
            :positions (list (schwab-broker-margin-stock-long :price 100 :qty 100)))))
    (should (plist-get a :margin-call))
    (should (= 0.0 (plist-get a :intraday-bp)))))

(ert-deftest schwab-broker-margin-account-csp-reserve ()
  "A cash-secured put reserves its assignment value out of option BP."
  (let ((a (schwab-broker-margin-account
            :cash 20000.0
            :positions (list (schwab-broker-margin-cash-secured-put
                              :strike 100 :premium 1.0)))))
    (should (schwab-broker-margin-test--near (plist-get a :option-bp) (- 19900.0 9900.0)))))

;; -- Screenshot reconciliation (Schwab screen, 2026-11-09 ~15:10 CT) --
;; Observed: Account Value 51,273.22; Option BP 23,072.99; Stock BP
;; 46,145.98; Intraday BP 141,966.20.  Holdings: SGOV 491 sh @ ~100.50,
;; short 1x NVDA 11/13 165P @1.04, NVDA ~178.9.  Cash was NOT observed:
;; it is derived from Account Value (51,273.22 - SGOV value + put
;; liability) = 2,031.72.  See docs/margin.md "Screenshot reconciliation".

(defconst schwab-broker-margin-test--observed
  '(:equity 51273.22 :option-bp 23072.99 :stock-bp 46145.98
    :intraday-bp 141966.20))

(defun schwab-broker-margin-test--screenshot (&rest extras)
  "Compute the screenshot account with EXTRAS passed to the account fn."
  (apply #'schwab-broker-margin-account
         :cash (+ (- 51273.22 (* 491 100.5)) 104.0)
         :positions (list (schwab-broker-margin-stock-long :price 100.5 :qty 491)
                          (schwab-broker-margin-short-put
                           :strike 165 :premium 1.04 :underlying 178.9))
         extras))

(ert-deftest schwab-broker-margin-screenshot-published-rules ()
  "Published rules reproduce equity exactly and the rest within a known gap."
  (let* ((c (schwab-broker-margin-test--screenshot))
         (res (schwab-broker-margin-reconcile
               schwab-broker-margin-test--observed c)))
    (should (schwab-broker-margin-test--near (plist-get c :equity) 51273.22))
    ;; put requirement: 20% leg binds: 3,578 - 1,390 + 104 = 2,292
    (should (schwab-broker-margin-test--near
             (plist-get c :maintenance-requirement) (+ 12336.375 2292.0)))
    ;; Schwab's own numbers are internally consistent: Stock BP = 2 x Option BP
    (should (schwab-broker-margin-test--near 46145.98 (* 2 23072.99)))
    ;; Schwab intraday BP / 4 = the maintenance excess Schwab used
    (should (schwab-broker-margin-test--near (/ 141966.20 4) 35491.55))
    ;; Documented residuals (observed - computed), the unexplained house gap:
    (should (schwab-broker-margin-test--near
             (nth 3 (assq :option-bp res)) -1235.48))
    (should (schwab-broker-margin-test--near
             (nth 3 (assq :stock-bp res)) -2470.96))
    (should (schwab-broker-margin-test--near
             (nth 3 (assq :intraday-bp res)) -4613.18))))

(ert-deftest schwab-broker-margin-screenshot-fitted-house-extra ()
  "FITTED, not published: explicit house add-ons close every number."
  (let ((c (schwab-broker-margin-test--screenshot
            :house-extra-initial 1235.48 :house-extra-maintenance 1153.295)))
    (should (schwab-broker-margin-test--near (plist-get c :option-bp) 23072.99))
    (should (schwab-broker-margin-test--near (plist-get c :stock-bp) 46145.98))
    (should (schwab-broker-margin-test--near (plist-get c :intraday-bp) 141966.20))))

(provide 'schwab-broker-margin-test)
;;; schwab-broker-margin-test.el ends here
