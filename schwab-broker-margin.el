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
  "Per-share out-of-the-money amount of a KIND (`put'/`call') option."
  (max 0.0 (if (eq kind 'put) (- underlying strike) (- strike underlying))))

(defun schwab-broker-margin--short-option (kind strike premium underlying qty
                                                pct min-pct house-extra)
  "Shared naked-option math for KIND, with leg percentages PCT and MIN-PCT."
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
Same keys as `schwab-broker-margin-short-put'; the minimum leg is
MIN-PCT of the underlying value rather than the strike."
  (schwab-broker-margin--short-option 'call strike premium underlying qty
                                      pct min-pct house-extra))

(provide 'schwab-broker-margin)
;;; schwab-broker-margin.el ends here
