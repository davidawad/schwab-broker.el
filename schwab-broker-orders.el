;;; schwab-broker-orders.el --- Schwab order-spec builders -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Pure functions that build Schwab order-spec alists (the JSON body
;; `schwab-broker-place-order'/`schwab-broker-preview-order'/
;; `schwab-broker-replace-order' send), mirroring the order templates
;; in this package's reference Python-side sibling implementation
;; (schwab-py's `schwab.orders.equities'/`schwab.orders.options').
;; None of these functions perform I/O or touch the network -- they
;; only assemble the JSON alist Schwab's API expects.
;;
;; INSTRUCTION is one of Schwab's own instruction enums: "BUY", "SELL"
;; for equities; "BUY_TO_OPEN", "BUY_TO_CLOSE", "SELL_TO_OPEN",
;; "SELL_TO_CLOSE" for options.  OPTION-SYMBOL is Schwab's 21-character
;; OCC-style option symbol, e.g. "AAPL  251017C00150000".

;;; Code:

(require 'cl-lib)

(defun schwab-broker--order-leg (instruction quantity instrument)
  "Build one Schwab order-leg alist from INSTRUCTION, QUANTITY, INSTRUMENT."
  `((instruction . ,instruction)
    (quantity . ,quantity)
    (instrument . ,instrument)))

(defun schwab-broker--equity-instrument (symbol)
  "Build a Schwab EQUITY instrument alist for SYMBOL."
  `((symbol . ,(upcase symbol)) (assetType . "EQUITY")))

(defun schwab-broker--option-instrument (option-symbol)
  "Build a Schwab OPTION instrument alist for OPTION-SYMBOL."
  `((symbol . ,(upcase option-symbol)) (assetType . "OPTION")))

;;;###autoload
(cl-defun
 schwab-broker-order-spec
 (&key
  order-type
  (session "NORMAL")
  (duration "DAY")
  (order-strategy-type "SINGLE")
  price
  stop-price
  legs)
 "Build a generic Schwab order-spec alist, the JSON body order endpoints send.
ORDER-TYPE is Schwab's own enum (\"MARKET\", \"LIMIT\", \"STOP\",
\"STOP_LIMIT\", ...).  SESSION, DURATION, and ORDER-STRATEGY-TYPE
default to \"NORMAL\", \"DAY\", and \"SINGLE\".  PRICE and STOP-PRICE
are included only when given.  LEGS is a list of order-leg alists (see
`schwab-broker--order-leg')."
 `((orderType . ,order-type)
   (session . ,session)
   (duration . ,duration)
   (orderStrategyType . ,order-strategy-type)
   ,@(when price `((price . ,price)))
   ,@(when stop-price `((stopPrice . ,stop-price)))
   (orderLegCollection . ,(vconcat legs))))

;;;###autoload
(defun schwab-broker-order-equity-market (symbol instruction quantity)
  "Build a market order-spec to INSTRUCTION QUANTITY shares of SYMBOL."
  (schwab-broker-order-spec
   :order-type "MARKET"
   :legs
   (list
    (schwab-broker--order-leg
     instruction quantity (schwab-broker--equity-instrument symbol)))))

;;;###autoload
(defun schwab-broker-order-equity-limit (symbol instruction quantity price)
  "Build a limit order-spec to INSTRUCTION QUANTITY shares of SYMBOL at PRICE."
  (schwab-broker-order-spec
   :order-type "LIMIT"
   :price price
   :legs
   (list
    (schwab-broker--order-leg
     instruction quantity (schwab-broker--equity-instrument symbol)))))

;;;###autoload
(defun schwab-broker-order-equity-stop
    (symbol instruction quantity stop-price)
 "Build a stop order-spec to INSTRUCTION QUANTITY shares of SYMBOL.
Triggers at STOP-PRICE."
 (schwab-broker-order-spec
  :order-type "STOP"
  :stop-price stop-price
  :legs
  (list
   (schwab-broker--order-leg
    instruction quantity (schwab-broker--equity-instrument symbol)))))

;;;###autoload
(defun schwab-broker-order-equity-stop-limit
    (symbol instruction quantity stop-price price)
 "Build a stop-limit order-spec for SYMBOL.
INSTRUCTION and QUANTITY behave as elsewhere in this file; the order
triggers at STOP-PRICE and then limits at PRICE."
 (schwab-broker-order-spec
  :order-type "STOP_LIMIT"
  :stop-price stop-price
  :price price
  :legs
  (list
   (schwab-broker--order-leg
    instruction quantity (schwab-broker--equity-instrument symbol)))))

;;;###autoload
(defun schwab-broker-order-option-market
    (option-symbol instruction quantity)
 "Build a market order-spec to INSTRUCTION QUANTITY contracts of OPTION-SYMBOL."
 (schwab-broker-order-spec
  :order-type "MARKET"
  :legs
  (list
   (schwab-broker--order-leg
    instruction quantity (schwab-broker--option-instrument option-symbol)))))

;;;###autoload
(defun schwab-broker-order-option-limit
    (option-symbol instruction quantity price)
 "Build a limit order-spec to INSTRUCTION QUANTITY contracts of OPTION-SYMBOL.
Limits at PRICE."
 (schwab-broker-order-spec
  :order-type "LIMIT"
  :price price
  :legs
  (list
   (schwab-broker--order-leg
    instruction quantity (schwab-broker--option-instrument option-symbol)))))

(provide 'schwab-broker-orders)
;;; schwab-broker-orders.el ends here
