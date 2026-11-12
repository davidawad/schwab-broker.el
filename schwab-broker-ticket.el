;;; schwab-broker-ticket.el --- thinkorswim web prefilled order tickets -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Build `https://trade.thinkorswim.com/trade?...' URLs that open a
;; PREFILLED (draft) order ticket in thinkorswim web, and convert
;; option symbols between OCC and thinkorswim (TOS) forms.  Pure
;; elisp, no network, no Rust dependency, no Schwab API call: opening
;; the URL only drafts a ticket in a signed-in browser session; the
;; user must still review and send it there.  Nothing in this file
;; sends an order, and nothing here is gated by
;; `schwab-broker-allow-orders'.
;;
;; The URL schema is undocumented by Schwab.  It was read from the
;; site's JavaScript and is specified, with evidence and a confidence
;; tag per claim, in the sibling Rust crate's docs
;; (tos-ticket-rs: docs/tos-ticket-url-schema.md).  This file mirrors
;; that crate's behavior and shares its golden test vectors
;; (test/golden/tos-ticket-golden.json).
;;
;; An ORDER is a plist:
;;
;;   (:legs ((:qty 1 :instrument ".NVDA261113P165"))
;;    :order-type "LIMIT" :limit 0.05 :tif "GTC")
;;
;; :order-type and :tif are REQUIRED: the site silently falls back to the
;; account's default order type (possibly MARKET) and a default time in
;; force when they are missing or unknown, so this file never lets that
;; happen.  Optional keys: :symbol (explicit `symbol' parameter), :stop,
;; :tick (price increment to enforce; default 0.01; required for futures
;; and futures options, and for a sub-penny stock price).  WALK_LIMIT and
;; the ETH time in force are refused, MARKET needs DAY, and forex pairs,
;; CUSIPs, mutual funds and futures products without a month are refused
;; (all tested live: the site changes or blocks them).  Unknown keys are
;; errors.
;;
;; The URL only DRAFTS a ticket.  Review it on screen before placing: it
;; has no to-open/to-close parameter and no account parameter.
;; :qty is a signed integer (negative sells).  :instrument is a TOS
;; option, an OCC option (21-character or compact), a futures option
;; (./ESZ26C7600:XCME, exchange required), or a plain symbol.
;; :order-type and :tif may be strings or symbols, any case.
;;
;; Entry points:
;;
;;   `schwab-broker-ticket-url'   -- validate and return (or copy) the URL.
;;   `schwab-broker-ticket-summary' -- one-line human-readable summary.
;;   `schwab-broker-ticket-open'  -- same, then `browse-url' it.
;;   `schwab-broker-ticket-for-position' -- the order that closes a
;;       Schwab position alist (short 1 put => buy 1 of that put).
;;   `schwab-broker-ticket-close-position' -- interactive: pick a
;;       position from `schwab-broker-positions-sync' and open its
;;       closing ticket.
;;   `schwab-broker-ticket-from-order-spec' -- translate an order-spec
;;       built by schwab-broker-orders.el.
;;   `schwab-broker-ticket-option-to-tos', `-to-occ', `-to-occ-compact'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function schwab-broker-positions-sync "schwab-broker-trader" ())

(define-error 'schwab-broker-ticket-error "thinkorswim ticket error" 'user-error)

(defconst schwab-broker-ticket-base-url "https://trade.thinkorswim.com/trade"
  "Route on thinkorswim web that reads the prefilled-ticket parameters.")

(defconst schwab-broker-ticket-order-types
  '("LIMIT" "MARKET" "MOC" "LOC" "STOP" "STOPLIMIT" "WALK_LIMIT")
  "Values of the `orderType' parameter the site's URL parser accepts.
The site also has TRAILSTOP, TRAILSTOPLIMIT and NONE, but its URL
parser rejects them.")

(defconst schwab-broker-ticket-tifs
  '("DAY" "EXT" "EXTO" "AM" "PM" "ETH" "GTC" "GTC_EXT" "GTC_EXTO")
  "Values of the `orderTif' parameter the site's URL parser accepts.")

(defconst schwab-broker-ticket-max-legs 4
  "The URL carries leg1 through leg4 only.")

(defun schwab-broker-ticket--fail (fmt &rest args)
  "Signal `schwab-broker-ticket-error' with `format' of FMT and ARGS."
  (signal 'schwab-broker-ticket-error (list (apply #'format fmt args))))

;; -- option symbols ---------------------------------------------------------

(defun schwab-broker-ticket--leap-p (year)
  "Non-nil when YEAR is a leap year."
  (or (and (zerop (% year 4)) (not (zerop (% year 100))))
      (zerop (% year 400))))

(defun schwab-broker-ticket--days-in-month (year month)
  "Number of days in MONTH of YEAR, or 0 for an invalid MONTH."
  (pcase month
    ((or 1 3 5 7 8 10 12) 31)
    ((or 4 6 9 11) 30)
    (2 (if (schwab-broker-ticket--leap-p year) 29 28))
    (_ 0)))

(defun schwab-broker-ticket--parse-yymmdd (s)
  "Parse the six-digit string S as YYMMDD into (YEAR MONTH DAY), or signal."
  (unless (string-match-p "\\`[0-9]\\{6\\}\\'" s)
    (schwab-broker-ticket--fail "Invalid expiry %S: want YYMMDD" s))
  (let ((year (+ 2000 (string-to-number (substring s 0 2))))
        (month (string-to-number (substring s 2 4)))
        (day (string-to-number (substring s 4 6))))
    (unless (and (>= day 1)
                 (<= day (schwab-broker-ticket--days-in-month year month)))
      (schwab-broker-ticket--fail "Invalid expiry %S: not a calendar date" s))
    (list year month day)))

