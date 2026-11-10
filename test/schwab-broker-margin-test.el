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

(ert-deftest schwab-broker-margin-vertical-debit-cboe-aapl ()
  "CBOE: long 100 Mar 125C @9.05, short 100 Mar 135C @4.75 -> $43,000."
  (let ((r (schwab-broker-margin-vertical :kind 'call :long-strike 125
                                          :short-strike 135 :long-price 9.05
                                          :short-price 4.75 :qty 100)))
    (should (eq (plist-get r :type) 'vertical-debit))
    (should (schwab-broker-margin-test--near (plist-get r :initial) 43000.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get r :max-loss) 43000.0 0.5))))

(ert-deftest schwab-broker-margin-vertical-credit ()
  "Credit call spread (arithmetic, not a CBOE vector): short 125C @9.05,
long 135C @4.75, 100 lots: width 100,000, credit 43,000, max loss 57,000."
  (let ((r (schwab-broker-margin-vertical :kind 'call :long-strike 135
                                          :short-strike 125 :long-price 4.75
                                          :short-price 9.05 :qty 100)))
    (should (eq (plist-get r :type) 'vertical-credit))
    (should (schwab-broker-margin-test--near (plist-get r :initial) 100000.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get r :net) 57000.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get r :market-value) -43000.0 0.5))))

(ert-deftest schwab-broker-margin-vertical-put-credit ()
  "Bull put spread: short 125P @6.33, long 120P @4.30, 1 lot: 500, loss 297."
  (let ((r (schwab-broker-margin-vertical :kind 'put :long-strike 120
                                          :short-strike 125 :long-price 4.30
                                          :short-price 6.33)))
    (should (eq (plist-get r :type) 'vertical-credit))
    (should (schwab-broker-margin-test--near (plist-get r :initial) 500.0))
    (should (schwab-broker-margin-test--near (plist-get r :max-loss) 297.0))))

(ert-deftest schwab-broker-margin-straddle-cboe-aapl ()
  "CBOE AAPL Mar 130: short straddle 255,660 (net), long straddle 155,900."
  (let ((s (schwab-broker-margin-straddle :strike 130 :put-price 8.94
                                          :call-price 6.65 :underlying 127.83
                                          :qty 100))
        (l (schwab-broker-margin-straddle :side 'long :strike 130
                                          :put-price 8.94 :call-price 6.65
                                          :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get s :net) 255660.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get s :gross) 411560.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get l :initial) 155900.0 0.5))))

(ert-deftest schwab-broker-margin-strangle-cboe-aapl ()
  "CBOE AAPL Mar 125P/135C: short strangle 227,360 (net), long 110,800."
  (let ((s (schwab-broker-margin-strangle :put-strike 125 :call-strike 135
                                          :put-price 6.33 :call-price 4.75
                                          :underlying 127.83 :qty 100))
        (l (schwab-broker-margin-strangle :side 'long :put-strike 125
                                          :call-strike 135 :put-price 6.33
                                          :call-price 4.75 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get s :net) 227360.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get l :initial) 110800.0 0.5))))

(ert-deftest schwab-broker-margin-iron-condor-cboe-aapl ()
  "CBOE AAPL short iron condors: 120/125/130/135 -> 10,700; 115/125/130/140 -> 32,300."
  (let ((a (schwab-broker-margin-iron-condor
            :put-long 120 :put-short 125 :call-short 130 :call-long 135
            :put-long-price 4.30 :put-short-price 6.33
            :call-short-price 6.65 :call-long-price 4.75 :qty 100))
        (b (schwab-broker-margin-iron-condor
            :put-long 115 :put-short 125 :call-short 130 :call-long 140
            :put-long-price 2.83 :put-short-price 6.33
            :call-short-price 6.65 :call-long-price 3.38 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get a :net) 10700.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get b :net) 32300.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get a :initial) 50000.0 0.5))))

(ert-deftest schwab-broker-margin-calendar-cboe-aapl ()
  "CBOE AAPL: long calendar Jun/Mar 130C -> 45,000; short calendar -> 300,460."
  (let ((l (schwab-broker-margin-calendar :kind 'call :long-strike 130
                                          :short-strike 130 :long-price 11.15
                                          :short-price 6.65
                                          :long-expires-later t :qty 100))
        (s (schwab-broker-margin-calendar :kind 'call :long-strike 130
                                          :short-strike 130 :long-price 6.65
                                          :short-price 11.15 :underlying 127.83
                                          :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get l :initial) 45000.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get s :net) 300460.0 0.5))))

(ert-deftest schwab-broker-margin-diagonal-differential ()
  "Call diagonal with long strike 135 above short strike 130, 1 lot:
differential 500 added to the 300 debit.  Derived, not a CBOE vector."
  (let ((r (schwab-broker-margin-calendar :kind 'call :long-strike 135
                                          :short-strike 130 :long-price 5.00
                                          :short-price 2.00
                                          :long-expires-later t)))
    (should (schwab-broker-margin-test--near (plist-get r :initial) 800.0))))

