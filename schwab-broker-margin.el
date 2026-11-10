;;; schwab-broker-margin.el --- Reg T / Schwab margin math (pure, read-only) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Pure functions that reproduce how a Schwab Reg T margin account
;; computes requirements and buying power, per position type.  No
;; network, no I/O, no order placement: numbers in, plists out.
;; Rules and citations: docs/margin.md.
;;
;; Every position helper returns a plist with these keys:
;;   :type          symbol naming the position type
;;   :qty           contracts / shares (positive)
;;   :market-value  signed current value: assets positive, short
;;                  liabilities negative (what account equity counts)
;;   :initial       Schwab initial requirement (dollars)
;;   :maintenance   Schwab maintenance requirement (dollars)
;;   :cash-reserve  cash that must be held against the position
;;   :formula       list describing how the numbers were built
;; plus type-specific detail keys.  Option requirements here are GROSS:
;; they include the option's current market value, which is also a
;; liability inside :market-value, so equity - requirement is right.
;; CBOE's published examples are NET of the credit: use `:net'.
;;
;; House rules Schwab does not publish per symbol are explicit
;; parameters (`:house-pct', `:house-extra'), never guessed.

;;; Code:

(require 'cl-lib)

(defconst schwab-broker-margin-multiplier 100
  "Shares per standard equity option contract.")

(defun schwab-broker-margin--otm (kind underlying strike)
  "Per-share out-of-the-money amount of a KIND (`put'/`call') option.
STRIKE and UNDERLYING are prices."
  (max 0.0 (if (eq kind 'put) (- underlying strike) (- strike underlying))))

(defun schwab-broker-margin--short-option (kind strike premium underlying qty
                                                pct min-pct house-extra)
  "Shared naked-option math for KIND, STRIKE, PREMIUM, UNDERLYING and QTY.
PCT and MIN-PCT are the leg percentages; HOUSE-EXTRA is a dollar add-on."
  (let* ((m schwab-broker-margin-multiplier)
         (credit (* premium m qty))
         (otm (* (schwab-broker-margin--otm kind underlying strike) m qty))
         (leg-pct (+ (- (* pct underlying m qty) otm) credit))
         (leg-min (+ (* min-pct (if (eq kind 'put) strike underlying) m qty)
                     credit))
         (floor-amt (* 100.0 qty))
         (req (+ (max leg-pct leg-min floor-amt) (or house-extra 0.0))))
    (list :type (if (eq kind 'put) 'short-put 'short-call)
          :qty qty :strike strike :premium premium :underlying underlying
          :market-value (- credit) :credit credit :otm otm
          :leg-pct leg-pct :leg-min leg-min :floor floor-amt
          :house-extra (or house-extra 0.0)
          :gross req :net (- req credit)
          :initial req :maintenance req :cash-reserve 0.0
          :formula (list (format "greater of %.0f%% underlying - OTM + premium" (* 100 pct))
                         (format "%.0f%% %s + premium"
                                 (* 100 min-pct)
                                 (if (eq kind 'put) "strike value" "underlying value"))
                         "$100 per contract"))))

;;;###autoload
(cl-defun schwab-broker-margin-short-put
    (&key strike premium underlying (qty 1) (pct 0.20) (min-pct 0.10) house-extra)
  "Naked short equity PUT requirement (Schwab / CBOE strategy-based).
STRIKE, PREMIUM (current mark, per share), UNDERLYING price, QTY contracts.
Requirement = greater of PCT*U - OTM + premium, MIN-PCT*strike + premium,
$100/contract, all x100 x QTY, plus HOUSE-EXTRA dollars (explicit Schwab
override; default none).  `:net' subtracts the credit (CBOE example form)."
  (schwab-broker-margin--short-option 'put strike premium underlying qty
                                      pct min-pct house-extra))

;;;###autoload
(cl-defun schwab-broker-margin-short-call
    (&key strike premium underlying (qty 1) (pct 0.20) (min-pct 0.10) house-extra)
  "Naked short equity CALL requirement (Schwab / CBOE strategy-based).
STRIKE, PREMIUM, UNDERLYING, QTY, PCT, MIN-PCT and HOUSE-EXTRA are as
in `schwab-broker-margin-short-put'; the minimum leg is MIN-PCT of the
underlying value rather than the strike."
  (schwab-broker-margin--short-option 'call strike premium underlying qty
                                      pct min-pct house-extra))

;;;###autoload
(cl-defun schwab-broker-margin-cash-secured-put
    (&key strike premium (qty 1))
  "Cash-secured equity put (Schwab CSEP): no margin requirement.
The holder must keep the assignment value in cash or cash equivalents:
`:cash-reserve' = STRIKE*100*QTY - credit (PREMIUM is the per-share
credit).  Schwab lists cash, money funds, Schwab Bank deposits and
T-bills under a year as cash equivalents; it does not list ETFs."
  (let* ((m schwab-broker-margin-multiplier)
         (credit (* premium m qty)))
    (list :type 'cash-secured-put :qty qty :strike strike :premium premium
          :market-value (- credit) :credit credit
          :initial 0.0 :maintenance 0.0
          :cash-reserve (- (* strike m qty) credit)
          :formula (list "margin requirement 0; reserve = strike x 100 x qty - credit"))))

;;;###autoload
(cl-defun schwab-broker-margin-covered-call
    (&key strike premium underlying (qty 1))
  "Covered short call: the long stock covers it, so the option needs 0.
The stock leg is margined by `schwab-broker-margin-stock-long'; the
credit lowers the net requirement (CBOE: 50% stock - call credit).
STRIKE and UNDERLYING are recorded only; PREMIUM is per share."
  (let ((credit (* premium schwab-broker-margin-multiplier qty)))
    (list :type 'covered-call :qty qty :strike strike :premium premium
          :underlying underlying :market-value (- credit) :credit credit
          :initial 0.0 :maintenance 0.0 :cash-reserve 0.0
          :formula (list "covered by long stock: option requirement 0"))))

;;;###autoload
(cl-defun schwab-broker-margin-long-option
    (&key price (qty 1) months-to-expiry (leaps-margin-pct 1.0))
  "Long equity option bought at PRICE per share, QTY contracts.
Schwab's published rule is 100% of cost, same for maintenance.  FINRA
4210(f)(1)/(2)(B) lets a listed option with more than 9 months to
expiry carry margin of 75% of market value (a 25% loan value): pass
`:leaps-margin-pct 0.75' with MONTHS-TO-EXPIRY above 9 to apply it.
Default LEAPS-MARGIN-PCT 1.0 = Schwab's published paid-in-full."
  (let* ((mv (* price schwab-broker-margin-multiplier qty))
         (leaps (and months-to-expiry (> months-to-expiry 9)))
         (pct (if leaps leaps-margin-pct 1.0))
         (req (* pct mv)))
    (list :type 'long-option :qty qty :market-value mv :leaps leaps
          :margin-pct pct :loan-value (- mv req)
          :initial req :maintenance req :cash-reserve 0.0
          :formula (list (format "%.0f%% of market value%s" (* 100 pct)
                                 (if leaps " (listed, > 9 months)" ""))))))

;;;###autoload
(cl-defun schwab-broker-margin-stock-long
    (&key price (qty 1) (initial-pct 0.50) (house-pct 0.25) (marginable t))
  "Long stock or non-leveraged ETF, QTY shares at PRICE.
Reg T initial is INITIAL-PCT (50%).  Schwab maintenance is 25% of market
value, or HOUSE-PCT when Schwab sets a higher level (commonly 50%).
Under $3.00 a share, or when MARGINABLE is nil, the requirement is 100%."
  (let* ((mv (* price qty))
         (full (or (not marginable) (< price 3.0)))
         (init (if full mv (* initial-pct mv)))
         (maint (if full mv (* house-pct mv))))
    (list :type 'stock-long :qty qty :price price :market-value mv
          :initial init :maintenance maint :cash-reserve 0.0
          :formula (list (format "initial %.0f%%, maintenance %.0f%% of market value"
                                 (* 100 (/ init mv)) (* 100 (/ maint mv)))))))

;;;###autoload
(cl-defun schwab-broker-margin-stock-short (&key price (qty 1))
  "Short stock or non-leveraged ETF, QTY shares at PRICE (Schwab table).
Initial: 50% of net proceeds.  Maintenance: 30% of short market value
above $16.66; $5 per share from $5.00 to $16.66; 100% from $2.50 to
$4.99; $2.50 per share below $2.50."
  (let* ((mv (* price qty))
         (maint (cond ((> price 16.66) (* 0.30 mv))
                      ((>= price 5.0) (* 5.0 qty))
                      ((>= price 2.5) mv)
                      (t (* 2.5 qty)))))
    (list :type 'stock-short :qty qty :price price :market-value (- mv)
          :initial (* 0.5 mv) :maintenance maint :cash-reserve 0.0
          :formula (list "initial 50% of proceeds; Schwab short maintenance tier"))))

;;;###autoload
(cl-defun schwab-broker-margin-account
    (&key (cash 0.0) positions (intraday-multiple 4)
          (house-extra-initial 0.0) (house-extra-maintenance 0.0))
  "Account-level margin numbers from CASH and POSITIONS.
POSITIONS is a list of plists from the position helpers.  CASH is the
cash balance including short-sale and option credits.
Returns a plist:
  :equity                CASH + sum of :market-value
  :initial-requirement   sum of :initial + HOUSE-EXTRA-INITIAL
  :maintenance-requirement sum of :maintenance + HOUSE-EXTRA-MAINTENANCE
  :maintenance-excess    equity - maintenance requirement
  :sma                   equity - initial requirement, floored at 0 (an
                         approximation: real SMA is a running balance
                         that never falls on price moves alone)
  :option-bp             :sma less cash reserved for cash-secured puts
  :stock-bp              2 x :option-bp (Schwab: Reg T 50%)
  :intraday-bp           INTRADAY-MULTIPLE x maintenance excess (Schwab
                         divides by 0.25), floored at 0
  :margin-call           non-nil when maintenance excess < 0
HOUSE-EXTRA-* are explicit dollar add-ons for house rules Schwab does
not publish; see docs/margin.md for the fitted values."
  (let* ((sum (lambda (k) (apply #'+ 0.0 (mapcar (lambda (p) (or (plist-get p k) 0.0))
                                                 positions))))
         (equity (+ cash (funcall sum :market-value)))
         (init (+ (funcall sum :initial) house-extra-initial))
         (maint (+ (funcall sum :maintenance) house-extra-maintenance))
         (excess (- equity maint))
         (sma (max 0.0 (- equity init)))
         (obp (max 0.0 (- sma (funcall sum :cash-reserve)))))
    (list :equity equity :initial-requirement init
          :maintenance-requirement maint :maintenance-excess excess
          :sma sma :option-bp obp :stock-bp (* 2 obp)
          :intraday-bp (* intraday-multiple (max 0.0 excess))
          :margin-call (< excess 0))))

;;;###autoload
(defun schwab-broker-margin-reconcile (observed computed)
  "Compare OBSERVED Schwab numbers with COMPUTED account numbers.
Both are plists using the keys of `schwab-broker-margin-account'
\(:equity :option-bp :stock-bp :intraday-bp ...).  Returns a list of
\(KEY OBSERVED COMPUTED RESIDUAL) for each key present in OBSERVED,
where RESIDUAL = OBSERVED - COMPUTED (the gap a house rule must fill)."
  (let (out)
    (cl-loop for (k v) on observed by #'cddr
             do (let ((c (plist-get computed k)))
                  (when (numberp c)
                    (push (list k v c (- v c)) out))))
    (nreverse out)))

;;;###autoload
(cl-defun schwab-broker-margin-vertical
    (&key kind long-strike short-strike long-price short-price (qty 1))
  "Vertical spread of KIND (`call'/`put'), QTY spreads, prices per share.
Debit spread (call: long strike below short; put: long strike above):
the debit is paid in full, requirement = debit = max loss.  Credit
spread: requirement = strike width x 100 x QTY (the credit sits in cash,
so equity - requirement is right); `:net' = width - credit is the CBOE
example form and the true max loss.  Maintenance equals initial."
  (let* ((m schwab-broker-margin-multiplier)
         (width (* (abs (- long-strike short-strike)) m qty))
         (debit (* (- long-price short-price) m qty))
         (debit-p (if (eq kind 'call) (< long-strike short-strike)
                    (> long-strike short-strike)))
         (req (if debit-p (max 0.0 debit) width))
         (max-loss (if debit-p (max 0.0 debit) (max 0.0 (+ width debit)))))
    (when (= long-strike short-strike)
      (error "Vertical spread needs two different strikes"))
    (list :type (if debit-p 'vertical-debit 'vertical-credit) :kind kind
          :qty qty :long-strike long-strike :short-strike short-strike
          :width width :debit debit :credit (max 0.0 (- debit))
          :market-value debit :max-loss max-loss :net max-loss
          :initial req :maintenance req :cash-reserve 0.0
          :formula (list (if debit-p "debit spread: net debit paid in full"
                           "credit spread: strike width x 100 x qty; net = width - credit")))))

(provide 'schwab-broker-margin)
;;; schwab-broker-margin.el ends here
