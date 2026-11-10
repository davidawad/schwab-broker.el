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

Phase 2 (investing-er3.15): spreads, condors, strangles, margin-call
trigger price, IRA variant, explain-a-snapshot.
