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
