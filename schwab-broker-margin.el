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

(defun schwab-broker-margin--short-pair (type put call side)
  "Combine PUT and CALL plists into one straddle/strangle plist of TYPE.
SIDE is `short' or `long'.  Short: greater side's gross requirement plus
the other side's premium (CBOE); long: both paid in full."
  (let* ((credit (+ (plist-get put :credit) (plist-get call :credit)))
         (req (if (eq side 'short)
                  (max (+ (plist-get put :gross) (plist-get call :credit))
                       (+ (plist-get call :gross) (plist-get put :credit)))
                0.0)))
    (list :type type :side side :put put :call call
          :market-value (+ (plist-get put :market-value)
                           (plist-get call :market-value))
          :credit credit :gross req :net (- req credit)
          :initial req :maintenance req :cash-reserve 0.0
          :formula (list "greater side's requirement + other side's premium"
                         "net = requirement - total credit (CBOE example form)"))))

(defun schwab-broker-margin--long-pair (type put call)
  "Long straddle/strangle of TYPE from priced PUT and CALL legs (paid in full)."
  (let* ((cost (+ (plist-get put :market-value) (plist-get call :market-value))))
    (list :type type :side 'long :put put :call call :market-value cost
          :initial cost :maintenance cost :cash-reserve 0.0 :max-loss cost
          :formula (list "long legs paid in full: sum of premiums"))))

(cl-defun schwab-broker-margin--combo
    (type side put-strike call-strike put-price call-price underlying qty)
  "Build a TYPE combo of SIDE from a put and a call leg."
  (if (eq side 'long)
      (schwab-broker-margin--long-pair
       type
       (schwab-broker-margin-long-option :price put-price :qty qty)
       (schwab-broker-margin-long-option :price call-price :qty qty))
    (schwab-broker-margin--short-pair
     type
     (schwab-broker-margin-short-put :strike put-strike :premium put-price
                                     :underlying underlying :qty qty)
     (schwab-broker-margin-short-call :strike call-strike :premium call-price
                                      :underlying underlying :qty qty)
     'short)))

;;;###autoload
(cl-defun schwab-broker-margin-straddle
    (&key (side 'short) strike put-price call-price underlying (qty 1))
  "Straddle (same STRIKE put and call) on SIDE `short' or `long'.
Short: greater of the two naked requirements plus the other side's
premium; `:net' subtracts both credits (CBOE: 100 AAPL Mar 130 -> 255,660).
Long: both premiums paid in full (CBOE 155,900)."
  (schwab-broker-margin--combo 'straddle side strike strike put-price
                               call-price underlying qty))

;;;###autoload
(cl-defun schwab-broker-margin-strangle
    (&key (side 'short) put-strike call-strike put-price call-price
          underlying (qty 1))
  "Strangle (PUT-STRIKE below CALL-STRIKE) on SIDE `short' or `long'.
Same rule as `schwab-broker-margin-straddle' (CBOE short: 227,360)."
  (schwab-broker-margin--combo 'strangle side put-strike call-strike put-price
                               call-price underlying qty))

;;;###autoload
(cl-defun schwab-broker-margin-iron-condor
    (&key put-long put-short call-short call-long
          put-long-price put-short-price call-short-price call-long-price
          (qty 1))
  "Short iron condor: bull put spread (PUT-LONG below PUT-SHORT) plus bear
call spread (CALL-SHORT below CALL-LONG), prices per share, QTY condors.
Only one side can finish in the money, so the requirement is the wider
spread's width x 100 x QTY; `:net' = that less both credits (CBOE: AAPL
120/125/130/135 -> 10,700).  Maintenance equals initial."
  (let* ((p (schwab-broker-margin-vertical :kind 'put :long-strike put-long
                                           :short-strike put-short
                                           :long-price put-long-price
                                           :short-price put-short-price :qty qty))
         (c (schwab-broker-margin-vertical :kind 'call :long-strike call-long
                                           :short-strike call-short
                                           :long-price call-long-price
                                           :short-price call-short-price :qty qty))
         (req (max (plist-get p :width) (plist-get c :width)))
         (credit (+ (plist-get p :credit) (plist-get c :credit))))
    (list :type 'iron-condor :qty qty :put-spread p :call-spread c
          :market-value (+ (plist-get p :market-value) (plist-get c :market-value))
          :credit credit :net (- req credit) :max-loss (- req credit)
          :initial req :maintenance req :cash-reserve 0.0
          :formula (list "wider spread width x 100 x qty (one side can lose)"
                         "net = width - total credit (CBOE example form)"))))

;;;###autoload
(cl-defun schwab-broker-margin-ratio-spread
    (&key kind long-strike short-strike long-price short-price
          long-qty short-qty underlying)
  "Ratio spread of KIND (`call'/`put'): LONG-QTY longs, SHORT-QTY shorts.
The matched pairs (min of the two) are margined as a vertical spread; each
extra short is margined as a naked option (needs UNDERLYING); each extra
long is paid in full.  Requirement is the sum.  `:net' subtracts the
net credit (CBOE example form)."
  (let* ((matched (min long-qty short-qty))
         (extra-short (- short-qty matched))
         (extra-long (- long-qty matched))
         (v (schwab-broker-margin-vertical
             :kind kind :long-strike long-strike :short-strike short-strike
             :long-price long-price :short-price short-price :qty matched))
         (naked (when (> extra-short 0)
                  (funcall (if (eq kind 'call)
                               #'schwab-broker-margin-short-call
                             #'schwab-broker-margin-short-put)
                           :strike short-strike :premium short-price
                           :underlying underlying :qty extra-short)))
         (long (when (> extra-long 0)
                 (schwab-broker-margin-long-option :price long-price
                                                   :qty extra-long)))
         (parts (delq nil (list v naked long)))
         (sum (lambda (k) (apply #'+ 0.0 (mapcar (lambda (x) (or (plist-get x k) 0.0))
                                                 parts))))
         (mv (funcall sum :market-value))
         (req (funcall sum :initial)))
    (list :type 'ratio-spread :kind kind :long-qty long-qty :short-qty short-qty
          :vertical v :naked naked :extra-long long :naked-shorts extra-short
          :market-value mv :initial req :maintenance req :cash-reserve 0.0
          :net (+ req mv)
          :formula (list "matched pairs: vertical spread rule"
                         "extra shorts: naked option rule; extra longs: paid in full"))))

;;;###autoload
(cl-defun schwab-broker-margin-calendar
    (&key kind long-strike short-strike long-price short-price
          long-expires-later underlying (qty 1))
  "Calendar (same strike) or diagonal (different strikes) of KIND.
LONG-EXPIRES-LATER non-nil: the long leg covers the short.  Requirement
is the net debit paid in full (CBOE long calendar: 45,000), plus the
strike differential when the long strike is worse than the short
(call: long above short; put: long below short).  nil (short calendar):
the short leg is margined naked (needs UNDERLYING) and the long is paid
in full; `:net' = short gross - net credit (CBOE short calendar: 300,460)."
  (let* ((m schwab-broker-margin-multiplier)
         (debit (* (- long-price short-price) m qty))
         (mv debit))
    (if long-expires-later
        (let* ((diff (* m qty (max 0.0 (if (eq kind 'call)
                                           (- long-strike short-strike)
                                         (- short-strike long-strike)))))
               (req (+ (max 0.0 debit) diff)))
          (list :type 'calendar-long :kind kind :qty qty :debit debit
                :differential diff :market-value mv :max-loss (max 0.0 debit)
                :net req :initial req :maintenance req :cash-reserve 0.0
                :formula (list "net debit paid in full + strike differential if long strike is worse")))
      (let* ((short (funcall (if (eq kind 'call)
                                 #'schwab-broker-margin-short-call
                               #'schwab-broker-margin-short-put)
                             :strike short-strike :premium short-price
                             :underlying underlying :qty qty))
             (req (plist-get short :gross)))
        (list :type 'calendar-short :kind kind :qty qty :debit debit :short short
              :market-value mv :net (+ req debit) :initial req :maintenance req
              :cash-reserve 0.0
              :formula (list "short leg naked (expires later than the long); long paid in full"
                             "net = short gross - net credit (CBOE example form)"))))))

;;;###autoload
(cl-defun schwab-broker-margin-call-price
    (&key cash positions-fn price bound (steps 2000)
          (house-extra-initial 0.0) (house-extra-maintenance 0.0))
  "Underlying price at which the book first goes into maintenance call.
POSITIONS-FN maps an underlying price to the full list of position
plists (so the rest of the book, other legs and fixed positions, rides
along); CASH is the cash balance.  Walks from PRICE toward BOUND in STEPS
grid steps, finds the first grid cell where maintenance excess turns
negative, then bisects it to a cent.  Returns a plist with `:price' (the
trigger, nil when no call occurs on the path), `:excess-at-start',
`:excess-at-bound' and `:already-called' (non-nil when the book is
already in call at PRICE, trigger = PRICE).  Nonmonotone books are safe:
the first crossing is reported."
  (let* ((excess (lambda (p)
                   (plist-get
                    (schwab-broker-margin-account
                     :cash cash :positions (funcall positions-fn p)
                     :house-extra-initial house-extra-initial
                     :house-extra-maintenance house-extra-maintenance)
                    :maintenance-excess)))
         (e0 (funcall excess price))
         (e-bound (funcall excess bound)))
    (if (< e0 0)
        (list :price price :already-called t
              :excess-at-start e0 :excess-at-bound e-bound)
      (let* ((step (/ (- bound price) (float steps)))
             (hit (cl-loop for i from 1 to steps
                           for p = (+ price (* i step))
                           when (< (funcall excess p) 0) return i))
             trigger)
        (when hit
          (let ((good (+ price (* (1- hit) step)))
                (bad (+ price (* hit step))))
            (while (> (abs (- bad good)) 0.005)
              (let ((mid (/ (+ good bad) 2.0)))
                (if (< (funcall excess mid) 0) (setq bad mid) (setq good mid))))
            (setq trigger bad)))
        (list :price trigger :already-called nil
              :excess-at-start e0 :excess-at-bound e-bound)))))

(defun schwab-broker-margin--ira-naked-p (pos)
  "Non-nil when position plist POS is not allowed in an IRA (uncovered risk)."
  (let ((type (plist-get pos :type)))
    (or (memq type '(short-put short-call stock-short calendar-short))
        (and (memq type '(straddle strangle)) (eq (plist-get pos :side) 'short))
        (and (eq type 'ratio-spread) (> (or (plist-get pos :naked-shorts) 0) 0)))))

(defun schwab-broker-margin--ira-cash (pos)
  "Cash an IRA must hold for allowed position plist POS (no margin loan)."
  (pcase (plist-get pos :type)
    ('cash-secured-put (plist-get pos :cash-reserve))
    ('covered-call 0.0)
    ('vertical-credit (plist-get pos :width))
    ('long-option (plist-get pos :market-value))
    ('stock-long (plist-get pos :market-value))
    (_ (or (plist-get pos :initial) 0.0))))

;;;###autoload
(cl-defun schwab-broker-margin-ira
    (&key (settled-cash 0.0) (unsettled-cash 0.0) positions)
  "IRA / limited-margin variant: cash-secured only.
No naked options, no short stock, no SMA, no margin loan: every position
must be paid for or cash-secured with SETTLED-CASH.  UNSETTLED-CASH is
reported but never counts as buying power (good-faith rule).  POSITIONS
are plists from the helpers.  Allowed: long options and stock (paid in
full), covered calls (stock leg not checked), cash-secured puts (strike
x 100 - credit), vertical credit spreads (width in cash), debit spreads,
calendars and condors (initial in cash).  Returns:
  :allowed       nil when any position needs margin
  :violations    list of (TYPE reason) for each disallowed position
  :cash-required settled cash tied up by allowed positions
  :buying-power  SETTLED-CASH - :cash-required (same for stock and
                 options; nothing is doubled), floored at 0
  :shortfall     how far :cash-required exceeds SETTLED-CASH, else 0
  :sma           always 0.0
  :margin-call   always nil (no loan to call)"
  (let* ((bad (cl-remove-if-not #'schwab-broker-margin--ira-naked-p positions))
         (ok (cl-remove-if #'schwab-broker-margin--ira-naked-p positions))
         (req (apply #'+ 0.0 (mapcar #'schwab-broker-margin--ira-cash ok))))
    (list :allowed (null bad)
          :violations (mapcar (lambda (p) (list (plist-get p :type)
                                                "needs margin: uncovered risk not allowed in an IRA"))
                              bad)
          :settled-cash settled-cash :unsettled-cash unsettled-cash
          :cash-required req
          :buying-power (max 0.0 (- settled-cash req))
          :shortfall (max 0.0 (- req settled-cash))
          :stock-bp (max 0.0 (- settled-cash req))
          :option-bp (max 0.0 (- settled-cash req))
          :sma 0.0 :margin-call nil)))

(provide 'schwab-broker-margin)
;;; schwab-broker-margin.el ends here
