;;; schwab-broker-trader.el --- Schwab Trader API (accounts, orders, transactions) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Full Schwab Trader API v1 (https://api.schwabapi.com/trader/v1)
;; coverage: account numbers, accounts (optionally with positions), a
;; single account, orders (list/place/get/replace/cancel, per-account
;; and across all linked accounts), order preview, transactions, and
;; user preferences.
;;
;; Order safety: this is a REAL-MONEY brokerage account API with no
;; sandbox.  `schwab-broker-place-order', `schwab-broker-replace-order',
;; and `schwab-broker-cancel-order' (and their `-sync' forms) all
;; signal a `user-error' unless `schwab-broker-allow-orders' is
;; non-nil; it defaults to nil.  `schwab-broker-preview-order' is never
;; gated -- Schwab's own `/previewOrder' endpoint only simulates and
;; places nothing.
;;
;; ACCOUNT-HASH throughout this file is the opaque `hashValue' Schwab
;; returns from `schwab-broker-account-numbers', never the plain
;; account number -- that is what Schwab's own account-scoped paths
;; require.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'schwab-broker-oauth)

(defconst schwab-broker--trader-base "https://api.schwabapi.com/trader/v1")

(defcustom schwab-broker-allow-orders nil
  "Non-nil to allow placing, replacing, or cancelling live orders.
This is a REAL-MONEY brokerage account API with no sandbox: when this
is nil (the default), `schwab-broker-place-order',
`schwab-broker-replace-order', and `schwab-broker-cancel-order' (and
their `-sync' forms) signal a `user-error' instead of ever reaching
the network.  `schwab-broker-preview-order' is never gated by this
variable, since Schwab's own `/previewOrder' endpoint only simulates
an order and places nothing."
  :type 'boolean
  :group 'schwab-broker)

(defun schwab-broker--ensure-orders-allowed ()
  "Signal a `user-error' unless `schwab-broker-allow-orders' is non-nil."
  (unless schwab-broker-allow-orders
    (user-error
     "Schwab: live order placement/replacement/cancellation is
disabled -- this is a REAL-MONEY brokerage account with no sandbox.
Set `schwab-broker-allow-orders' to non-nil to enable it")))

;; -- account numbers / accounts / positions --

;;;###autoload
(defun schwab-broker-account-numbers (callback)
  "Fetch the caller's Schwab account-number/hash-value mappings.
Asynchronous; CALLBACK is called with two arguments, ACCOUNTS-LIST and
ERR."
  (schwab-broker--request
   schwab-broker--trader-base "/accounts/accountNumbers" nil callback))

;;;###autoload
(defun schwab-broker-account-numbers-sync ()
  "Synchronous form of `schwab-broker-account-numbers'."
  (schwab-broker--sync-call #'schwab-broker-account-numbers))

;;;###autoload
(cl-defun
 schwab-broker-accounts
 (callback &key positions)
 "Fetch all of the caller's Schwab accounts asynchronously and call CALLBACK.
CALLBACK is called with two arguments, ACCOUNTS-LIST and ERR.  Non-nil
POSITIONS additionally requests each account's `positions' field."
 (schwab-broker--request
  schwab-broker--trader-base "/accounts"
  (when positions
    '(("fields" . "positions")))
  callback))

;;;###autoload
(cl-defun
 schwab-broker-accounts-sync (&key positions)
 "Synchronous form of `schwab-broker-accounts'.
POSITIONS is passed through unchanged."
 (schwab-broker--sync-call
  (lambda (callback)
    (schwab-broker-accounts callback :positions positions))))

;;;###autoload
(cl-defun
 schwab-broker-account (account-hash callback &key positions)
 "Fetch one Schwab account, ACCOUNT-HASH, asynchronously and call CALLBACK.
CALLBACK is called with two arguments, ACCOUNT-ALIST and ERR.  Non-nil
POSITIONS additionally requests the account's `positions' field."
 (schwab-broker--request
  schwab-broker--trader-base
  (format "/accounts/%s" (url-hexify-string account-hash))
  (when positions
    '(("fields" . "positions")))
  callback))

;;;###autoload
(cl-defun
 schwab-broker-account-sync (account-hash &key positions)
 "Synchronous form of `schwab-broker-account' for ACCOUNT-HASH.
POSITIONS is passed through unchanged."
 (schwab-broker--sync-call
  (lambda (callback)
    (schwab-broker-account account-hash callback :positions positions))))

(defun schwab-broker--flatten-positions (accounts)
  "Flatten ACCOUNTS into one list of position alists.
ACCOUNTS is as returned by `schwab-broker-accounts' with POSITIONS; each
resulting position is tagged with its accountNumber."
  (seq-mapcat
   (lambda (entry)
     (let* ((securities-account (alist-get 'securitiesAccount entry))
            (account-number
             (alist-get 'accountNumber securities-account)))
       (mapcar
        (lambda (position)
          (append position `((accountNumber . ,account-number))))
        (alist-get 'positions securities-account))))
   accounts))

;;;###autoload
(defun schwab-broker-positions (callback)
  "Fetch a flat list of positions across all Schwab accounts and call CALLBACK.
Each position is tagged with its accountNumber.  CALLBACK is called
with two arguments, POSITIONS-LIST and ERR."
  (schwab-broker-accounts
   (lambda (accounts err)
     (if err
         (funcall callback nil err)
       (funcall callback (schwab-broker--flatten-positions accounts) nil)))
   :positions t))

;;;###autoload
(defun schwab-broker-positions-sync ()
  "Synchronous form of `schwab-broker-positions'."
  (schwab-broker--sync-call #'schwab-broker-positions))

;; -- orders: per-account list/place, single get/replace/cancel --

(defun schwab-broker--orders-params
    (max-results from-entered-time to-entered-time status)
  "Build the shared query-parameter alist for the two order-list endpoints.
MAX-RESULTS, FROM-ENTERED-TIME, TO-ENTERED-TIME, and STATUS map onto
Schwab's own maxResults/fromEnteredTime/toEnteredTime/status
parameters."
  `(("maxResults" . ,(schwab-broker--number-param max-results))
    ("fromEnteredTime" . ,from-entered-time)
    ("toEnteredTime" . ,to-entered-time)
    ("status" . ,status)))

;;;###autoload
(cl-defun
 schwab-broker-orders-for-account
 (account-hash
  callback
  &key
  max-results
  from-entered-time
  to-entered-time
  status)
 "List orders for ACCOUNT-HASH asynchronously and call CALLBACK.
CALLBACK is called with two arguments, ORDERS-LIST and ERR.  Keyword
arguments map onto Schwab's own `/orders' query parameters:
MAX-RESULTS -> maxResults, FROM-ENTERED-TIME -> fromEnteredTime (an
ISO-8601 date-time), TO-ENTERED-TIME -> toEnteredTime, STATUS ->
status (one of Schwab's own order-status enum values)."
 (schwab-broker--request
  schwab-broker--trader-base
  (format "/accounts/%s/orders" (url-hexify-string account-hash))
  (schwab-broker--orders-params
   max-results from-entered-time to-entered-time status)
  callback))

;;;###autoload
(defun schwab-broker-orders-for-account-sync (account-hash &rest keys)
  "Synchronous form of `schwab-broker-orders-for-account' for ACCOUNT-HASH.
KEYS is the same keyword-argument list
`schwab-broker-orders-for-account' accepts."
  (schwab-broker--sync-call
   (lambda (callback)
     (apply #'schwab-broker-orders-for-account account-hash callback keys))))

;;;###autoload
(defun schwab-broker-place-order (account-hash order-spec callback)
  "Place ORDER-SPEC for ACCOUNT-HASH asynchronously and call CALLBACK.
ORDER-SPEC is an alist as built by `schwab-broker-order-spec' or one of
its convenience wrappers in `schwab-broker-orders'.  CALLBACK is
called with two arguments, RESPONSE (usually nil -- Schwab returns 201
with no body and the new order's id in a `Location' header this
package does not currently surface) and ERR.  Signals a `user-error'
unless `schwab-broker-allow-orders' is non-nil -- see that variable."
  (schwab-broker--ensure-orders-allowed)
  (schwab-broker--json-request
   schwab-broker--trader-base
   (format "/accounts/%s/orders" (url-hexify-string account-hash))
   nil callback "POST" order-spec))

;;;###autoload
(defun schwab-broker-place-order-sync (account-hash order-spec)
  "Synchronous form of `schwab-broker-place-order' for ACCOUNT-HASH/ORDER-SPEC."
  (schwab-broker--sync-call
   (lambda (callback)
     (schwab-broker-place-order account-hash order-spec callback))))

;;;###autoload
(defun schwab-broker-order (account-hash order-id callback)
  "Fetch order ORDER-ID under ACCOUNT-HASH asynchronously and call CALLBACK.
CALLBACK is called with two arguments, ORDER-ALIST and ERR."
  (schwab-broker--request
   schwab-broker--trader-base
   (format
    "/accounts/%s/orders/%s"
    (url-hexify-string account-hash) (url-hexify-string (format "%s" order-id)))
   nil callback))

;;;###autoload
(defun schwab-broker-order-sync (account-hash order-id)
  "Synchronous form of `schwab-broker-order' for ACCOUNT-HASH/ORDER-ID."
  (schwab-broker--sync-call
   (lambda (callback) (schwab-broker-order account-hash order-id callback))))

;;;###autoload
(defun schwab-broker-replace-order (account-hash order-id order-spec callback)
  "Replace order ORDER-ID under ACCOUNT-HASH with ORDER-SPEC and call CALLBACK.
CALLBACK is called with two arguments, RESPONSE and ERR.  Signals a
`user-error' unless `schwab-broker-allow-orders' is non-nil -- see
that variable."
  (schwab-broker--ensure-orders-allowed)
  (schwab-broker--json-request
   schwab-broker--trader-base
   (format
    "/accounts/%s/orders/%s"
    (url-hexify-string account-hash) (url-hexify-string (format "%s" order-id)))
   nil callback "PUT" order-spec))

;;;###autoload
(defun schwab-broker-replace-order-sync (account-hash order-id order-spec)
  "Synchronous form of `schwab-broker-replace-order'.
ACCOUNT-HASH, ORDER-ID, and ORDER-SPEC are passed through unchanged."
  (schwab-broker--sync-call
   (lambda (callback)
     (schwab-broker-replace-order account-hash order-id order-spec callback))))

;;;###autoload
(defun schwab-broker-cancel-order (account-hash order-id callback)
  "Cancel order ORDER-ID under ACCOUNT-HASH asynchronously and call CALLBACK.
CALLBACK is called with two arguments, RESPONSE and ERR.  Signals a
`user-error' unless `schwab-broker-allow-orders' is non-nil -- see
that variable."
  (schwab-broker--ensure-orders-allowed)
  (schwab-broker--request
   schwab-broker--trader-base
   (format
    "/accounts/%s/orders/%s"
    (url-hexify-string account-hash) (url-hexify-string (format "%s" order-id)))
   nil callback "DELETE"))

;;;###autoload
(defun schwab-broker-cancel-order-sync (account-hash order-id)
  "Synchronous form of `schwab-broker-cancel-order' for ACCOUNT-HASH/ORDER-ID."
  (schwab-broker--sync-call
   (lambda (callback)
     (schwab-broker-cancel-order account-hash order-id callback))))

;; -- orders across all linked accounts --

;;;###autoload
(cl-defun
 schwab-broker-orders
 (callback &key max-results from-entered-time to-entered-time status)
 "List orders across all of the caller's linked Schwab accounts.
Asynchronous; CALLBACK is called with two arguments, ORDERS-LIST and
ERR.  MAX-RESULTS, FROM-ENTERED-TIME, TO-ENTERED-TIME, and STATUS are
the same keyword arguments as `schwab-broker-orders-for-account'."
 (schwab-broker--request
  schwab-broker--trader-base "/orders"
  (schwab-broker--orders-params
   max-results from-entered-time to-entered-time status)
  callback))

;;;###autoload
(defun schwab-broker-orders-sync (&rest keys)
  "Synchronous form of `schwab-broker-orders'.
KEYS is the same keyword-argument list `schwab-broker-orders' accepts."
  (schwab-broker--sync-call
   (lambda (callback) (apply #'schwab-broker-orders callback keys))))

;; -- preview order (never gated -- simulates only) --

;;;###autoload
(defun schwab-broker-preview-order (account-hash order-spec callback)
  "Preview (simulate) ORDER-SPEC for ACCOUNT-HASH and call CALLBACK.
Asynchronous.
CALLBACK is called with two arguments, PREVIEW-ALIST and ERR.  Never
gated by `schwab-broker-allow-orders' -- Schwab's own `/previewOrder'
endpoint only simulates an order and places nothing."
  (schwab-broker--json-request
   schwab-broker--trader-base
   (format "/accounts/%s/previewOrder" (url-hexify-string account-hash))
   nil callback "POST" order-spec))

;;;###autoload
(defun schwab-broker-preview-order-sync (account-hash order-spec)
  "Synchronous form of `schwab-broker-preview-order'.
ACCOUNT-HASH and ORDER-SPEC are passed through unchanged."
  (schwab-broker--sync-call
   (lambda (callback)
     (schwab-broker-preview-order account-hash order-spec callback))))

;; -- transactions --

;;;###autoload
(cl-defun
 schwab-broker-transactions
 (account-hash callback &key start-date end-date symbol types)
 "List transactions for ACCOUNT-HASH asynchronously and call CALLBACK.
CALLBACK is called with two arguments, TRANSACTIONS-LIST and ERR.
Keyword arguments map onto Schwab's own `/transactions' query
parameters: START-DATE -> startDate, END-DATE -> endDate (both
ISO-8601 date-times, required by Schwab), SYMBOL -> symbol, TYPES ->
types (one of Schwab's own transaction-type enum values, e.g.
\"TRADE\")."
 (schwab-broker--request
  schwab-broker--trader-base
  (format "/accounts/%s/transactions" (url-hexify-string account-hash))
  `(("startDate" . ,start-date)
    ("endDate" . ,end-date)
    ("symbol" . ,symbol)
    ("types" . ,types))
  callback))

;;;###autoload
(defun schwab-broker-transactions-sync (account-hash &rest keys)
  "Synchronous form of `schwab-broker-transactions' for ACCOUNT-HASH.
KEYS is the same keyword-argument list `schwab-broker-transactions' accepts."
  (schwab-broker--sync-call
   (lambda (callback)
     (apply #'schwab-broker-transactions account-hash callback keys))))

;;;###autoload
(defun schwab-broker-transaction (account-hash transaction-id callback)
  "Fetch transaction TRANSACTION-ID under ACCOUNT-HASH and call CALLBACK.
Asynchronous; CALLBACK is called with two arguments, TRANSACTION-ALIST
and ERR."
  (schwab-broker--request
   schwab-broker--trader-base
   (format
    "/accounts/%s/transactions/%s"
    (url-hexify-string account-hash)
    (url-hexify-string (format "%s" transaction-id)))
   nil callback))

;;;###autoload
(defun schwab-broker-transaction-sync (account-hash transaction-id)
  "Synchronous form of `schwab-broker-transaction'.
ACCOUNT-HASH and TRANSACTION-ID are passed through unchanged."
  (schwab-broker--sync-call
   (lambda (callback)
     (schwab-broker-transaction account-hash transaction-id callback))))

;; -- user preference --

;;;###autoload
(defun schwab-broker-user-preference (callback)
  "Fetch the caller's Schwab user preferences asynchronously and call CALLBACK.
CALLBACK is called with two arguments, PREFERENCE-ALIST and ERR."
  (schwab-broker--request
   schwab-broker--trader-base "/userPreference" nil callback))

;;;###autoload
(defun schwab-broker-user-preference-sync ()
  "Synchronous form of `schwab-broker-user-preference'."
  (schwab-broker--sync-call #'schwab-broker-user-preference))

(provide 'schwab-broker-trader)
;;; schwab-broker-trader.el ends here