(ert-deftest schwab-broker-margin-ratio-spread ()
  "1x2 call ratio, long 125C @9.05, short 2x 135C @4.75, AAPL 127.83, 1 lot:
vertical debit 430 + one naked 135C (20%% x 12,783 - 717 OTM + 475 = 2,314.6)."
  (let ((r (schwab-broker-margin-ratio-spread
            :kind 'call :long-strike 125 :short-strike 135 :long-price 9.05
            :short-price 4.75 :long-qty 1 :short-qty 2 :underlying 127.83)))
    (should (= (plist-get r :naked-shorts) 1))
    (should (schwab-broker-margin-test--near (plist-get r :initial) 2744.6))
    ;; 1x1 reduces to the vertical
    (should (schwab-broker-margin-test--near
             (plist-get (schwab-broker-margin-ratio-spread
                         :kind 'call :long-strike 125 :short-strike 135
                         :long-price 9.05 :short-price 4.75 :long-qty 1
                         :short-qty 1 :underlying 127.83)
                        :initial)
             430.0))))

(ert-deftest schwab-broker-margin-call-price-short-put ()
  "Short 5 NVDA 165P marked at max(1.04, intrinsic) plus 491 SGOV, cash
2,031.72: scanning NVDA down from 178.9 finds a trigger price, checked
against the account function a hair either side."
  (let* ((fn (lambda (u)
               (list (schwab-broker-margin-stock-long :price 100.50 :qty 491)
                     (schwab-broker-margin-short-put
                      :strike 165 :premium (max 1.04 (- 165 u))
                      :underlying u :qty 5))))
         (cash 2031.72)
         (excess (lambda (u)
                   (plist-get (schwab-broker-margin-account
                               :cash cash :positions (funcall fn u))
                              :maintenance-excess)))
         (r (schwab-broker-margin-call-price :cash cash :positions-fn fn
                                             :price 178.9 :bound 20.0))
         (p (plist-get r :price)))
    (should p)
    (should (< p 165.0))
    (should (< (funcall excess (- p 0.02)) 0))
    (should (>= (funcall excess (+ p 0.02)) 0))))

(ert-deftest schwab-broker-margin-call-price-none-and-already ()
  "Long stock only: a price rise never triggers; a deep drop does."
  (let* ((fn (lambda (u) (list (schwab-broker-margin-stock-long :price u :qty 100))))
         (up (schwab-broker-margin-call-price :cash -4000.0 :positions-fn fn
                                              :price 100.0 :bound 200.0))
         (down (schwab-broker-margin-call-price :cash -4000.0 :positions-fn fn
                                                :price 100.0 :bound 10.0))
         (called (schwab-broker-margin-call-price :cash -9000.0 :positions-fn fn
                                                  :price 100.0 :bound 10.0)))
    (should-not (plist-get up :price))
    ;; equity = 100 U - 4000; maintenance = 25 U; excess = 75 U - 4000 -> U = 53.33
    (should (schwab-broker-margin-test--near (plist-get down :price) 53.33 0.02))
    (should (plist-get called :already-called))))

(ert-deftest schwab-broker-margin-ira-cash-secured ()
  "CSP + long stock + long option fit in settled cash; unsettled never counts."
  (let ((r (schwab-broker-margin-ira
            :settled-cash 30000.0 :unsettled-cash 5000.0
            :positions (list (schwab-broker-margin-cash-secured-put
                              :strike 100 :premium 2.0)
                             (schwab-broker-margin-stock-long :price 50 :qty 100)
                             (schwab-broker-margin-long-option :price 3.0)))))
    (should (plist-get r :allowed))
    ;; 9,800 reserve + 5,000 stock + 300 option
    (should (schwab-broker-margin-test--near (plist-get r :cash-required) 15100.0))
    (should (schwab-broker-margin-test--near (plist-get r :buying-power) 14900.0))
    (should (= (plist-get r :sma) 0.0))
    (should-not (plist-get r :margin-call))))

