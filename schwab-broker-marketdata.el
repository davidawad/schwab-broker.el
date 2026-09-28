;;; schwab-broker-marketdata.el --- Schwab Market Data API (quotes, history, chains) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Read-only Schwab Market Data API v1 (https://api.schwabapi.com/marketdata/v1)
;; coverage: quotes (single + batch), price history, option chains (the
;; full parameter surface), market hours, and movers.  Every entry
;; point has an async form (its bare name, taking a CALLBACK of (DATA
;; ERR)) and a `-sync' form built on top of it via `schwab-broker--sync-call'.

;;; Code:

(require 'cl-lib)
(require 'schwab-broker-oauth)

(defconst schwab-broker--marketdata-base
  "https://api.schwabapi.com/marketdata/v1")

(defun schwab-broker--number-param (value)
  "Return VALUE as a query-parameter string, or nil when VALUE is nil."
  (when value
    (format "%s" value)))

(defun schwab-broker--bool-param (value)
  "Map VALUE to a Schwab boolean query-parameter string, or nil.
VALUE of t maps to \"true\", the keyword :false maps to \"false\", and
anything else (including plain nil) maps to nil so the parameter is
omitted and Schwab's own default applies."
  (cond
   ((eq value t)
    "true")
   ((eq value :false)
    "false")))

;;;###autoload
(defun schwab-broker-quote (symbol callback)
  "Fetch SYMBOL's quote asynchronously and call CALLBACK.
CALLBACK is called with two arguments, QUOTE-ALIST and ERR."
  (let ((upper (upcase symbol)))
    (schwab-broker--request
     schwab-broker--marketdata-base
     (format "/%s/quotes" (url-hexify-string upper))
     nil
     (lambda (data err)
       (funcall callback
                (and data (alist-get (intern upper) data)) err)))))

;;;###autoload
(defun schwab-broker-quote-sync (symbol)
  "Synchronous form of `schwab-broker-quote' for SYMBOL."
  (schwab-broker--sync-call
   (lambda (callback) (schwab-broker-quote symbol callback))))

;;;###autoload
(defun schwab-broker-quotes (symbols callback)
  "Fetch quotes for SYMBOLS asynchronously and call CALLBACK.
SYMBOLS is a list of strings, or a single comma-separated string.
CALLBACK is called with two arguments, QUOTES-ALIST and ERR --
Schwab's own `/quotes' response shape, an alist keyed by symbol."
  (let ((joined
         (if (stringp symbols)
             symbols
           (mapconcat #'upcase symbols ","))))
    (schwab-broker--request
     schwab-broker--marketdata-base
     "/quotes"
     `(("symbols" . ,joined))
     callback)))

;;;###autoload
(defun schwab-broker-quotes-sync (symbols)
  "Synchronous form of `schwab-broker-quotes' for SYMBOLS."
  (schwab-broker--sync-call
   (lambda (callback) (schwab-broker-quotes symbols callback))))

;;;###autoload
(cl-defun
 schwab-broker-price-history
 (symbol
  callback
  &key
  period-type
  period
  frequency-type
  frequency
  start
  end
  need-extended-hours-data
  need-previous-close)
 "Fetch SYMBOL's price history asynchronously and call CALLBACK.
CALLBACK is called with two arguments, HISTORY-ALIST and ERR.  Keyword
arguments map onto Schwab's own `/pricehistory' query parameters:
PERIOD-TYPE -> periodType, PERIOD -> period, FREQUENCY-TYPE ->
frequencyType, FREQUENCY -> frequency, START -> startDate (epoch
milliseconds), END -> endDate (epoch milliseconds),
NEED-EXTENDED-HOURS-DATA/NEED-PREVIOUS-CLOSE -> their camelCase Schwab
equivalents (pass t or :false explicitly -- plain nil omits the
parameter and lets Schwab's own default apply)."
 (schwab-broker--request
  schwab-broker--marketdata-base "/pricehistory"
  `(("symbol" . ,(upcase symbol))
    ("periodType" . ,period-type)
    ("period" . ,(schwab-broker--number-param period))
    ("frequencyType" . ,frequency-type)
    ("frequency" . ,(schwab-broker--number-param frequency))
    ("startDate" . ,(schwab-broker--number-param start))
    ("endDate" . ,(schwab-broker--number-param end))
    ("needExtendedHoursData"
     .
     ,(schwab-broker--bool-param need-extended-hours-data))
    ("needPreviousClose" . ,(schwab-broker--bool-param need-previous-close)))
  callback))

;;;###autoload
(defun schwab-broker-price-history-sync (symbol &rest keys)
  "Synchronous form of `schwab-broker-price-history' for SYMBOL.
KEYS is the same keyword-argument list `schwab-broker-price-history' accepts."
  (schwab-broker--sync-call
   (lambda (callback)
     (apply #'schwab-broker-price-history symbol callback keys))))

;;;###autoload
(cl-defun
 schwab-broker-option-chain
 (symbol
  callback
  &key
  contract-type
  strike-count
  include-underlying-quote
  strategy
  interval
  strike
  range
  from-date
  to-date
  volatility
  underlying-price
  interest-rate
  days-to-expiration
  exp-month
  option-type)
 "Fetch SYMBOL's option chain asynchronously and call CALLBACK.
CALLBACK is called with two arguments, CHAIN-ALIST and ERR.  Keyword
arguments cover Schwab's full `/chains' query-parameter surface:
CONTRACT-TYPE -> contractType, STRIKE-COUNT -> strikeCount,
INCLUDE-UNDERLYING-QUOTE -> includeUnderlyingQuote (t or :false),
STRATEGY -> strategy, INTERVAL -> interval, STRIKE -> strike, RANGE ->
range, FROM-DATE -> fromDate, TO-DATE -> toDate, VOLATILITY ->
volatility, UNDERLYING-PRICE -> underlyingPrice, INTEREST-RATE ->
interestRate, DAYS-TO-EXPIRATION -> daysToExpiration, EXP-MONTH ->
expMonth, OPTION-TYPE -> optionType."
 (schwab-broker--request
  schwab-broker--marketdata-base "/chains"
  `(("symbol" . ,(upcase symbol))
    ("contractType" . ,contract-type)
    ("strikeCount" . ,(schwab-broker--number-param strike-count))
    ("includeUnderlyingQuote"
     .
     ,(schwab-broker--bool-param include-underlying-quote))
    ("strategy" . ,strategy)
    ("interval" . ,(schwab-broker--number-param interval))
    ("strike" . ,(schwab-broker--number-param strike))
    ("range" . ,range)
    ("fromDate" . ,from-date)
    ("toDate" . ,to-date)
    ("volatility" . ,(schwab-broker--number-param volatility))
    ("underlyingPrice" . ,(schwab-broker--number-param underlying-price))
    ("interestRate" . ,(schwab-broker--number-param interest-rate))
    ("daysToExpiration" . ,(schwab-broker--number-param days-to-expiration))
    ("expMonth" . ,exp-month)
    ("optionType" . ,option-type))
  callback))

;;;###autoload
(defun schwab-broker-option-chain-sync (symbol &rest keys)
  "Synchronous form of `schwab-broker-option-chain' for SYMBOL.
KEYS is the same keyword-argument list `schwab-broker-option-chain' accepts."
  (schwab-broker--sync-call
   (lambda (callback)
     (apply #'schwab-broker-option-chain symbol callback keys))))

;;;###autoload
(cl-defun
 schwab-broker-market-hours (markets callback &key date)
 "Fetch market hours for MARKETS asynchronously and call CALLBACK.
MARKETS is a list like (\"equity\" \"option\"), or a single
comma-separated string.  CALLBACK is called with two arguments,
HOURS-ALIST and ERR.  DATE, when given, is an ISO YYYY-MM-DD string."
 (let ((joined
        (if (stringp markets)
            markets
          (mapconcat #'identity markets ","))))
   (schwab-broker--request
    schwab-broker--marketdata-base
    "/markets"
    `(("markets" . ,joined) ("date" . ,date))
    callback)))

;;;###autoload
(defun schwab-broker-market-hours-sync (markets &rest keys)
  "Synchronous form of `schwab-broker-market-hours' for MARKETS.
KEYS is the same keyword-argument list `schwab-broker-market-hours' accepts."
  (schwab-broker--sync-call
   (lambda (callback)
     (apply #'schwab-broker-market-hours markets callback keys))))

;;;###autoload
(cl-defun
 schwab-broker-movers (index callback &key sort frequency)
 "Fetch the day's top movers for INDEX asynchronously and call CALLBACK.
INDEX is an index/exchange code (e.g. \"$DJI\", \"$SPX\", \"NASDAQ\").
CALLBACK is called with two arguments, MOVERS-ALIST and ERR.  SORT and
FREQUENCY map onto Schwab's own `/movers' query parameters."
 (schwab-broker--request
  schwab-broker--marketdata-base
  (format "/movers/%s" (url-hexify-string index))
  `(("sort" . ,sort)
    ("frequency" . ,(schwab-broker--number-param frequency)))
  callback))

;;;###autoload
(defun schwab-broker-movers-sync (index &rest keys)
  "Synchronous form of `schwab-broker-movers' for INDEX.
KEYS is the same keyword-argument list `schwab-broker-movers' accepts."
  (schwab-broker--sync-call
   (lambda (callback) (apply #'schwab-broker-movers index callback keys))))

;;;###autoload
(defun schwab-broker-show-quote (symbol)
  "Fetch SYMBOL's quote synchronously and show its last/mark price.
A minimal end-to-end demo command: run `schwab-broker-authorize' first."
  (interactive "sSchwab symbol: ")
  (let* ((data (schwab-broker-quote-sync symbol))
         (quote-data (alist-get 'quote data))
         (last (and quote-data (alist-get 'lastPrice quote-data))))
    (if last
        (message "%s: last %s (mark %s)"
                 (upcase symbol)
                 last
                 (alist-get 'mark quote-data))
      (message "%s: %S" (upcase symbol) data))))

(provide 'schwab-broker-marketdata)
;;; schwab-broker-marketdata.el ends here
