;;; schwab-broker.el --- Charles Schwab Trader & Market Data API client -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Homepage: https://github.com/davidawad/schwab-broker.el
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A pure-Elisp client for the Charles Schwab Trader & Market Data
;; APIs, built entirely on the built-in `url' (HTTP) and native JSON
;; (`json-parse-buffer'/`json-serialize') facilities -- no external
;; binary, no Python, no third-party HTTP/JSON library.
;;
;; Register an app at https://developer.schwab.com to get a Consumer
;; Key/Secret pair and register a callback URL, then:
;;
;;   (setq schwab-broker-app-key "your-consumer-key"
;;         schwab-broker-app-secret "your-consumer-secret")
;;   M-x schwab-broker-authorize
;;
;; `schwab-broker-authorize' opens Schwab's consent page in a browser,
;; and once you approve access and are redirected, prompts you to
;; paste the full redirect URL back -- the "manual authorize" flow
;; Schwab's own OAuth requires for a script/desktop app with no public
;; HTTP callback listener.  From then on, every request in this
;; package refreshes the access token on disk automatically as it
;; nears expiry.
;;
;; Provided by the three files this one loads:
;;
;;   `schwab-broker-oauth' -- credentials, the manual-authorize flow,
;;   the on-disk token store, and the shared async HTTP/request core
;;   (`schwab-broker-authorize', `schwab-broker-auth-status').
;;
;;   `schwab-broker-marketdata' -- quotes, price history, option
;;   chains, market hours, movers (`schwab-broker-quote',
;;   `schwab-broker-quotes', `schwab-broker-price-history',
;;   `schwab-broker-option-chain', `schwab-broker-market-hours',
;;   `schwab-broker-movers', and the demo command
;;   `schwab-broker-show-quote').
;;
;;   `schwab-broker-trader' -- account numbers, accounts, positions
;;   (`schwab-broker-account-numbers', `schwab-broker-accounts',
;;   `schwab-broker-positions').  Deliberately read-only: no
;;   order-placement endpoint is implemented anywhere in this package.
;;
;; Every entry point above has both an async form (its bare name,
;; taking a CALLBACK of (DATA ERR)) and a blocking `-sync' form that
;; returns DATA directly or signals `schwab-broker-error'.
;;
;; The on-disk token file (`schwab-broker-token-file', default
;; ~/.config/schwab/token.json) uses the same JSON shape as this
;; package's reference Python-side sibling implementation
;; (access_token/refresh_token/both expiries), so a Python client and
;; this Emacs client can share one token file and interoperate.

;;; Code:

(require 'schwab-broker-oauth)
(require 'schwab-broker-marketdata)
(require 'schwab-broker-trader)

(provide 'schwab-broker)
;;; schwab-broker.el ends here
