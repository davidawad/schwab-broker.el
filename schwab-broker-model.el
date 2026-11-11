;;; schwab-broker-model.el --- Schwab account rules for broker-model -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;; Author: David Awad <me@davidaw.ad>
;; Maintainer: David Awad <me@davidaw.ad>
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1") (broker-model "0.1.0"))
;; Keywords: comm, tools, finance

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Registers Charles Schwab with broker-model (the sibling package
;; broker-model.el): account types cash, reg-t (margin), portfolio-margin
;; and ira (limited margin), each as rule cells layered on the
;; regulatory baseline, every cell citing a Schwab document (short names
;; as in docs/schwab-margin/index.md) or a kd fact id, with a
;; confidence.  Unpublished Schwab values are marked `unpublished',
;; never guessed.
;;
;; This is the only file in schwab-broker.el that depends on
;; broker-model; nothing else requires it.  `schwab-broker-margin.el'
;; keeps its own helpers (test/schwab-broker-model-test.el checks they
;; agree with broker-model on the same inputs).
;;
;; Per-symbol house rules Schwab sets but does not publish can be
;; registered with `schwab-broker-model-set-house-option-multiplier'.

;;; Code:

(require 'broker-model)

(defconst schwab-broker-model--req
  "Schwab REQ: Margin rates and requirements https://www.schwab.com/margin/margin-rates-and-requirements (docs/schwab-margin/reg-t/margin-rates-and-requirements.md, fetched 2026-11-10)"
  "Schwab requirements tables.")
(defconst schwab-broker-model--guide
  "Schwab GUIDE: Charles Schwab Guide to Margin MKT105883W-10 (docs/schwab-margin/reg-t/MKT105883W-10.pdf)"
  "Schwab margin guide.")
(defconst schwab-broker-model--intra
  "Schwab INTRA: Understanding Intraday Margin Buying Power https://www.schwab.com/learn/story/understanding-intraday-margin-buying-power"
  "Schwab intraday buying power article.")
(defconst schwab-broker-model--disc
  "Schwab DISC: Margin Disclosure Statement REG95795-02 https://www.schwab.com/legal/margin-disclosure-statement"
  "Schwab margin disclosure.")
(defconst schwab-broker-model--rbc
  "Schwab RBC: Understanding Risk-Based Concentration and Margin https://www.schwab.com/learn/story/understanding-risk-based-concentration-and-margin"
  "Schwab RBC article.")
(defconst schwab-broker-model--pmapp
  "Schwab PMAPP: Request to Add Portfolio Margin APP95358-12 (07/26) (docs/schwab-margin/portfolio-margin/APP95358-12-01.pdf)"
  "Schwab PM application.")
(defconst schwab-broker-model--pmweb
  "Schwab PMWEB: What is Portfolio Margin? https://www.schwab.com/margin/portfolio-margin"
  "Schwab PM page.")
(defconst schwab-broker-model--pmund
  "Schwab PMUND: Understanding Portfolio Margin https://www.schwab.com/learn/story/understanding-portfolio-margin"
  "Schwab PM article.")
(defconst schwab-broker-model--pmopt
  "Schwab PMOPT: Option Traders: How Portfolio Margin Works https://www.schwab.com/learn/story/option-traders-how-portfolio-margin-works"
  "Schwab PM options article.")
(defconst schwab-broker-model--pmfact
  "Schwab PMFACT: Portfolio Margin factsheet SLS125661-00 (docs/schwab-margin/portfolio-margin/Portfolio-Margin-Factsheet.pdf)"
  "Schwab PM factsheet.")
(defconst schwab-broker-model--tos
  "thinkorswim manual: Portfolio Margin https://toslc.thinkorswim.com/center/howToTos/thinkManual/Miscellaneous/Portfolio-Margin"
  "TOS PM manual.")
(defconst schwab-broker-model--empirical
  "docs/schwab-margin/empirical.md (community evidence vs official text, 2026-11-10)"
  "Empirical comparison.")

(defun schwab-broker-model--c (v s c &optional n)
  "Shorthand rule cell: value V, source S, confidence C, note N."
  (broker-model-cell v s c n))

(defconst schwab-broker-model-rules
  (list
   :min-equity-margin (schwab-broker-model--c 2000.0 (concat schwab-broker-model--req ": at least $2,000 to borrow") 'official)
   :min-equity-naked (schwab-broker-model--c 5000.0 (concat schwab-broker-model--req "; kd f-schwab-naked-5000-minimum-equity") 'official
                                             "minimum ACCOUNT equity to write uncovered options (puts: lesser of $5,000 or max loss); not added to each requirement")
   :long-stock (schwab-broker-model--c '((:min-price 3.0 :initial 0.50 :maintenance 0.25)
                                         (:min-price 0.0 :initial 1.00 :maintenance 1.00))
                                       (concat schwab-broker-model--req " (Equities, long: >= $3 50%/25%, < $3 100%)") 'official)
   :house-stock-maintenance (schwab-broker-model--c 0.0 (concat schwab-broker-model--req " tooltip; " schwab-broker-model--rbc) 'official
                                                    "default is the 25% table rate; Schwab sets higher per-security rates ('in most instances 50%', RBC base rates) that are unpublished: register them per symbol")
   :short-stock (schwab-broker-model--c '(:initial 0.50
                                          :tiers ((:min-price 5.0 :pct 0.30 :per-share 5.0)
                                                  (:min-price 0.0 :pct 1.00 :per-share 2.50)))
                                        (concat schwab-broker-model--req " (short: 30% above $16.66, $5/share $5-$16.66, 100% $2.50-$4.99, $2.50/share below)") 'official
                                        "identical to FINRA 4210(c)(2)-(3) written as greater-of tiers")
   :leveraged-etf-long (schwab-broker-model--c '(:initial 0.50 :initial-per-x 0.25 :maintenance-per-x 0.25 :cap 1.0)
                                               (concat schwab-broker-model--req " (2X 50%/50%, 3X 75%/75%); kd f-schwab-leveraged-etf-margin") 'official)
   :leveraged-etf-short (schwab-broker-model--c '(:initial 0.50 :maintenance-per-x 0.30 :cap 1.0)
                                                (concat schwab-broker-model--req " (short 2X 60%, 3X 90% above the price tiers)") 'official)
   :money-market (schwab-broker-model--c '(:initial 0.10 :maintenance 0.10) (concat schwab-broker-model--req " (Money Market Funds 10%/10%)") 'official
                                         "purchased funds not marginable until 30 days after settlement (100% initial) per REQ footnote 2")
   :treasury-bill (schwab-broker-model--c '(:initial 0.10 :maintenance 0.01) (concat schwab-broker-model--req " (Debt: Treasury Bill 10% / 1%)") 'official)
   :naked-equity (schwab-broker-model--c '(:pct 0.20 :min-pct 0.10) (concat schwab-broker-model--req "; kd f-schwab-regt-naked-equity-put-formula") 'official)
   :naked-narrow-index (schwab-broker-model--c '(:pct 0.20 :min-pct 0.10) (concat schwab-broker-model--req " (narrow-based index)") 'official)
   :naked-broad-index (schwab-broker-model--c '(:pct 0.15 :min-pct 0.10) (concat schwab-broker-model--req " (broad-based index 15%; ETNs 20% not modeled)") 'official)
   :naked-leverage-scaling (schwab-broker-model--c t (concat schwab-broker-model--req " (2X: 30%/20% broad, 40%/20% narrow; 3X: 45%/30%, 60%/30%)") 'official)
   :naked-per-contract-floor (schwab-broker-model--c 100.0 (concat schwab-broker-model--req " ($100 per contract; puts: or max loss)") 'official
                                                     "TDA-era thinkorswim manual used $50 (TOS1LEG)")
   :house-option-multiplier (schwab-broker-model--c 1.0 (concat schwab-broker-model--disc "; " schwab-broker-model--rbc) 'official
                                                    "published formula; Schwab reserves unpublished security-level house surcharges (kd f-schwab-nvda-165p-gap-inferred: ~1.5x on NVDA options, inferred)")
   :long-option (schwab-broker-model--c '(:pct 1.0 :leaps-pct 1.0 :leaps-months 9)
                                        (concat schwab-broker-model--req " (long options 100% of cost; no LEAPS carve-out); PMVS 'long options are not marginable'") 'official
                                        "FINRA would allow 75% beyond 9 months; Schwab does not publish that it does")
   :csp-reserve (schwab-broker-model--c '(:net-of-premium t) (concat schwab-broker-model--req " (CSEP: hold assignment value in cash or cash equivalents)") 'inferred
                                        "Schwab does not say whether the premium received counts toward the assignment value; netting it follows schwab-broker-margin.el")
   :csp-collateral (schwab-broker-model--c '(cash money-market schwab-bank-deposit schwab-value-advantage-fund treasury-under-1y)
                                           (concat schwab-broker-model--req " (CSEP collateral list); kd f-schwab-sgov-not-csep-collateral") 'official
                                           "ETFs (e.g. SGOV) are not on the list")
   :spread-rule (schwab-broker-model--c 'universal-max-loss
                                        (concat schwab-broker-model--req " (credit spread: width x 100 x qty; debit: 100% of cost; complex spreads: lesser of naked sum or max potential loss, same expiry)") 'official
                                        "Schwab picks the pairing and 'may pair options in a manner that does not produce the lowest possible requirement'")
   :straddle-rule (schwab-broker-model--c 'greater-plus-other-premium (concat schwab-broker-model--req " (Straddle/Combo)") 'official)
   :calendar-rule (schwab-broker-model--c 'long-covers-if-later (concat schwab-broker-model--pmapp " (Options Application Agreement: long expiring same or later)") 'official
                                          "diagonal strike differential follows the usual rule; no Schwab worked example")
   :protective-put (schwab-broker-model--c '(:pct-of-strike 0.10) (concat schwab-broker-model--req " (Protective Put: lesser of 10% of exercise + OTM, or long stock requirement)") 'official)
   :collar (schwab-broker-model--c '(:put-pct-of-strike 0.10 :call-pct-of-strike 0.25) (concat schwab-broker-model--req " (Collars with Long Equity)") 'official)
   :bp-overnight-multiplier (schwab-broker-model--c 2.0 (concat schwab-broker-model--intra " ($7,000 available cash -> $14,000 stock BP); kd f-schwab-regt-buying-power-multiples") 'official)
   :bp-intraday-multiplier (schwab-broker-model--c 4.0 (concat schwab-broker-model--intra " (maintenance excess / 0.25)") 'official
                                                   "always displayed assuming a 25% requirement; not in retirement accounts")
   :bp-intraday-basis (schwab-broker-model--c 'maintenance-excess schwab-broker-model--intra 'official)
   :bp-option-basis (schwab-broker-model--c 'sma-less-reserves (concat schwab-broker-model--empirical " (screenshot: stock BP = 2 x option BP exactly)") 'inferred
                                            "no Schwab option-BP formula is published")
   :concentration (schwab-broker-model--c '(:mechanism rbc-epr-pnr :share nil)
                                          (concat schwab-broker-model--rbc "; kd f-schwab-rbc-epr-pnr") 'unpublished
                                          "EPR per security and the PNR test are published as a mechanism; the per-security numbers are not, so no concentration add-on is computed")
   :intraday (schwab-broker-model--c '(:regime unknown)
                                     "no Schwab statement captured (2026-11-10) on legacy PDT vs FINRA 4210(d)(2) intraday margin" 'unpublished
                                     "FINRA lets firms apply either during the 12-month transition")
   :option-levels (schwab-broker-model--c '((:level 3 :name "Short Uncovered"
                                             :adds (naked-call naked-put straddle-short strangle-short calendar-short)))
                                          (concat schwab-broker-model--pmapp " (Level 3: all covered/long/spread strategies plus uncovered calls, puts, straddles, strangles, ratio spreads)") 'official
                                          "levels 0-2 definitions were not captured in docs/schwab-margin; unpublished here"))
  "Schwab broker-wide rule cells (apply to every Schwab account type).")

(defconst schwab-broker-model-pm-rules
  (list
   :pm-move-equity (schwab-broker-model--c '(:up 0.15 :down 0.15 :points 10)
                                           (concat schwab-broker-model--pmund "; " schwab-broker-model--pmopt "; kd f-schwab-pm-equity-stress-15pct") 'official
                                           "a minimum; widened per security under risk-based concentration (unpublished)")
   :pm-move-narrow-index (schwab-broker-model--c '(:up 0.15 :down 0.15 :points 10) schwab-broker-model--tos 'official)
   :pm-move-broad-index-high-cap (schwab-broker-model--c '(:up 0.15 :down 0.15 :points 20)
                                                         (concat schwab-broker-model--pmund " (SPX, NDX: -15% to +15% in 20 points); kd f-schwab-pm-index-wider-than-tims") 'official
                                                         "wider than the OCC TIMS +6%/-8% floor")
   :pm-move-broad-index (schwab-broker-model--c '(:up 0.15 :down 0.15 :points 10) (concat schwab-broker-model--tos " (small- and large-cap broad indices +/-15%)") 'official)
   :pm-move-tbill-etf (schwab-broker-model--c '(:up 0.07 :down 0.07 :points 10)
                                              (concat "kd f-sgov-pm-7pct; " schwab-broker-model--empirical " (r/PMTraders 1o2fo9y, 2025-10-09)") 'community
                                              "Schwab publishes no per-ETF range; users report 7%, equal to the OCC floor")
   :pm-min-per-contract (schwab-broker-model--c 0.375 (concat schwab-broker-model--pmapp "; " schwab-broker-model--pmopt " ($37.50 per standard short option; longs lesser of that or premium)") 'official)
   :pm-vol-shocks (schwab-broker-model--c '(0.0) (concat schwab-broker-model--pmopt " (two IV methods: sticky strike and modified sticky delta; higher loss applies)") 'unpublished
                                          "shock sizes unpublished: the model applies none, so Schwab PM results are a floor")
   :pm-ineligible (schwab-broker-model--c '(:below-price 3.0 :leveraged-etf t)
                                          (concat schwab-broker-model--pmweb " (stocks under $3 held at standard margin); " schwab-broker-model--pmfact " (most leveraged ETF/ETPs ineligible)") 'official
                                          "Schwab says 'most' leveraged products; the model treats all as ineligible")
   :min-equity-pm (schwab-broker-model--c '(:open 125000.0 :maintain 100000.0)
                                          (concat schwab-broker-model--pmapp "; " schwab-broker-model--pmweb "; kd f-schwab-pm-eligibility-equity") 'official)
   :pm-house-stress (schwab-broker-model--c '(:tests (spx-beta account-wide-uniform-vol security-concentration
                                                     margin-balance-to-net-worth vega-to-net-worth theta-to-net-worth
                                                     net-short-units))
                                            (concat schwab-broker-model--pmfact "; kd f-schwab-pm-house-stress-tests") 'unpublished
                                            "tests are named, parameters are not; not computed")
   :pm-gross-leverage-cap (schwab-broker-model--c 50.0 "kd f-schwab-pm-gross-leverage-cap (3 users, 2025-06 to 2026-02)" 'community
                                                  "gross position value / NLV; not computed")
   :permitted (schwab-broker-model--c broker-model-strategy-classes (concat schwab-broker-model--pmapp " (PM requires Level 3)") 'official))
  "Schwab portfolio-margin account-type rule cells.")

(defconst schwab-broker-model-ira-rules
  (list
   :settled-only (schwab-broker-model--c t "schwab-broker-margin.el IRA helper (good-faith rule)" 'inferred
                                         "Schwab's IRA limited-margin settlement treatment was not read from a primary source")
   :spread-collateral (schwab-broker-model--c 'max-loss (concat schwab-broker-model--req " (IRA initial minimum for spreads $5,000)") 'official)
   :min-equity-spreads (schwab-broker-model--c 5000.0 (concat schwab-broker-model--req " (IRA account initial minimum requirement for spreads)") 'official)
   :permitted (schwab-broker-model--c '(long-stock long-option covered-call cash-secured-put protective-put
                                        vertical-debit vertical-credit spread iron-condor
                                        straddle-long strangle-long calendar-long)
                                      "schwab-broker-margin.el IRA helper (conservative reading); REQ allows IRA spreads" 'inferred
                                      "no naked options, no short stock; Schwab's IRA strategy list was not read from a primary source"))
  "Schwab IRA (limited margin) account-type rule cells.")

(defconst schwab-broker-model-cash-rules
  (list
   :csp-collateral (plist-get schwab-broker-model-rules :csp-collateral))
  "Schwab cash account rule cells (the rest is the Reg T cash baseline).")

;;;###autoload
(defun schwab-broker-model-register ()
  "Register Schwab and its account types with broker-model."
  (broker-model-define-broker 'schwab :name "Charles Schwab" :url "https://www.schwab.com/margin"
                              :rules schwab-broker-model-rules)
  (broker-model-define-account-type 'schwab 'cash :name "Cash" :baseline 'cash
                                    :rules schwab-broker-model-cash-rules)
  (broker-model-define-account-type 'schwab 'reg-t :name "Margin (Reg T)" :baseline 'reg-t)
  (broker-model-define-account-type 'schwab 'portfolio-margin :name "Portfolio margin"
                                    :baseline 'portfolio-margin :rules schwab-broker-model-pm-rules)
  (broker-model-define-account-type 'schwab 'ira :name "IRA (limited margin)" :baseline 'cash
                                    :rules schwab-broker-model-ira-rules)
  'schwab)

;;;###autoload
(defun schwab-broker-model-set-house-option-multiplier (symbol multiplier source confidence &optional note)
  "Register a Schwab house multiplier on SYMBOL's naked option requirement.
MULTIPLIER scales the published formula; SOURCE and CONFIDENCE (usually
`inferred' or `community') say where it comes from; NOTE is a caveat.
Applies to the reg-t and ira account types."
  (broker-model-define-symbol
   'schwab symbol :account-types '(reg-t ira)
   :rules (list :house-option-multiplier
                (broker-model-cell (float multiplier) source confidence note))))

(schwab-broker-model-register)

(provide 'schwab-broker-model)
;;; schwab-broker-model.el ends here