(defun schwab-broker-ticket--parse-occ-strike (s)
  "Parse the eight-digit OCC strike S into thousandths of a dollar."
  (unless (string-match-p "\\`[0-9]\\{8\\}\\'" s)
    (schwab-broker-ticket--fail "Invalid strike %S" s))
  (let ((m (string-to-number s)))
    (unless (>= m 1)
      (schwab-broker-ticket--fail "Invalid strike %S" s))
    m))

(defun schwab-broker-ticket--parse-tos-strike (s)
  "Parse the TOS strike S (`165', `450.5') into thousandths of a dollar."
  (let* ((dot (cl-position ?. s))
         (int (if dot (substring s 0 dot) s))
         (frac (if dot (substring s (1+ dot)) "")))
    (unless (and (string-match-p "\\`[0-9]*\\'" int)
                 (string-match-p "\\`[0-9]*\\'" frac)
                 (<= (length int) 5)
                 (<= (length frac) 3)
                 (not (and (string-empty-p int) (string-empty-p frac))))
      (schwab-broker-ticket--fail "Invalid strike %S" s))
    (let ((m (+ (* 1000 (if (string-empty-p int) 0 (string-to-number int)))
                (string-to-number (concat frac
                                          (make-string (- 3 (length frac))
                                                       ?0))))))
      (unless (>= m 1)
        (schwab-broker-ticket--fail "Invalid strike %S" s))
      m)))

