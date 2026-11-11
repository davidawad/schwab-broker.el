;;; schwab-broker-model-test.el --- Tests for schwab-broker-model.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline, pure.  Needs the sibling broker-model.el package: it is
;; found via $BROKER_MODEL_DIR or ../broker-model.el next to this repo;
;; when it cannot be loaded every test here is skipped.
;;
;; Three groups:
;;  - parity: schwab-broker-margin.el helpers and broker-model's Schwab
;;    registration give the same numbers on the same inputs (the
;;    helpers' own vectors from test/schwab-broker-margin-test.el);
;;  - Schwab-published vectors (REQ, PMUND) and the 2026-11-09
;;    screenshot reconciliation (docs/margin.md, empirical.md);
;;  - account-type rules (IRA, portfolio margin, sources).

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name here)))
       (bm (or (getenv "BROKER_MODEL_DIR")
               (expand-file-name "../broker-model.el" root))))
  (add-to-list 'load-path root)
  (when (file-directory-p bm) (add-to-list 'load-path bm)))

(require 'schwab-broker-margin)
(defvar schwab-broker-model-test--ok (ignore-errors (require 'schwab-broker-model)))

(declare-function broker-model-requirement "broker-model")
(declare-function broker-model-account "broker-model")
(declare-function broker-model-resolve "broker-model-core")
(declare-function broker-model-cell-of "broker-model-core")
(declare-function broker-model-remove-symbol "broker-model-core")
(declare-function broker-model-compare "broker-model")
(declare-function schwab-broker-model-set-house-option-multiplier "schwab-broker-model")

(defmacro schwab-broker-model-test--deftest (name doc &rest body)
  "Define ERT test NAME (DOC) running BODY, skipped without broker-model."
  (declare (indent 1) (doc-string 2))
  `(ert-deftest ,name ()
     ,doc
     (skip-unless schwab-broker-model-test--ok)
     ,@body))

(defun schwab-broker-model-test--near (a b &optional tol)
  "Non-nil when A and B differ by at most TOL (default 0.01)."
  (<= (abs (- a b)) (or tol 0.01)))

(defun schwab-broker-model-test--req (pos &optional acct market)
  "Schwab requirement of POS in ACCT (default reg-t) with MARKET."
  (broker-model-requirement 'schwab (or acct 'reg-t) pos market))

(defun schwab-broker-model-test--same (helper pos &optional keys tol)
  "Assert HELPER plist and the broker-model result for POS agree on KEYS."
  (let ((bm (schwab-broker-model-test--req pos)))
    (dolist (k (or keys '(:initial :maintenance)))
      (should (schwab-broker-model-test--near (plist-get helper k) (plist-get bm k) (or tol 0.01))))))

;; -- parity with schwab-broker-margin.el -------------------------------

(schwab-broker-model-test--deftest schwab-broker-model-parity-naked
  "Naked puts and calls: helper and broker-model agree (Cboe AAPL, NVDA, deep OTM)."
  (schwab-broker-model-test--same
   (schwab-broker-margin-short-put :strike 130 :premium 8.94 :underlying 127.83 :qty 100)
   '(:type option :symbol "AAPL" :side short :right put :strike 130 :price 8.94 :qty 100 :underlying-price 127.83)
   '(:initial :maintenance :net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-short-call :strike 130 :premium 6.65 :underlying 127.83 :qty 100)
   '(:type option :symbol "AAPL" :side short :right call :strike 130 :price 6.65 :qty 100 :underlying-price 127.83)
   '(:initial :net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-short-put :strike 170 :premium 2.97 :underlying 175.99)
   '(:type option :symbol "NVDA" :side short :right put :strike 170 :price 2.97 :qty 1 :underlying-price 175.99)
   '(:initial :net :leg-pct :leg-min))
  (schwab-broker-model-test--same
   (schwab-broker-margin-short-put :strike 50 :premium 0.10 :underlying 100)
   '(:type option :symbol "X" :side short :right put :strike 50 :price 0.10 :qty 1 :underlying-price 100)))

(schwab-broker-model-test--deftest schwab-broker-model-parity-stock-and-long
  "Stock tiers, long options and cash-secured puts agree."
  (schwab-broker-model-test--same (schwab-broker-margin-stock-long :price 127.83 :qty 10000)
                                  '(:type stock :symbol "AAPL" :price 127.83 :qty 10000) nil 0.5)
  (schwab-broker-model-test--same (schwab-broker-margin-stock-long :price 2 :qty 100)
                                  '(:type stock :symbol "P" :price 2 :qty 100))
  (dolist (px '(100 10 3 2))
    (schwab-broker-model-test--same (schwab-broker-margin-stock-short :price px :qty 10)
                                    (list :type 'stock :symbol "S" :side 'short :price px :qty 10)
                                    '(:maintenance)))
  (schwab-broker-model-test--same (schwab-broker-margin-long-option :price 6.33 :qty 100)
                                  '(:type option :symbol "AAPL" :side long :right put :strike 125 :price 6.33 :qty 100))
  (schwab-broker-model-test--same (schwab-broker-margin-long-option :price 20 :months-to-expiry 12)
                                  '(:type option :symbol "X" :side long :right call :strike 100 :price 20 :qty 1
                                          :months-to-expiry 12))
  (schwab-broker-model-test--same (schwab-broker-margin-cash-secured-put :strike 170 :premium 2.97)
                                  '(:type cash-secured-put :symbol "NVDA" :strike 170 :price 2.97 :qty 1)
                                  '(:cash-reserve :maintenance)))

(schwab-broker-model-test--deftest schwab-broker-model-parity-spreads
  "Verticals, straddles, strangles, condors, calendars agree with the helpers."
  (schwab-broker-model-test--same
   (schwab-broker-margin-vertical :kind 'call :long-strike 125 :short-strike 135 :long-price 9.05 :short-price 4.75 :qty 100)
   '(:type vertical :symbol "AAPL" :right call :long-strike 125 :short-strike 135 :long-price 9.05 :short-price 4.75 :qty 100)
   '(:initial :net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-vertical :kind 'call :long-strike 135 :short-strike 125 :long-price 4.75 :short-price 9.05 :qty 100)
   '(:type vertical :symbol "AAPL" :right call :long-strike 135 :short-strike 125 :long-price 4.75 :short-price 9.05 :qty 100)
   '(:initial :net :market-value) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-vertical :kind 'put :long-strike 120 :short-strike 125 :long-price 4.30 :short-price 6.33)
   '(:type vertical :symbol "AAPL" :right put :long-strike 120 :short-strike 125 :long-price 4.30 :short-price 6.33 :qty 1)
   '(:initial :max-loss))
  (schwab-broker-model-test--same
   (schwab-broker-margin-straddle :strike 130 :put-price 8.94 :call-price 6.65 :underlying 127.83 :qty 100)
   '(:type straddle :symbol "AAPL" :side short :strike 130 :put-price 8.94 :call-price 6.65 :qty 100 :underlying-price 127.83)
   '(:initial :net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-strangle :put-strike 125 :call-strike 135 :put-price 6.33 :call-price 4.75 :underlying 127.83 :qty 100)
   '(:type strangle :symbol "AAPL" :side short :put-strike 125 :call-strike 135 :put-price 6.33 :call-price 4.75
           :qty 100 :underlying-price 127.83)
   '(:net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-straddle :side 'long :strike 130 :put-price 8.94 :call-price 6.65 :qty 100)
   '(:type straddle :symbol "AAPL" :side long :strike 130 :put-price 8.94 :call-price 6.65 :qty 100)
   '(:initial) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-iron-condor :put-long 120 :put-short 125 :call-short 130 :call-long 135
                                     :put-long-price 4.30 :put-short-price 6.33 :call-short-price 6.65
                                     :call-long-price 4.75 :qty 100)
   '(:type iron-condor :symbol "AAPL" :put-long 120 :put-short 125 :call-short 130 :call-long 135
           :put-long-price 4.30 :put-short-price 6.33 :call-short-price 6.65 :call-long-price 4.75 :qty 100)
   '(:initial :net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-calendar :kind 'call :long-strike 130 :short-strike 130 :long-price 11.15
                                  :short-price 6.65 :long-expires-later t :qty 100)
   '(:type calendar :symbol "AAPL" :right call :long-strike 130 :short-strike 130 :long-price 11.15
           :short-price 6.65 :long-expires-later t :qty 100)
   '(:initial) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-calendar :kind 'call :long-strike 130 :short-strike 130 :long-price 6.65
                                  :short-price 11.15 :underlying 127.83 :qty 100)
   '(:type calendar :symbol "AAPL" :right call :long-strike 130 :short-strike 130 :long-price 6.65
           :short-price 11.15 :underlying-price 127.83 :qty 100)
   '(:initial :net) 0.5)
  (schwab-broker-model-test--same
   (schwab-broker-margin-calendar :kind 'call :long-strike 135 :short-strike 130 :long-price 5.00
                                  :short-price 2.00 :long-expires-later t)
   '(:type calendar :symbol "X" :right call :long-strike 135 :short-strike 130 :long-price 5.00
           :short-price 2.00 :long-expires-later t :qty 1)))

;; -- screenshot reconciliation (docs/margin.md, empirical.md) ----------

(defconst schwab-broker-model-test--shot
  (list :cash (+ (- 51273.22 (* 491 100.5)) 104.0)
        :positions '((:type stock :symbol "SGOV" :asset-class etf :price 100.5 :qty 491)
                     (:type option :symbol "NVDA" :side short :right put :strike 165 :price 1.04 :qty 1
                            :underlying-price 178.9)))
  "The 2026-11-09 screenshot account (cash derived from Account Value).")

(schwab-broker-model-test--deftest schwab-broker-model-screenshot-published
  "broker-model with Schwab's published rules reproduces the helper's numbers
and the documented residuals against the screenshot."
  (let* ((a (apply #'broker-model-account 'schwab 'reg-t schwab-broker-model-test--shot))
         (h (schwab-broker-margin-account
             :cash (plist-get schwab-broker-model-test--shot :cash)
             :positions (list (schwab-broker-margin-stock-long :price 100.5 :qty 491)
                              (schwab-broker-margin-short-put :strike 165 :premium 1.04 :underlying 178.9)))))
    (dolist (k '(:equity :maintenance-requirement :maintenance-excess :option-bp :stock-bp :intraday-bp))
      (should (schwab-broker-model-test--near (plist-get a k) (plist-get h k))))
    (should (schwab-broker-model-test--near (- 23072.99 (plist-get a :option-bp)) -1235.48))
    (should (schwab-broker-model-test--near (- 141966.20 (plist-get a :intraday-bp)) -4613.18))))

(schwab-broker-model-test--deftest schwab-broker-model-screenshot-house-multiplier
  "INFERRED (kd f-schwab-nvda-165p-gap-inferred): a 1.5x house multiplier on
NVDA options leaves a 7.29 maintenance residual (empirical.md) and the result
is tagged `inferred'."
  (unwind-protect
      (progn
        (schwab-broker-model-set-house-option-multiplier
         "NVDA" 1.5 "kd f-schwab-nvda-165p-gap-inferred; docs/schwab-margin/empirical.md" 'inferred
         "fitted to one screenshot, not published")
        (let* ((a (apply #'broker-model-account 'schwab 'reg-t schwab-broker-model-test--shot))
               (put (cadr (plist-get a :positions))))
          (should (schwab-broker-model-test--near (plist-get put :initial) 3438.0))
          (should (eq (plist-get put :confidence) 'inferred))
          ;; account level also reads Schwab's unpublished RBC concentration rule
          (should (eq (plist-get a :confidence) 'unpublished))
          (should (schwab-broker-model-test--near (- (/ 141966.20 4) (plist-get a :maintenance-excess))
                                                  -7.29 0.05))))
    (broker-model-remove-symbol 'schwab "NVDA")))

;; -- Schwab-published vectors -------------------------------------------

(schwab-broker-model-test--deftest schwab-broker-model-req-tables
  "REQ: $100/contract floor, broad index 15%, 2X/3X ETFs, money funds, T-bills."
  ;; $100 floor binds on a deep-OTM cheap put: 10% leg 10.05, 20% leg < 0
  (should (schwab-broker-model-test--near
           (plist-get (schwab-broker-model-test--req '(:type option :symbol "X" :side short :right put :strike 1
                                                             :price 0.05 :qty 1 :underlying-price 20))
                      :initial)
           100.0))
  ;; regulatory has no floor
  (should (schwab-broker-model-test--near
           (plist-get (broker-model-requirement 'regulatory 'reg-t
                                                '(:type option :symbol "X" :side short :right put :strike 1
                                                        :price 0.05 :qty 1 :underlying-price 20))
                      :initial)
           15.0))
  (let ((s (lambda (lev) (schwab-broker-model-test--req
                          (list :type 'stock :symbol "L" :asset-class 'leveraged-etf :leverage lev :price 50 :qty 100)))))
    (should (schwab-broker-model-test--near (plist-get (funcall s 2) :initial) 2500.0))
    (should (schwab-broker-model-test--near (plist-get (funcall s 2) :maintenance) 2500.0))
    (should (schwab-broker-model-test--near (plist-get (funcall s 3) :initial) 3750.0))
    (should (schwab-broker-model-test--near (plist-get (funcall s 3) :maintenance) 3750.0)))
  (should (schwab-broker-model-test--near
           (plist-get (schwab-broker-model-test--req '(:type stock :symbol "SWVXX" :asset-class money-market :price 1 :qty 10000))
                      :maintenance)
           1000.0))
  (let ((tb (schwab-broker-model-test--req '(:type stock :symbol "TB" :asset-class treasury-bill :price 99 :qty 100))))
    (should (schwab-broker-model-test--near (plist-get tb :initial) 990.0))
    (should (schwab-broker-model-test--near (plist-get tb :maintenance) 99.0))))

(schwab-broker-model-test--deftest schwab-broker-model-pmund-examples
  "PMUND: long 100 sh of $50 stock PM = $750; short 120P @0.80 on $125:
Reg T ~ $2,000 vs PM ~ $1,350; covered call (41.35, 44C @0.35) Reg T $2,032.50, PM ~ $590."
  (let ((pm (lambda (pos) (plist-get (schwab-broker-model-test--req pos 'portfolio-margin) :initial))))
    (should (schwab-broker-model-test--near
             (funcall pm '(:type stock :symbol "X" :price 50 :qty 100)) 750.0))
    (let ((put '(:type option :symbol "Y" :side short :right put :strike 120 :price 0.80 :qty 1 :underlying-price 125)))
      (should (schwab-broker-model-test--near (plist-get (schwab-broker-model-test--req put) :initial) 2080.0))
      ;; no expiry given in PMUND: intrinsic + time value revaluation, 13.75 x 100
      (should (<= (abs (- (funcall pm put) 1350.0)) (* 0.03 1350.0))))
    (let ((st (schwab-broker-model-test--req '(:type stock :symbol "Z" :price 41.35 :qty 100)))
          (cc (schwab-broker-model-test--req '(:type covered-call :symbol "Z" :strike 44 :price 0.35 :qty 1))))
      (should (schwab-broker-model-test--near (- (plist-get st :initial) (plist-get cc :credit)) 2032.50)))
    (let ((a (broker-model-account 'schwab 'portfolio-margin :cash 200000.0
                                   :positions '((:type stock :symbol "Z" :price 41.35 :qty 100)
                                                (:type covered-call :symbol "Z" :strike 44 :price 0.35 :qty 1))
                                   :market '(:prices (("Z" . 41.35))))))
      ;; 15% x 4,135 = 620.25 with the call's time value held; PMUND says "about $590"
      (should (<= (abs (- (plist-get a :maintenance-requirement) 590.0)) (* 0.06 590.0))))))

(schwab-broker-model-test--deftest schwab-broker-model-pm-index-and-floor
  "Schwab PM stresses SPX +/-15% (PMUND), wider than the OCC -8%/+6% floor;
unpublished IV shocks make the result a floor (confidence `unpublished')."
  (let* ((pos '(:type option :symbol "SPX" :side short :right put :strike 3800 :price 121.49 :qty 1
                      :expiry "2021-03-19" :underlying-class broad-index-high-cap))
         (mkt '(:as-of "2021-01-19" :prices (("SPX" . 3798.91))))
         (s (schwab-broker-model-test--req pos 'portfolio-margin mkt))
         (r (broker-model-requirement 'regulatory 'portfolio-margin pos mkt)))
    (should (> (plist-get s :initial) (plist-get r :initial)))
    (should (eq (plist-get s :confidence) 'unpublished))
    (should (eq (plist-get r :confidence) 'regulatory))))

(schwab-broker-model-test--deftest schwab-broker-model-pm-eligibility
  "PMWEB/PMFACT: stock under $3 and leveraged ETFs use standard margin; equity
under $100,000 is a violation."
  (let ((cheap (schwab-broker-model-test--req '(:type stock :symbol "P" :price 2 :qty 100) 'portfolio-margin))
        (lev (schwab-broker-model-test--req '(:type stock :symbol "TQQQ" :asset-class leveraged-etf :leverage 3
                                                   :price 50 :qty 100)
                                            'portfolio-margin))
        (small (broker-model-account 'schwab 'portfolio-margin :cash 90000.0)))
    (should (plist-get cheap :pm-ineligible))
    (should (schwab-broker-model-test--near (plist-get cheap :maintenance) 200.0))
    (should (schwab-broker-model-test--near (plist-get lev :maintenance) 3750.0))
    (should (cl-some (lambda (v) (string-match-p "portfolio-margin minimum" v))
                     (plist-get small :violations)))))

(schwab-broker-model-test--deftest schwab-broker-model-ira
  "IRA parity with `schwab-broker-margin-ira': settled cash only, no naked."
  (let* ((pos '((:type cash-secured-put :symbol "A" :strike 100 :price 2.0 :qty 1)
                (:type stock :symbol "B" :price 50 :qty 100)
                (:type option :symbol "C" :side long :right call :strike 10 :price 3.0 :qty 1)))
         (a (broker-model-account 'schwab 'ira :cash 35000.0 :settled-cash 30000.0 :positions pos))
         (naked (schwab-broker-model-test--req '(:type option :symbol "D" :side short :right call :strike 130
                                                      :price 1.0 :qty 1 :underlying-price 127)
                                               'ira))
         (spread (schwab-broker-model-test--req '(:type vertical :symbol "E" :right put :long-strike 120 :short-strike 125
                                                       :long-price 4.0 :short-price 6.0 :qty 1)
                                                'ira)))
    (should (schwab-broker-model-test--near (plist-get a :option-bp) 14900.0))
    (should (= 0.0 (plist-get a :sma)))
    (should-not (plist-get naked :allowed))
    (should (schwab-broker-model-test--near (plist-get spread :initial) 500.0))))

(schwab-broker-model-test--deftest schwab-broker-model-sources
  "Every Schwab cell carries a source and a known confidence; CSEP collateral
excludes ETFs (kd f-schwab-sgov-not-csep-collateral)."
  (dolist (acct '(cash reg-t portfolio-margin ira))
    (dolist (kc (broker-model-resolve 'schwab acct))
      (should (stringp (plist-get (cdr kc) :source)))
      (should (memq (plist-get (cdr kc) :confidence)
                    '(regulatory official community inferred unpublished)))))
  (let ((col (plist-get (broker-model-cell-of (broker-model-resolve 'schwab 'reg-t) :csp-collateral) :value)))
    (should (memq 'money-market col))
    (should-not (memq 'etf col)))
  (should (eq (plist-get (broker-model-cell-of (broker-model-resolve 'schwab 'reg-t) :intraday) :confidence)
              'unpublished)))

(schwab-broker-model-test--deftest schwab-broker-model-compare-regulatory
  "Compare: Schwab reg-t adds the $100 floor over the regulatory minimum."
  (let* ((pos '(:type option :symbol "X" :side short :right put :strike 1 :price 0.05 :qty 1 :underlying-price 20))
         (rows (broker-model-compare pos '((regulatory . reg-t) (schwab . reg-t) (schwab . cash)))))
    (should (< (plist-get (nth 0 rows) :initial) (plist-get (nth 1 rows) :initial)))
    (should-not (plist-get (nth 2 rows) :allowed))))

(provide 'schwab-broker-model-test)
;;; schwab-broker-model-test.el ends here
