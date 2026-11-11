# Schwab Reg T margin helpers

`schwab-broker-margin.el` is pure and read-only. This file lists the rules
each helper implements and where each rule is published. (Sections are
filled in as helpers land; see the end for the screenshot reconciliation.)

## Naked short equity options

Schwab publishes (Margin requirements page, "Options - Short"): greater of
20% underlying value - out-of-the-money amount + premium; 10% of contract
value (puts) or underlying value (calls) + premium; $100 per contract.
Maintenance = greater of minimum equity requirement or initial requirement.
The same structure is CBOE's strategy-based rule (100% of proceeds + 20% of
underlying - OTM, minimum proceeds + 10%).

CBOE's published examples are NET of the credit (the proceeds term is paid
by the credit received). Check: short 100 AAPL Mar 130 puts @ 8.94, AAPL
127.83: 0.20 x 12,783 x 100 = $255,660 (CBOE: $255,660). Short 100 calls
@ 6.65: (2,556.6 - 217) x 100 = $233,960 (CBOE: $233,960). The helpers
return `:gross` (with premium, as Schwab's table words it) and `:net`.

Sources:
- https://www.schwab.com/margin/requirements
- https://www.cboe.com/us/options/strategy_based_margin
- CBOE Margin Requirement Examples:
  https://cdn.cboe.com/resources/membership/Margin_Requirement_Examples.pdf

## Other position types

- Cash-secured put (Schwab CSEP): no margin requirement; the assignment
  value (strike x 100 - credit) must be held in cash or cash equivalents
  (cash, money funds, Schwab Bank deposits, Treasuries under 1 year).
  Source: Schwab margin requirements page, CSEP row. Whether an ETF such as
  SGOV counts is not stated; the helpers do not assume it does.
- Covered call: the option adds 0; the stock is margined normally. CBOE
  check: long 10,000 AAPL @127.83 + short 100 Mar 130C @6.65 = 50% x
  1,278,300 - 66,500 credit = $572,650 (CBOE: $572,650).
- Long option: Schwab publishes 100% of cost, maintenance same as initial.
  FINRA 4210(f)(2)(B)/(f)(1): a listed option with more than nine months to
  expiry may be margined at 75% of market value. NOTE: that is a 75%
  REQUIREMENT, i.e. a 25% loan value, not a 75% loan value as the bead
  wording says. `:leaps-margin-pct` defaults to Schwab's 1.0; pass 0.75 for
  the FINRA minimum. Whether Schwab grants it is not published.
  Source: https://www.finra.org/rules-guidance/rulebooks/finra-rules/4210
- Long stock / non-leveraged ETF: Reg T initial 50% of cost; Schwab
  maintenance 25% (house names higher, "in most instances 50%"); under
  $3.00/share 100%. Source: Schwab margin requirements page.
- Short stock: initial 50% of net proceeds; maintenance 30% above $16.66,
  $5/share from $5.00 to $16.66, 100% from $2.50 to $4.99, $2.50/share
  below. Source: same page.

## Account level

- equity = cash + long market value - short market value (option marks
  count as liabilities).
- maintenance excess = equity - maintenance requirement.
- SMA (approximation) = max(0, equity - initial requirement).
- Option buying power = SMA less cash reserved for CSPs. Stock buying
  power = 2 x option buying power (Schwab example: $7,000 available cash,
  $14,000 stock BP).
- Intraday buying power = 4 x maintenance excess (Schwab divides by 0.25
  and always assumes a 25% requirement).
  Source: https://www.schwab.com/learn/story/understanding-intraday-margin-buying-power
- Reg T delegates option margin to exchange rules: 12 CFR 220.12(f).

## Screenshot reconciliation (2026-11-09 ~15:10 CT)

Observed: Account Value 51,273.22; Option BP 23,072.99; Stock BP 46,145.98;
Intraday BP 141,966.20. Holdings: SGOV 491 sh @ ~100.50 (49,345.50),
short 1 NVDA 11/13 165P @1.04, NVDA ~178.9. Cash was not observed: derived
from Account Value as 2,031.72 (51,273.22 - 49,345.50 + 104). That derived
cash makes Account Value match by construction; the check is not
independent.

| Quantity | Formula | Computed | Observed | Residual |
|---|---|---|---|---|
| Put requirement | 20% x 17,890 - 1,390 OTM + 104 (10% leg is 1,754) | 2,292.00 | | |
| SGOV maintenance | 25% x 49,345.50 | 12,336.38 | | |
| SGOV initial | 50% x 49,345.50 | 24,672.75 | | |
| Maintenance excess | 51,273.22 - 14,628.38 | 36,644.85 | 35,491.55 (= 141,966.20 / 4) | -1,153.30 |
| Intraday BP | 4 x maintenance excess | 146,579.38 | 141,966.20 | -4,613.18 |
| Option BP | equity - (24,672.75 + 2,292) | 24,308.47 | 23,072.99 | -1,235.48 |
| Stock BP | 2 x Option BP | 48,616.94 | 46,145.98 | -2,470.96 |

What reproduces exactly: Stock BP = 2 x Option BP (46,145.98 = 2 x
23,072.99), and the intraday figure is a clean 4 x maintenance excess
(141,966.20 / 4 = 35,491.55). What does not close: Schwab's requirement
is about 1,153 higher on the maintenance side and 1,235 higher on the
initial side than published rules give. The two gaps differ by 82.19.

Candidate explanations, none confirmable from public sources:
1. A Schwab house surcharge on the NVDA short put. Needed extra: about
   1,153 (maintenance) and 1,235 (initial). 25% instead of 20% would add
   only 894.50; 30% would add 1,789.
2. SGOV valued at about 101.17 instead of 100.50 (solving the two linear
   equations with a common put requirement gives S = 49,674 and put
   requirement 3,363). Implausible for SGOV.
3. A different NVDA or put mark used by Schwab at the moment of the screen.

`schwab-broker-margin-account` takes `:house-extra-initial` and
`:house-extra-maintenance`; the fitted values 1,235.48 and 1,153.295
reproduce every observed number (test
`schwab-broker-margin-screenshot-fitted-house-extra`). They are fitted,
not published. The test `...-published-rules` pins the residuals so a rule
change shows up.

## Spreads, combinations and calendars (phase 2)

All vectors below come from the CBOE Margin Requirement Examples PDF (AAPL
close 127.83 on 2021-01-19, 100 contracts, the strategy-based column, NET of
credit) and are tests in `test/schwab-broker-margin-test.el`.

- Vertical spread (`schwab-broker-margin-vertical`). Debit spread: the debit
  is paid in full, requirement = max loss. CBOE: long 100 Mar 125C @9.05 /
  short 100 Mar 135C @4.75 = $43,000. Credit spread: requirement = strike
  width x 100 x qty; `:net` = width - credit is the true max loss. The credit
  spread rule is the standard differential rule (CBOE Margin Manual, spread
  differential; FINRA 4210(f)(8)(B)); the CBOE examples PDF has no credit
  vertical, so those tests are arithmetic, not CBOE vectors.
- Straddle / strangle (`-straddle`, `-strangle`). Short: greater of the two
  naked-option requirements (each with its own premium) plus the other side's
  premium; `:net` subtracts both credits. CBOE: short 100 Mar 130 straddle
  @8.94/6.65 = $255,660 (gross 411,560); short 100 Mar 125P/135C strangle
  @6.33/4.75 = $227,360. Long: both premiums paid in full: $155,900 and
  $110,800.
- Short iron condor (`-iron-condor`). One side can finish in the money, so
  the requirement is the wider spread's width x 100 x qty; `:net` subtracts
  both credits. CBOE: 120/125/130/135 @4.30/6.33/6.65/4.75 = $10,700;
  115/125/130/140 = $32,300. This is the CBOE number (width less total
  credit), not "greater side plus the other side's premium", which would
  give 29,700 for the first example; the straddle/strangle rule above is the
  one with that wording.
- Ratio spread (`-ratio-spread`). Matched pairs use the vertical rule, each
  extra short is margined as a naked option, each extra long is paid in
  full. Composition of the rules above; the CBOE examples PDF has no ratio
  spread, so the vectors are arithmetic.
- Calendar / diagonal (`-calendar`). Long leg expiring later: net debit paid
  in full. CBOE long calendar Jun/Mar 130C @11.15/6.65 = $45,000. Short
  calendar (short leg expires later): short leg naked, long paid in full;
  CBOE Jun short 130C @11.15 / Mar long @6.65 = $300,460 (= short gross
  345,460 - 45,000 net credit). Diagonal strike differential (long call
  strike above the short, or long put below) is added to the debit: this
  follows the usual covered-by-longer-dated-option rule but is NOT
  confirmed by a primary-source example.

## Margin-call trigger price

`schwab-broker-margin-call-price` takes a function from underlying price to
the whole position list (the rest of the book rides along), walks from the
current price toward a bound, and bisects the first cell where maintenance
excess goes negative. It uses the same maintenance math as
`schwab-broker-margin-account`, so it inherits every house-rule caveat.

## IRA / limited margin

`schwab-broker-margin-ira`: no naked options, no short stock, no SMA, no
margin loan; everything is paid for or cash-secured with settled cash;
unsettled cash is reported but never counted (good-faith rule, FINRA 4210
and Reg T 12 CFR 220.8 settlement). Credit spreads are treated as needing
their full width in cash. Schwab's page on which strategies an IRA may trade
and its exact collateral per strategy was not read from a primary source
here; the allowed set is a conservative reading.

## Explaining a snapshot

`schwab-broker-margin-explain` takes a trader-API `securitiesAccount`
(positions + currentBalances), rebuilds helper plists (OCC symbols parsed;
equal-quantity same-expiry long/short pairs become verticals, share-covered
short calls become covered calls), runs `schwab-broker-margin-account`, and
returns residuals against every numeric balance Schwab reports. The balance
field names (`equity`, `cashBalance`, `maintenanceRequirement`, `sma`,
`optionBuyingPower`, `stockBuyingPower`, `dayTradingBuyingPower`) follow the
Schwab Trader API schema as best known; they were not verified against a
live response in this change and absent fields are skipped. Residuals are
reported, never absorbed.

## Primary sources for phase 2

- CBOE Margin Manual: https://cdn.cboe.com/resources/membership/Margin_Manual.pdf
- CBOE Margin Requirement Examples (the vectors above), fetched 2026-11-10:
  https://cdn.cboe.com/resources/membership/Margin_Requirement_Examples.pdf
- FINRA Rule 4210: https://www.finra.org/rules-guidance/rulebooks/finra-rules/4210
- 12 CFR 220.12 and 220.8 (eCFR, links above)

## Source files

Local snapshots (fetched 2026-11-09) live in the deal research folder
`options-spreads/deals/2026-11-nvda-csp/research/sources/`; not copied here.
- https://www.schwab.com/margin/requirements
- https://www.schwab.com/legal/margin-disclosure-statement
- https://www.schwab.com/learn/story/understanding-intraday-margin-buying-power
- https://www.schwab.com/learn/story/managing-cash-secured-equity-puts
- https://www.ecfr.gov/current/title-12/chapter-II/subchapter-A/part-220/subpart-B/section-220.12
- https://www.cboe.com/us/options/strategy_based_margin
- https://cdn.cboe.com/resources/membership/Margin_Manual.pdf
- https://cdn.cboe.com/resources/membership/Margin_Requirement_Examples.pdf
- https://www.finra.org/rules-guidance/rulebooks/finra-rules/4210

## broker-model registration (schwab-broker-model.el)

The rules above are also registered, as data, with the sibling package
`../broker-model.el` (see its README and `docs/rules-matrix.md`). Each
Schwab cell names its document (short names from
`docs/schwab-margin/index.md`) or kd fact id and a confidence:

| account type | baseline | Schwab overrides (confidence) |
|---|---|---|
| `reg-t` | Reg T + FINRA 4210 + Cboe | REQ tables: long >= $3 50/25, < $3 100%; short tiers; 2X/3X ETFs; money funds 10/10; T-bills 10/1; naked 20%/10% (broad index 15%), $100/contract floor, leverage-scaled; long options 100% (no LEAPS carve-out); spreads, straddles, protective puts, collars; $2,000 margin and $5,000 naked minimum equity; BP 2x / 4x maintenance excess (all official). Option BP = SMA - reserves (inferred). CSP premium netted (inferred). House surcharges and RBC concentration (unpublished). PDT vs intraday-margin regime (unpublished). |
| `portfolio-margin` | FINRA 4210(g) + OCC TIMS | equities and narrow indexes +/-15% 10 points; SPX/NDX +/-15% 20 points (wider than TIMS +6/-8); $0.375 x multiplier; stocks < $3 and leveraged ETFs margined Reg T; $125,000 / $100,000 equity (official). T-bill ETFs 7% (community). IV shocks and house stress tests (unpublished: results are floors). |
| `ira` | Reg T cash | no naked or short; spreads hold max loss in cash, $5,000 spread minimum (official); settled cash only and the strategy list (inferred, as `schwab-broker-margin-ira`). |
| `cash` | Reg T cash | CSEP collateral list (official). |

`test/schwab-broker-model-test.el` checks the registration against this
package's helpers on the same inputs (parity), reproduces the screenshot
residuals, and shows that an INFERRED 1.5x house multiplier on NVDA
options (`schwab-broker-model-set-house-option-multiplier`, kd
f-schwab-nvda-165p-gap-inferred) leaves the 7.29 maintenance residual
from `docs/schwab-margin/empirical.md`. The multiplier is not registered
by default.