(defun schwab-broker-ticket--make-option (root yymmdd right-char strike-milli)
  "Build an option plist from ROOT, YYMMDD, RIGHT-CHAR and STRIKE-MILLI.
STRIKE-MILLI is already a number, or a function of no arguments that
parses the strike (so a bad root or expiry is reported first)."
  (let ((root (upcase root))
        (right (upcase right-char)))
    (unless (string-match-p "\\`[A-Z0-9]\\{1,6\\}\\'" root)
      (schwab-broker-ticket--fail
       "Invalid option root %S: want 1-6 letters or digits" root))
    (unless (memq right '(?C ?P))
      (schwab-broker-ticket--fail "Not an option symbol (no C/P marker)"))
    (pcase-let ((`(,y ,m ,d) (schwab-broker-ticket--parse-yymmdd yymmdd)))
      (list :root root :year y :month m :day d :right right
            :strike-milli (if (functionp strike-milli)
                              (funcall strike-milli)
                            strike-milli)))))

(defun schwab-broker-ticket--ascii-p (s)
  "Non-nil when S has only ASCII characters."
  (not (string-match-p "[^[:ascii:]]" s)))

(defun schwab-broker-ticket-parse-occ (string)
  "Parse OCC 21-character option symbol STRING into an option plist."
  (let ((s (string-trim string)))
    (unless (and (= (length s) 21) (schwab-broker-ticket--ascii-p s))
      (schwab-broker-ticket--fail "Not an OCC 21-character symbol: %S" s))
    (schwab-broker-ticket--make-option
     (string-trim-right (substring s 0 6)) (substring s 6 12) (aref s 12)
     (lambda () (schwab-broker-ticket--parse-occ-strike (substring s 13 21))))))

(defun schwab-broker-ticket-parse-compact (string)
  "Parse compact OCC option symbol STRING (`NVDA261113P00165000')."
  (let* ((s (string-trim string))
         (n (length s)))
    (unless (and (>= n 16) (schwab-broker-ticket--ascii-p s))
      (schwab-broker-ticket--fail "Not a compact OCC symbol: %S" s))
    (schwab-broker-ticket--make-option
     (substring s 0 (- n 15)) (substring s (- n 15) (- n 9)) (aref s (- n 9))
     (lambda () (schwab-broker-ticket--parse-occ-strike (substring s (- n 8)))))))

(defun schwab-broker-ticket-parse-tos (string)
  "Parse thinkorswim option symbol STRING (`.NVDA261113P165')."
  (let ((s (string-trim string)))
    (unless (and (string-prefix-p "." s) (schwab-broker-ticket--ascii-p s))
      (schwab-broker-ticket--fail "Not a TOS option symbol: %S" s))
    (let* ((body (substring s 1))
           ;; The strike holds only digits and ".", so the last letter is C/P.
           (at (and (string-match "[A-Za-z][^A-Za-z]*\\'" body)
                    (match-beginning 0)))
           (split (and at (>= at 7) (- at 6))))
      (unless split
        (schwab-broker-ticket--fail "Not a TOS option symbol: %S" s))
      (schwab-broker-ticket--make-option
       (substring body 0 split) (substring body split at) (aref body at)
       (lambda ()
         (schwab-broker-ticket--parse-tos-strike (substring body (1+ at))))))))

(defun schwab-broker-ticket-parse-option (string)
  "Parse option symbol STRING in TOS, OCC 21-character or compact OCC form.
Return a plist (:root :year :month :day :right :strike-milli); signal
`schwab-broker-ticket-error' when STRING is not a valid option."
  (let ((s (string-trim string)))
    (cond ((string-empty-p s) (schwab-broker-ticket--fail "Empty symbol"))
          ((string-prefix-p "." s) (schwab-broker-ticket-parse-tos s))
          ((string-match-p "[[:space:]]" s) (schwab-broker-ticket-parse-occ s))
          (t (schwab-broker-ticket-parse-compact s)))))

(defun schwab-broker-ticket--yymmdd (opt)
  "Format the expiry of option plist OPT as YYMMDD."
  (format "%02d%02d%02d" (- (plist-get opt :year) 2000)
          (plist-get opt :month) (plist-get opt :day)))

(defun schwab-broker-ticket--strike-tos (opt)
  "Format the strike of option plist OPT as TOS writes it.
An integer, or a decimal with trailing zeros trimmed."
  (let* ((m (plist-get opt :strike-milli))
         (whole (/ m 1000))
         (frac (% m 1000)))
    (if (zerop frac)
        (number-to-string whole)
      (string-trim-right (format "%d.%03d" whole frac) "0+"))))

(defun schwab-broker-ticket--option-tos (opt)
  "Format option plist OPT as a TOS symbol."
  (format ".%s%s%c%s" (plist-get opt :root) (schwab-broker-ticket--yymmdd opt)
          (plist-get opt :right) (schwab-broker-ticket--strike-tos opt)))

(defun schwab-broker-ticket--option-occ (opt)
  "Format option plist OPT as an OCC 21-character symbol."
  (format "%-6s%s%c%08d" (plist-get opt :root) (schwab-broker-ticket--yymmdd opt)
          (plist-get opt :right) (plist-get opt :strike-milli)))

;;;###autoload
(defun schwab-broker-ticket-option-to-tos (symbol)
  "Convert option SYMBOL (any supported form) to TOS form `.NVDA261113P165'."
  (schwab-broker-ticket--option-tos (schwab-broker-ticket-parse-option symbol)))

;;;###autoload
(defun schwab-broker-ticket-option-to-occ (symbol)
  "Convert option SYMBOL (any supported form) to OCC 21-character form."
  (schwab-broker-ticket--option-occ (schwab-broker-ticket-parse-option symbol)))

;;;###autoload
(defun schwab-broker-ticket-option-to-occ-compact (symbol)
  "Convert option SYMBOL (any supported form) to compact OCC form."
  (replace-regexp-in-string
   " " "" (schwab-broker-ticket-option-to-occ symbol)))

;; -- instruments ------------------------------------------------------------

(defconst schwab-broker-ticket--root-aliases '(("SPXW" . "SPX"))
  "Option roots whose ticket `symbol' is another underlying.
Tested live: symbol=SPXW opens no ticket, symbol=SPX with .SPXW legs
does, and SPX and SPXW legs mix in one ticket.")

(defun schwab-broker-ticket--futures-contract-p (s)
  "Non-nil when S is a futures contract such as /ESZ26 or /ESZ26:XCME."
  (let ((case-fold-search nil))
    (string-match-p "\\`/[A-Z0-9]+[FGHJKMNQUVXZ][0-9][0-9]\\(?::[A-Z]+\\)?\\'" s)))

(defun schwab-broker-ticket--parse-future-option (string)
  "Parse the futures option STRING, ./ESZ26C7600:XCME.
Return a plist (:symbol UPCASED :future \"/ESZ26\").  The exchange
suffix is required: tested live, without it no ticket opens."
  (let ((s (upcase string)) (case-fold-search nil))
    (if (and (string-match
              "\\`\\./\\(.+\\)[CP]\\([0-9]+\\(?:\\.[0-9]+\\)?\\):[A-Z]+\\'" s)
             (schwab-broker-ticket--futures-contract-p
              (concat "/" (match-string 1 s))))
        (list :symbol s :future (concat "/" (match-string 1 s)))
      (schwab-broker-ticket--fail
       "Invalid futures option %S: want ./<contract><C|P><strike>:<EXCHANGE>, e.g. ./ESZ26C7600:XCME"
       string))))

(defun schwab-broker-ticket-parse-instrument (string)
  "Classify STRING as an option, a futures option or a plain symbol.
Return (option . PLIST) for any equity or index option form,
\(future-option . PLIST) for ./ESZ26C7600:XCME, else (symbol . UPCASED).
Signal `schwab-broker-ticket-error' when it is neither."
  (let ((s (string-trim string)))
    (cond
     ((string-empty-p s) (schwab-broker-ticket--fail "Empty symbol"))
     ((string-prefix-p "./" s)
      (cons 'future-option (schwab-broker-ticket--parse-future-option s)))
     ((or (string-prefix-p "." s)
          (string-match-p "[[:space:]]" s)
          (and (>= (length s) 16)
               (condition-case nil
                   (schwab-broker-ticket-parse-compact s)
                 (schwab-broker-ticket-error nil))))
      (cons 'option (schwab-broker-ticket-parse-option s)))
     ((string-match-p "\\`[A-Za-z0-9/$^:_-][A-Za-z0-9./$^:_-]*\\'" s)
      (cons 'symbol (upcase s)))
     (t (schwab-broker-ticket--fail
         "Invalid symbol %S: only letters, digits and . / $ ^ : _ - allowed"
         s)))))

(defun schwab-broker-ticket--instrument-text (inst)
  "Text for a parsed instrument INST as placed in a `legN' parameter."
  (pcase (car inst)
    ('option (schwab-broker-ticket--option-tos (cdr inst)))
    ('future-option (plist-get (cdr inst) :symbol))
    (_ (cdr inst))))

(defun schwab-broker-ticket--instrument-underlying (inst)
  "The `symbol' parameter implied by parsed instrument INST.
An option's root (SPXW mapped to SPX), a futures option's future, else
the symbol itself."
  (pcase (car inst)
    ('option (let ((root (plist-get (cdr inst) :root)))
               (or (cdr (assoc root schwab-broker-ticket--root-aliases)) root)))
    ('future-option (plist-get (cdr inst) :future))
    (_ (cdr inst))))

(defun schwab-broker-ticket--futures-p (inst)
  "Non-nil when parsed INST is a futures contract or futures option."
  (or (eq (car inst) 'future-option)
      (and (eq (car inst) 'symbol) (string-prefix-p "/" (cdr inst)))))

(defun schwab-broker-ticket--alnum (s)
  "Upper-case S with every character except letters and digits removed."
  (upcase (replace-regexp-in-string "[^A-Za-z0-9]" "" s)))

(defun schwab-broker-ticket--instrument-root (inst)
  "Root of parsed instrument INST used for the shared-root rule."
  (schwab-broker-ticket--alnum
   (schwab-broker-ticket--instrument-underlying inst)))

;; -- order normalization and validation -------------------------------------

(defun schwab-broker-ticket--enum (value allowed what)
  "Normalize VALUE to the member of ALLOWED it names, case-insensitively.
VALUE is nil, a string, a symbol or a keyword; WHAT names the field in
errors.  Return nil for nil VALUE."
  (when value
    (let* ((raw (if (symbolp value) (symbol-name value) value))
           (up (upcase (replace-regexp-in-string "-" "_" (string-remove-prefix ":" raw)))))
      (or (car (member up allowed))
          (schwab-broker-ticket--fail "Unknown %s %S; want one of: %s"
                                      what raw (string-join allowed ", "))))))

(defconst schwab-broker-ticket--order-keys
  '(:symbol :legs :order-type :limit :stop :tif :tick)
  "Keys an order plist may have; any other key is an error (a typo guard).")

(defconst schwab-broker-ticket--leg-keys '(:qty :instrument)
  "Keys a leg plist may have.")

(defun schwab-broker-ticket--check-keys (plist allowed what)
  "Signal when the property list PLIST has a key outside ALLOWED.
WHAT names PLIST in the error."
  (let ((p plist))
    (while p
      (unless (memq (car p) allowed)
        (schwab-broker-ticket--fail "Unknown %s key %S" what (car p)))
      (setq p (cddr p)))))

(defun schwab-broker-ticket--legs (order)
  "Return the legs of ORDER as a list of (QTY . PARSED-INSTRUMENT)."
  (schwab-broker-ticket--check-keys order schwab-broker-ticket--order-keys
                                    "order")
  (mapcar (lambda (leg)
            (schwab-broker-ticket--check-keys
             leg schwab-broker-ticket--leg-keys "leg")
            (let ((qty (plist-get leg :qty)))
              (unless (integerp qty)
                (schwab-broker-ticket--fail
                 "Leg quantity %S must be an integer" qty))
              (cons qty (schwab-broker-ticket-parse-instrument
                         (or (plist-get leg :instrument) "")))))
          (plist-get order :legs)))

(defun schwab-broker-ticket--price-ok-p (p)
  "Non-nil when P is a finite number greater than 0."
  (and (numberp p) (> p 0) (not (= p 1.0e+INF))))

(defun schwab-broker-ticket--on-grid-p (price step)
  "Non-nil when PRICE is a whole number of STEP, allowing float error."
  (let ((p (float price)) (s (float step)))
    (< (abs (- (* (fround (/ p s)) s) p)) (* s 1e-6))))

(defun schwab-broker-ticket--tick-kinds (order legs)
  "Violation kinds for the tick rule of ORDER with parsed LEGS.
The step is `:tick' when given, else 0.01.  Tested live, the tick is per
instrument (NVDA refuses 0.1234), so a sub-penny price needs an explicit
tick, and futures (/ES is 0.25) always need one: `missing_tick'."
  (let* ((tick (plist-get order :tick))
         (tick-ok (and tick (schwab-broker-ticket--price-ok-p tick)))
         (step (if tick-ok tick 0.01))
         (prices (list (plist-get order :limit) (plist-get order :stop))))
    (if (and (null tick) (cl-some #'identity prices)
             (cl-some (lambda (leg) (schwab-broker-ticket--futures-p (cdr leg)))
                      legs))
        '(missing_tick)
      (append
       (and tick (not tick-ok) '(bad_price))
       (and (cl-some (lambda (p)
                       (and p (schwab-broker-ticket--price-ok-p p)
                            (not (schwab-broker-ticket--on-grid-p p step))))
                     prices)
            '(non_tick_price))))))

(defun schwab-broker-ticket--cusip-p (s)
  "Non-nil when S is a 9-character CUSIP with a valid check digit."
  (and (= (length s) 9)
       (string-match-p "\\`[0-9A-Z*@#]\\{8\\}[0-9]\\'" s)
       (string-match-p "[0-9]" s)
       (let ((sum 0))
         (dotimes (i 8)
           (let* ((c (aref s i))
                  (v (cond ((<= ?0 c ?9) (- c ?0))
                           ((<= ?A c ?Z) (+ 10 (- c ?A)))
                           ((= c ?*) 36) ((= c ?@) 37) (t 38)))
                  (v (if (= (% i 2) 1) (* v 2) v)))
             (setq sum (+ sum (/ v 10) (% v 10)))))
         (= (% (- 10 (% sum 10)) 10) (- (aref s 8) ?0)))))

(defun schwab-broker-ticket--unsupported-p (inst)
  "Non-nil when parsed INST is a class the site will not ticket.
Tested live: forex pairs (an empty, unusable draft), CUSIPs and
Treasury bills, mutual funds (5 letters ending in X) and futures
products without a contract month open no usable ticket."
  (when (eq (car inst) 'symbol)
    (let ((s (cdr inst)) (case-fold-search nil))
      (or (string-match-p "\\`[A-Z]\\{3\\}/[A-Z]\\{3\\}\\'" s)
          (schwab-broker-ticket--cusip-p s)
          (string-match-p "\\`[A-Z]\\{4\\}X\\'" s)
          (and (string-prefix-p "/" s)
               (not (schwab-broker-ticket--futures-contract-p s)))))))

(defun schwab-broker-ticket--price-kinds (order legs)
  "Violation kinds for the type, TIF and price fields of ORDER with LEGS."
  (let* ((type (schwab-broker-ticket--enum (plist-get order :order-type)
                                           schwab-broker-ticket-order-types
                                           "order type"))
         (limit (plist-get order :limit))
         (stop (plist-get order :stop))
         (rules (pcase type
                  ((or "LIMIT" "LOC") '(t nil nil t))
                  ((or "MARKET" "MOC") '(nil nil t t))
                  ("STOP" '(nil t t nil))
                  ("STOPLIMIT" '(t t nil nil))
                  (_ '(nil nil nil nil))))
         (need-limit (nth 0 rules)) (need-stop (nth 1 rules))
         (no-limit (nth 2 rules)) (no-stop (nth 3 rules)))
    (append
     (and (or (and limit (not (schwab-broker-ticket--price-ok-p limit)))
              (and stop (not (schwab-broker-ticket--price-ok-p stop))))
          '(bad_price))
     (and (null type) '(missing_order_type))
     (and (equal type "WALK_LIMIT") '(unsupported_order_type))
     (and (or (and need-limit (null limit)) (and need-stop (null stop)))
          '(missing_price))
     (and (or (and no-limit limit) (and no-stop stop))
          '(unexpected_price))
     (schwab-broker-ticket--tick-kinds order legs)
     (let ((tif (schwab-broker-ticket--enum (plist-get order :tif)
                                            schwab-broker-ticket-tifs
                                            "time in force")))
       (cond ((null tif) '(missing_tif))
             ((equal tif "ETH") '(unsupported_tif))
             ((and (equal type "MARKET") (not (equal tif "DAY")))
              '(market_requires_day)))))))

(defun schwab-broker-ticket--symbol-kinds (order legs)
  "Violation kinds for the symbol rules of ORDER with parsed LEGS."
  (let ((symbol (or (plist-get order :symbol)
                    (and legs (schwab-broker-ticket--instrument-underlying
                               (cdar legs))))))
    (when symbol
      (let* ((as-inst (condition-case nil
                          (schwab-broker-ticket-parse-instrument symbol)
                        (schwab-broker-ticket-error nil)))
             (option-rule-hit
              (and as-inst (eq (car as-inst) 'option)
                   (not (and (= (length legs) 1)
                             (equal (cdar legs) as-inst)))))
             (want (if as-inst
                       (schwab-broker-ticket--instrument-root as-inst)
                     (schwab-broker-ticket--alnum symbol))))
        (append
         (and (or (string-empty-p symbol)
                  (string-match-p "[[:space:],]" symbol))
              '(bad_symbol))
         (and legs (string-match-p "[*+-]" symbol) '(symbol_disables_legs))
         (and option-rule-hit '(option_symbol_needs_single_matching_leg))
         (and (not option-rule-hit)
              (cl-some (lambda (leg)
                         (not (equal (schwab-broker-ticket--instrument-root
                                      (cdr leg))
                                     want)))
                       legs)
              '(root_mismatch)))))))

;;;###autoload
(defun schwab-broker-ticket-violations (order)
  "Return the sorted rule violations of ORDER (a list of symbols).
Empty means ORDER is expressible as a ticket URL.  The kinds are the
same tags the Rust crate reports: `no_legs', `too_many_legs',
`zero_quantity', `multiple_non_option_legs', `root_mismatch',
`option_symbol_needs_single_matching_leg', `symbol_disables_legs',
`bad_symbol', `bad_price', `missing_price', `unexpected_price',
`missing_order_type', `missing_tif', `unsupported_order_type',
`non_tick_price', `unsupported_tif', `market_requires_day',
`unsupported_instrument', `missing_tick'.
Signal `schwab-broker-ticket-error' for input that cannot be parsed at
all (an unknown order type, a bad symbol, a non-integer quantity)."
  (let* ((legs (schwab-broker-ticket--legs order))
         (kinds
          (append
           (and (null legs) '(no_legs))
           (and (> (length legs) schwab-broker-ticket-max-legs)
                '(too_many_legs))
           (and (> (cl-count 'symbol legs :key #'cadr) 1)
                '(multiple_non_option_legs))
           (and (cl-some (lambda (leg) (zerop (car leg))) legs)
                '(zero_quantity))
           (and (cl-some (lambda (leg)
                           (schwab-broker-ticket--unsupported-p (cdr leg)))
                         legs)
                '(unsupported_instrument))
           (schwab-broker-ticket--symbol-kinds order legs)
           (schwab-broker-ticket--price-kinds order legs))))
    (schwab-broker-ticket--enum (plist-get order :tif) schwab-broker-ticket-tifs
                                "time in force")
    (sort (delete-dups kinds)
          (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defconst schwab-broker-ticket--violation-text
  '((no_legs . "no legs")
    (too_many_legs . "more than 4 legs")
    (zero_quantity . "a leg has quantity 0")
    (multiple_non_option_legs . "more than one non-option leg")
    (root_mismatch . "a leg's root differs from the symbol's root")
    (option_symbol_needs_single_matching_leg
     . "an option symbol needs exactly one leg, that option")
    (symbol_disables_legs . "a symbol containing * + - makes the site ignore all legs")
    (bad_symbol . "the symbol is empty or has whitespace or a comma")
    (bad_price . "a price is not finite and greater than 0")
    (missing_price . "the order type needs a price that is missing")
    (unexpected_price . "the order type does not use a price that is given")
    (missing_order_type
     . "no order type: the site would use the account default, maybe MARKET")
    (missing_tif . "no time in force: the site would use its default")
    (unsupported_order_type . "WALK_LIMIT is unverified and refused")
    (non_tick_price . "a price is not a multiple of the tick")
    (unsupported_tif
     . "ETH is refused: the ticket replaces it with Day (tested live)")
    (market_requires_day
     . "MARKET needs DAY: the ticket blocks any other time in force")
    (unsupported_instrument
     . "forex, CUSIPs/bonds, mutual funds and futures products without a month open no usable ticket")
    (missing_tick
     . "futures prices need an explicit :tick (/ES is 0.25)"))
  "Human text for each violation kind.")

;; -- URL --------------------------------------------------------------------

(defun schwab-broker-ticket--encode (s)
  "Percent-encode S as a query value.
Every UTF-8 byte is escaped except ASCII letters, digits and - . _ ~ and
the comma.  The comma stays literal: the site splits the decoded value
on it, so it reads the same as %2C.  A literal + would decode to a
space, so it is sent as %2B."
  (mapconcat (lambda (b)
               (if (or (<= ?a b ?z) (<= ?A b ?Z) (<= ?0 b ?9)
                       (memq b '(?- ?. ?_ ?~ ?,)))
                   (string b)
                 (format "%%%02X" b)))
             (encode-coding-string s 'utf-8 t) ""))

(defun schwab-broker-ticket--expand-exponent (s)
  "Rewrite the exponent form S (`1.5e-07') as a plain decimal."
  (if (string-match "\\`\\([0-9]+\\)\\(?:\\.\\([0-9]+\\)\\)?e\\([-+][0-9]+\\)\\'" s)
      (let* ((int (match-string 1 s))
             (frac (or (match-string 2 s) ""))
             (digits (concat int frac))
             (point (+ (length int) (string-to-number (match-string 3 s)))))
        (cond ((<= point 0) (concat "0." (make-string (- point) ?0) digits))
              ((>= point (length digits))
               (concat digits (make-string (- point (length digits)) ?0)))
              (t (concat (substring digits 0 point) "." (substring digits point)))))
    s))

(defun schwab-broker-ticket--format-price (p)
  "Format number P as the shortest plain decimal (no exponent, no `.0')."
  (cond ((integerp p) (number-to-string p))
        ((= p (ffloor p)) (format "%d" p))
        (t (schwab-broker-ticket--expand-exponent (number-to-string p)))))

(defun schwab-broker-ticket-params (order)
  "Return ORDER's URL parameters as an alist of (KEY . VALUE), unencoded.
Keys come in the site's own order: symbol, leg1..leg4, orderType,
limitPrice, stopPrice, orderTif.  Performs no rule validation."
  (let* ((legs (schwab-broker-ticket--legs order))
         (type (schwab-broker-ticket--enum (plist-get order :order-type)
                                           schwab-broker-ticket-order-types
                                           "order type"))
         (tif (schwab-broker-ticket--enum (plist-get order :tif)
                                          schwab-broker-ticket-tifs
                                          "time in force"))
         (symbol (or (plist-get order :symbol)
                     (and legs (schwab-broker-ticket--instrument-underlying
                                (cdar legs)))))
         (limit (plist-get order :limit))
         (stop (plist-get order :stop)))
    (append
     (and symbol (list (cons "symbol" symbol)))
     (cl-loop for leg in legs
              for i from 1
              collect (cons (format "leg%d" i)
                            (format "%d,%s" (car leg)
                                    (schwab-broker-ticket--instrument-text
                                     (cdr leg)))))
     (and type (list (cons "orderType" type)))
     (and limit (list (cons "limitPrice"
                            (schwab-broker-ticket--format-price limit))))
     (and stop (list (cons "stopPrice"
                           (schwab-broker-ticket--format-price stop))))
     (and tif (list (cons "orderTif" tif))))))

(defun schwab-broker-ticket--build (order)
  "Build the URL for ORDER without validating the rules."
  (concat schwab-broker-ticket-base-url "?"
          (mapconcat (lambda (kv)
                       (concat (car kv) "=" (schwab-broker-ticket--encode (cdr kv))))
                     (schwab-broker-ticket-params order) "&")))

(defconst schwab-broker-ticket--months
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
  "Month abbreviations used by `schwab-broker-ticket-summary'.")

(defconst schwab-broker-ticket-review-reminder
  (concat "REVIEW the ticket in thinkorswim before placing it.  The URL has "
          "no to-open/to-close parameter and no account parameter: the "
          "ticket uses the account currently selected in the site, and "
          "whatever order type, quantity and prices appear on screen are "
          "what would be sent.")
  "Reminder shown whenever a ticket URL is produced.")

(defun schwab-broker-ticket--leg-summary (leg)
  "One-line text for parsed LEG, a (QTY . INSTRUMENT) cons."
  (let* ((qty (car leg))
         (inst (cdr leg))
         (what (if (eq (car inst) 'option)
                   (let ((o (cdr inst)))
                     (format "%s %02d %s %02d %s %s" (plist-get o :root)
                             (plist-get o :day)
                             (aref schwab-broker-ticket--months
                                   (1- (plist-get o :month)))
                             (% (plist-get o :year) 100)
                             (schwab-broker-ticket--strike-tos o)
                             (if (eq (plist-get o :right) ?C) "CALL" "PUT")))
                 (schwab-broker-ticket--instrument-text inst))))
    (format "%s %d %s" (if (< qty 0) "SELL" "BUY") (abs qty) what)))

;;;###autoload
(defun schwab-broker-ticket-summary (order)
  "Return a one-line human-readable summary of ORDER.
For example `BUY 1 NVDA 13 Nov 26 165 PUT, LIMIT 0.05, GTC'.  Legs are
joined with ` / '.  A missing order type or time in force is shown as
such, not hidden."
  (let* ((legs (schwab-broker-ticket--legs order))
         (type (schwab-broker-ticket--enum (plist-get order :order-type)
                                           schwab-broker-ticket-order-types
                                           "order type"))
         (tif (schwab-broker-ticket--enum (plist-get order :tif)
                                          schwab-broker-ticket-tifs
                                          "time in force"))
         (limit (plist-get order :limit))
         (stop (plist-get order :stop))
         (kind (or type "(no order type)"))
         (prices (cond ((and limit stop)
                        (format "stop %s limit %s"
                                (schwab-broker-ticket--format-price stop)
                                (schwab-broker-ticket--format-price limit)))
                       (limit (schwab-broker-ticket--format-price limit))
                       (stop (format "stop %s"
                                     (schwab-broker-ticket--format-price stop))))))
    (mapconcat #'identity
               (list (mapconcat #'schwab-broker-ticket--leg-summary legs " / ")
                     (if prices (concat kind " " prices) kind)
                     (or tif "(no TIF)"))
               ", ")))

(defun schwab-broker-ticket--read-leg ()
  "Prompt for one `QTY,INSTRUMENT' leg; return a leg plist, or nil if empty."
  (let ((s (string-trim (read-string "Leg QTY,INSTRUMENT (empty to finish): "))))
    (unless (string-empty-p s)
      (schwab-broker-ticket-parse-leg s))))

(defun schwab-broker-ticket--read-price (prompt)
  "Read a positive price with PROMPT."
  (let ((n (read-number prompt)))
    (if (schwab-broker-ticket--price-ok-p n)
        n
      (user-error "Price must be greater than 0"))))

(defun schwab-broker-ticket--read-order ()
  "Prompt for an order plist."
  (let* ((legs (cl-loop for leg = (schwab-broker-ticket--read-leg)
                        while leg collect leg))
         (type (schwab-broker-ticket--enum
                (completing-read "Order type: " schwab-broker-ticket-order-types
                                 nil t)
                schwab-broker-ticket-order-types "order type"))
         (tif (schwab-broker-ticket--enum
               (completing-read "Time in force: " schwab-broker-ticket-tifs
                                nil t)
               schwab-broker-ticket-tifs "time in force")))
    (list :legs legs :order-type type :tif tif
          :limit (and (member type '("LIMIT" "LOC" "STOPLIMIT"))
                      (schwab-broker-ticket--read-price "Limit price: "))
          :stop (and (member type '("STOP" "STOPLIMIT"))
                     (schwab-broker-ticket--read-price "Stop price: ")))))

;;;###autoload
(defun schwab-broker-ticket-parse-leg (string)
  "Parse `QTY,INSTRUMENT' STRING into a leg plist (:qty :instrument).
Splits on the first comma only, so a 21-character OCC symbol is fine."
  (let ((comma (cl-position ?, string)))
    (unless comma
      (schwab-broker-ticket--fail "Leg %S must be QTY,INSTRUMENT" string))
    (let ((qty (string-trim (substring string 0 comma))))
      (unless (string-match-p "\\`-?[0-9]+\\'" qty)
        (schwab-broker-ticket--fail "Leg quantity %S must be an integer" qty))
      (list :qty (string-to-number qty)
            :instrument (string-trim (substring string (1+ comma)))))))

;;;###autoload
(defun schwab-broker-ticket-url (order &optional copy)
  "Validate ORDER and return its thinkorswim ticket URL.
ORDER is a plist, see the Commentary.  Signal
`schwab-broker-ticket-error' listing each broken rule when ORDER is not
expressible.  Interactively, prompt for an order and copy the URL to
the kill ring; non-interactively copy it when COPY is non-nil.
Opening the URL only drafts a ticket; nothing is submitted."
  (interactive (list (schwab-broker-ticket--read-order) t))
  (let ((kinds (schwab-broker-ticket-violations order)))
    (when kinds
      (schwab-broker-ticket--fail
       "Invalid order: %s"
       (mapconcat (lambda (k)
                    (or (alist-get k schwab-broker-ticket--violation-text)
                        (symbol-name k)))
                  kinds "; ")))
    (let ((url (schwab-broker-ticket--build order)))
      (when copy
        (kill-new url)
        (message "Copied: %s\n%s\n%s" url (schwab-broker-ticket-summary order)
                 schwab-broker-ticket-review-reminder))
      url)))

;;;###autoload
(defun schwab-broker-ticket-open (order)
  "Open a prefilled thinkorswim ticket for ORDER in the browser.
ORDER is a plist, see the Commentary; interactively it is prompted for.
The ticket opens as a DRAFT in a signed-in thinkorswim web session
after about 1.5 seconds; review and send it there.  This function
never submits anything.  Return the URL."
  (interactive (list (schwab-broker-ticket--read-order)))
  (let ((url (schwab-broker-ticket-url order)))
    (browse-url url)
    (message "Opened thinkorswim ticket draft: %s\n%s\n%s" url
             (schwab-broker-ticket-summary order)
             schwab-broker-ticket-review-reminder)
    url))

;; -- positions and order specs ---------------------------------------------

(defconst schwab-broker-ticket--ticketable-asset-types
  '("EQUITY" "OPTION" "COLLECTIVE_INVESTMENT")
  "Schwab assetType values a position may have to get a closing ticket.")

;;;###autoload
(cl-defun schwab-broker-ticket-for-position
    (position &key order-type limit stop tif)
  "Return the ticket order that closes POSITION.
POSITION is a Schwab position alist as returned by
`schwab-broker-positions' (longQuantity, shortQuantity, instrument).
The leg is the net position negated: short 1 put gives buy 1 of that
put, long 100 shares gives sell 100.  ORDER-TYPE, LIMIT, STOP and TIF
fill the rest of the order.  Signal `schwab-broker-ticket-error' for a
flat or fractional position, or an asset type with no ticket."
  (let* ((inst (alist-get 'instrument position))
         (symbol (alist-get 'symbol inst))
         (asset (alist-get 'assetType inst))
         (net (- (or (alist-get 'longQuantity position) 0)
                 (or (alist-get 'shortQuantity position) 0))))
    (unless (and (stringp symbol) (not (string-empty-p symbol)))
      (schwab-broker-ticket--fail "Position has no instrument symbol"))
    (unless (or (null asset)
                (member asset schwab-broker-ticket--ticketable-asset-types))
      (schwab-broker-ticket--fail "No ticket for %s positions (%s)" asset symbol))
    (when (zerop net)
      (schwab-broker-ticket--fail "Position %s is flat" symbol))
    (unless (= net (round net))
      (schwab-broker-ticket--fail "Position %s has fractional quantity %s"
                                  symbol net))
    (list :legs (list (list :qty (- (round net)) :instrument symbol))
          :order-type order-type :limit limit :stop stop :tif tif)))

(defun schwab-broker-ticket--position-label (position)
  "One-line completion label for Schwab position alist POSITION."
  (let ((net (- (or (alist-get 'longQuantity position) 0)
                (or (alist-get 'shortQuantity position) 0))))
    (format "%s  %s%s" (alist-get 'symbol (alist-get 'instrument position))
            (if (> net 0) "long " "short ") (abs net))))

;;;###autoload
(defun schwab-broker-ticket-close-position (&optional position)
  "Open the closing ticket for a Schwab POSITION in thinkorswim web.
POSITION is a Schwab position alist.  Interactively, fetch positions
with `schwab-broker-positions-sync' (needs a token) and choose one;
then prompt for a limit price and time in force.  The ticket is a
draft; nothing is submitted.  Return the URL."
  (interactive)
  (let* ((position
          (or position
              (progn
                (require 'schwab-broker-trader)
                (let* ((all (schwab-broker-positions-sync))
                       (table (mapcar (lambda (p)
                                        (cons (schwab-broker-ticket--position-label p) p))
                                      all))
                       (choice (completing-read "Close position: " table nil t)))
                  (cdr (assoc choice table))))))
         (tif (schwab-broker-ticket--enum
               (completing-read "Time in force: " schwab-broker-ticket-tifs
                                nil t)
               schwab-broker-ticket-tifs "time in force"))
         (limit (schwab-broker-ticket--read-price "Limit price: ")))
    (schwab-broker-ticket-open
     (schwab-broker-ticket-for-position position :order-type "LIMIT"
                                        :limit limit :tif tif))))

(defconst schwab-broker-ticket--spec-order-types
  '(("MARKET" . "MARKET") ("LIMIT" . "LIMIT") ("STOP" . "STOP")
    ("STOP_LIMIT" . "STOPLIMIT") ("MARKET_ON_CLOSE" . "MOC")
    ("LIMIT_ON_CLOSE" . "LOC")
    ("NET_DEBIT" . "LIMIT") ("NET_CREDIT" . "LIMIT"))
  "Map Schwab order-spec orderType to the ticket `orderType'.
NET_DEBIT and NET_CREDIT map to LIMIT; the site takes the absolute
price and decides debit or credit itself (unverified live).")

;;;###autoload
(defun schwab-broker-ticket-from-order-spec (spec)
  "Translate Schwab order-spec alist SPEC into a ticket order plist.
SPEC is what `schwab-broker-order-spec' and its wrappers build.  Buy
instructions (BUY, BUY_TO_OPEN, BUY_TO_CLOSE, BUY_TO_COVER) become
positive quantities and sell instructions negative ones.  Duration DAY
and GOOD_TILL_CANCEL map to the DAY and GTC time in force; any other
duration, and the session, are left to the site's defaults.  The
open/close distinction has no URL parameter and is dropped."
  (let* ((legs (mapcar
                (lambda (leg)
                  (let* ((ins (alist-get 'instruction leg))
                         (sign (cond ((member ins '("BUY" "BUY_TO_OPEN" "BUY_TO_CLOSE"
                                                    "BUY_TO_COVER"))
                                      1)
                                     ((member ins '("SELL" "SELL_TO_OPEN" "SELL_TO_CLOSE"
                                                    "SELL_SHORT"))
                                      -1)
                                     (t (schwab-broker-ticket--fail
                                         "Unknown instruction %S" ins))))
                         (qty (alist-get 'quantity leg)))
                    (unless (and (numberp qty) (> qty 0) (= qty (round qty)))
                      (schwab-broker-ticket--fail
                       "Leg quantity %S must be a positive integer" qty))
                    (list :qty (* sign (round qty))
                          :instrument (alist-get 'symbol
                                                 (alist-get 'instrument leg)))))
                (append (alist-get 'orderLegCollection spec) nil)))
         (spec-type (alist-get 'orderType spec))
         (type (and spec-type
                    (or (cdr (assoc spec-type schwab-broker-ticket--spec-order-types))
                        (schwab-broker-ticket--fail
                         "No ticket order type for %S" spec-type))))
         (tif (pcase (alist-get 'duration spec)
                ("DAY" "DAY") ("GOOD_TILL_CANCEL" "GTC") (_ nil))))
    (list :legs legs :order-type type
          :limit (alist-get 'price spec) :stop (alist-get 'stopPrice spec)
          :tif tif)))

(provide 'schwab-broker-ticket)
;;; schwab-broker-ticket.el ends here