(ert-deftest schwab-broker-margin-ira-rejects-naked ()
  "Naked short call, short strangle, short stock and 1x2 ratio are violations;
a credit spread is allowed and needs its full width in cash."
  (let ((r (schwab-broker-margin-ira
            :settled-cash 1000.0
            :positions (list (schwab-broker-margin-short-call
                              :strike 130 :premium 1.0 :underlying 127.0)
                             (schwab-broker-margin-strangle
                              :put-strike 120 :call-strike 135 :put-price 1.0
                              :call-price 1.0 :underlying 127.0)
                             (schwab-broker-margin-stock-short :price 20 :qty 10)
                             (schwab-broker-margin-ratio-spread
                              :kind 'call :long-strike 125 :short-strike 135
                              :long-price 9.0 :short-price 4.0 :long-qty 1
                              :short-qty 2 :underlying 127.0)
                             (schwab-broker-margin-vertical
                              :kind 'put :long-strike 120 :short-strike 125
                              :long-price 4.0 :short-price 6.0)))))
    (should-not (plist-get r :allowed))
    (should (= (length (plist-get r :violations)) 4))
    (should (schwab-broker-margin-test--near (plist-get r :cash-required) 500.0))
    (should (schwab-broker-margin-test--near (plist-get r :buying-power) 500.0))))

(ert-deftest schwab-broker-margin-ira-shortfall ()
  "Cash needed beyond settled cash is a shortfall, not negative buying power."
  (let ((r (schwab-broker-margin-ira
            :settled-cash 100.0 :unsettled-cash 99999.0
            :positions (list (schwab-broker-margin-stock-long :price 50 :qty 100)))))
    (should (= (plist-get r :buying-power) 0.0))
    (should (schwab-broker-margin-test--near (plist-get r :shortfall) 4900.0))))

(defun schwab-broker-margin-test--snapshot ()
  "Synthetic trader-API snapshot shaped like the 2026-11-09 screenshot."
  `((securitiesAccount
     . ((type . "MARGIN")
        (positions
         . (((longQuantity . 491) (shortQuantity . 0) (marketValue . 49345.5)
             (instrument . ((assetType . "COLLECTIVE_INVESTMENT") (symbol . "SGOV"))))
            ((longQuantity . 0) (shortQuantity . 1) (marketValue . -104.0)
             (instrument . ((assetType . "OPTION") (symbol . "NVDA  261113P00165000")
                            (putCall . "PUT") (underlyingSymbol . "NVDA"))))))
        (currentBalances
         . ((equity . 51273.22) (optionBuyingPower . 23072.99)
            (stockBuyingPower . 46145.98) (dayTradingBuyingPower . 141966.20)))))))

(ert-deftest schwab-broker-margin-explain-screenshot-residuals ()
  "Explain reproduces the documented screenshot residuals from a snapshot."
  (let* ((r (schwab-broker-margin-explain
             (schwab-broker-margin-test--snapshot)
             :quotes '(("NVDA" . 178.9))))
         (res (lambda (k) (nth 3 (assq k (plist-get r :residuals))))))
    (should (= (length (plist-get r :positions)) 2))
    (should (schwab-broker-margin-test--near (funcall res :equity) 0.0))
    (should (schwab-broker-margin-test--near (funcall res :option-bp) -1235.48 0.02))
    (should (schwab-broker-margin-test--near (funcall res :stock-bp) -2470.96 0.04))
    (should (schwab-broker-margin-test--near (funcall res :intraday-bp) -4613.18 0.05))
    (should (cl-some (lambda (n) (string-match-p "cash derived" n))
                     (plist-get r :notes)))))

(ert-deftest schwab-broker-margin-explain-vertical-and-covered ()
  "Equal-qty same-expiry legs pair as a vertical; covered call needs no quote."
  (let* ((snap `((positions
                  . (((longQuantity . 1) (shortQuantity . 0) (marketValue . 100.0)
                      (instrument . ((assetType . "OPTION")
                                     (symbol . "XYZ   261120P00090000"))))
                     ((longQuantity . 0) (shortQuantity . 1) (marketValue . -300.0)
                      (instrument . ((assetType . "OPTION")
                                     (symbol . "XYZ   261120P00095000"))))
                     ((longQuantity . 100) (shortQuantity . 0) (marketValue . 5000.0)
                      (instrument . ((assetType . "EQUITY") (symbol . "ABC"))))
                     ((longQuantity . 0) (shortQuantity . 1) (marketValue . -50.0)
                      (instrument . ((assetType . "OPTION")
                                     (symbol . "ABC   261120C00060000"))))))
                 (currentBalances . ((cashBalance . 1000.0)))))
         (r (schwab-broker-margin-explain snap))
         (types (mapcar (lambda (p) (plist-get p :type)) (plist-get r :positions))))
    (should (memq 'vertical-credit types))
    (should (memq 'covered-call types))
    (should (memq 'stock-long types))
    (should (null (plist-get r :residuals)))))

(ert-deftest schwab-broker-margin-explain-missing-quote-errors ()
  "A naked short option without a quote is an error, not a guess."
  (should-error
   (schwab-broker-margin-explain
    '((positions . (((longQuantity . 0) (shortQuantity . 1) (marketValue . -104.0)
                     (instrument . ((assetType . "OPTION")
                                    (symbol . "NVDA  261113P00165000"))))))))))
