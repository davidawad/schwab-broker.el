;;; schwab-broker-trader.el --- Schwab Trader API (accounts, positions) -*- lexical-binding: t; -*-

;; Author: David Awad
;; Keywords: comm, tools, finance

;;; Commentary:

;; Read-only Schwab Trader API v1 (https://api.schwabapi.com/trader/v1)
;; coverage: account numbers, accounts (optionally with positions), and
;; a flattened positions view across all accounts.
;;
;; Roadmap / deliberately NOT implemented: order placement of any kind.
;; There is no `schwab-broker-place-order'/`schwab-broker-stage-order' function
;; anywhere in this package, by construction -- this client is
;; read-only market-data and account access only.  A future order-
;; placement surface, if ever added, belongs in its own explicit,
;; separately-reviewed entry points, never bolted onto this file.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'schwab-broker-oauth)

(defconst schwab-broker--trader-base "https://api.schwabapi.com/trader/v1")

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

(provide 'schwab-broker-trader)
;;; schwab-broker-trader.el ends here
