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

(provide 'schwab-broker-margin-test)
;;; schwab-broker-margin-test.el ends here
