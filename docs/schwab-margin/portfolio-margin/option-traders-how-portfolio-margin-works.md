Source URL: https://www.schwab.com/learn/story/option-traders-how-portfolio-margin-works
Fetched: 2026-11-10

Capture note: text extracted from the HTML page (curl + pandoc); images, tooltips-as-images and video content are not captured. Tables are preserved where the page used HTML tables; some option tables render as flattened lists.

---

Margin

# Option Traders: How Portfolio Margin Works

Portfolio margin is available to qualified Schwab clients who have a margin account and meet the requirements. Learn more about what it is, how it works, and the risks involved.

December 1, 2025 • Advanced

- 
- 
- 
- 
- 

------------------------------------------------------------------------

Portfolio margin, as distinguished from traditional "Reg T" margin, is governed by FINRA Rule 4210(g). This rule permits a qualified trader greater leverage in their account because margin requirements are calculated based on their entire portfolio and leverage. This amount is determined by overall credit risk, rather than position by position on a strict equity-percentage basis as in a traditional Reg T margin account. Thus, portfolio margin seeks to determine a more in-depth and accurate picture of a trader's ability to assume credit risk. 

Some experienced traders with well-diversified portfolios who want to hedge their risk and use options as part of their overall trading strategy may choose to use portfolio margin because it can translate to more buying power in their account. That can potentially help create more opportunities to diversify or create a buffer when markets turn volatile. 

However, lower margin requirements also add more leverage and more risk. 

Here's a look at how portfolio margin works and what using it might mean to an individual option trader. 

## What is portfolio margin?

To determine portfolio margin, stock and options positions are stressed by hypothetically moving the price of the underlying asset generally between +/–15%. 

These price ranges are then divided into 10 equidistant points, and the loss or gain on the entire position is calculated at each of the 10 points. These 10 points are also called scenarios or a risk array. 

A portfolio margin calculation uses an industry-standard options-pricing model and stress-testing. Testing is done on a position's implied volatility (IV), and the margin requirement will be equal to the largest loss calculated for any given scenario. Below is an example of margin requirements in different scenarios for an underlying stock.

## How do margin loans work at Schwab?

Learn more

### Example of portfolio margin requirements

|  |  |  |  |  |  |  |
|----|----|----|----|----|----|----|
| ZYX | 138.431 | 143.3168 | 148.2026 | 177.5174 | 182.4032 | 187.289 |
| Margin req | (\$2,442.90) | (\$1,954.32) | (\$1,465.74) | \$1,465.74 | \$1,954.32 | \$2,442.90 |
| Minimum RBM | \$0.00 |   |   |   |   |   |
| PNR |   |   |   |   |   |   |
| EPR | -30% | 30% |   |   |   |   |
| P/L at EPR | (\$4,885.80) | \$4,885.80 |   |   |   |   |

Disclosures

*The **risk-based minimum (RBM)** represents the minimum requirement of \$0.375* (multiplied by the deliverable, so \$37.50 for a standard option) per short options contract held and the lesser of \$0.375 or the premium for long options contracts held. ***Point of no return (PNR)** is the percentage move in an underlying asset's price at which an account will lose 100% of its equity, meaning its net liquidation value would equal \$0. Beyond this point, the account will become unsecure. PNR does not include equity in a futures account or cross-product correlations. The **expected price range (EPR)** is Schwab*'*s estimate of the maximum expected one-day price range for a given underlying asset.* 

A trader using portfolio margin is generally allowed 6.6-to-1 leverage for stock positions. Importantly, trading with greater leverage involves greater risk of loss. Because of this, portfolio margin requirements are calculated in real time. 

Hedged positions may have lower margin requirements than unhedged positions. Hedging strategies are generally used to reduce, or hedge, risk associated with price movements in an underlying asset. For example, a long position of 100 ZYX shares at \$134 combined with a long 133-strike ZYX put is a hedging strategy that combines a long stock with a protective put, also known as a married put. 

Additionally, concentrated positions will be evaluated using a greater range in the underlying asset, and the requirements on these positions will be greater compared to non-concentrated positions. 

The table below displays an example of a hedged position, or a long stock with a protective put. 

|  |  |  |  |  |  |  |  |  |
|----|----|----|----|----|----|----|----|----|
| Married put | +1 | ZYX | 23 SEP 22... | 133 | Put | \$1,403 |   | -25%...+25% |
|   | +100 | ZYX |   |   | Stock |   |   |   |

Disclosures

This table displays an example of a hedged position using portfolio margin.

|  |  |  |  |  |  |  |
|----|----|----|----|----|----|----|
| ZYX | 113.6535 | 117.6648 | 121.6761 | 145.7439 | 149.7552 | 153.7665 |
| Sticky strike | \$583.50 | (\$536.78) | (\$462.00) | \$832.97 | \$1,172.39 | \$1,532.01 |
| Sticky delta | (\$567.73) | (\$524.86) | (\$455.03) | \$838.71 | \$1,179.25 | \$1,539.05 |
| Minimum RBM | \$37.50 |   |   |   |   |   |
| PNR |   |   |   |   |   |   |
| EPR | -25% | 25% |   |   |   |   |
| P/L at EPR | (\$612.26) | \$2,812.67 |   |   |   |   |

Disclosures

## How does portfolio margin account for IV and concentration?

Implied volatility, or IV, is usually incorporated into the risk array used in portfolio margin calculations. Schwab uses two methods to dynamically incorporate IV into the risk array: 

- **Sticky strike (constant IV)**: Each options strike uses a constant IV in the options-pricing model to calculate theoretical options prices at each evaluation point of the risk array. This means IV does not change over each price slice. \

- **Sticky delta (IV with slope)**: IV is based on the in-the-money (ITM)/out-of-the-money (OTM) amount of the options with respect to evaluation points. A slope and adjusted volatility is assigned to each price point. However, IV for the current price is not an adjusted sticky delta or sticky strike method. Of the two methods used, the risk array yielding the highest theoretical loss is applied for the margin requirements. 

The table below illustrates both methods. 

|  |  |  |  |  |  |  |
|----|----|----|----|----|----|----|
| ZYX | 137.8615 | 142.7272 | 147.5929 | 176.7871 | 181.6528 | 186.5185 |
| Volatility | 45.98% | 45.98% | 45.98% | 45.98% | 45.98% | 45.98% |
| Sticky strike | (\$1,373.26) | (\$1,009.88) | (\$689.12) | \$339.23 | \$399.15 | \$441.56 |
| Volatility | 49.88% | 48.37% | 47.29% | 45.23% | 45.20% | 45.19% |
| Sticky delta | \$1,425.20 | \$1,049.80 | (\$716.08) | \$342.75 | \$401.34 | \$442.19 |
| Minimum RBM | \$37.50 |   |   |   |   |   |

*For illustrative purposes only. Past performance does not guarantee future results.*

Concentration is part of the calculation as well. Schwab uses proprietary logic to make this calculation. The two main terms used in this calculation include the expected price range (EPR) and the point of no return (PNR). 

If the PNR is outside of the EPR, then the risk array will generally default to either the house minimum or the regulatory minimum (using TIMS, the Options Clearing Corporation's Theoretical Inter-Market Margin System), whichever is greater. 

Now, if the opposite occurs, that is, when the PNR is inside the EPR range, then a risk concentration exists, and action is taken in real time to increase the portfolio margin requirement. When concentration exists, the margin requirement will be set to the largest loss inside the EPR. For example, if upside PNR is 30% and upside EPR is 40%, then the margin requirement will use the largest loss inside the 40% EPR to calculate the risk array, even if the Schwab/House minimum may be 15%. 

The thinkorswim® platform includes PNR and EPR in the **Explain Margin** pop-up window for both portfolio margin and Reg T accounts. The risk arrays used for portfolio margin requirements may also be raised due to low liquidity and market events. The table below displays the PNR and EPR used in a portfolio margin calculation. 

|  |  |  |  |  |  |  |
|----|----|----|----|----|----|----|
| ZYX | 138.431 | 143.3168 | 148.2026 | 177.5174 | 182.4032 | 187.289 |
| Margin req | (\$2,442.90) | (\$1,954.32) | (\$1,465.74) | \$1,465.74 | \$1,954.32 | \$2,442.90 |
| Minimum RBM | \$0 |   |   |   |   |   |
| PNR |   |   |   |   |   |   |
| EPR | -30% | 30% |   |   |   |   |
| P/L at EPR | (\$4,885.80) | \$4,885.80 |   |   |   |   |

Disclosures

## How to analyze portfolio margin requirements 

On thinkorswim, traders can see general portfolio margin requirements, analyze current positions or simulated trades, and see real-time portfolio margin requirements. 

The thinkorswim platform offers access to historical daily securities prices. To access these prices, after logging in to thinkorswim, head to the **Analyze** tab and turn on the **thinkBack** function, which allows traders to view historical pricing, IV, and the greeks. It's also possible to analyze simulated or existing trades and positions using standard industry options-pricing models. In addition, traders can change components, including the underlying asset price, increased/decreased volatility, time to expiration, interest rate, and dividend yield to calculate the theoretical price of the options and estimate portfolio margin requirements. 

## How do traders qualify for portfolio margin?

Portfolio margin is available to qualified Schwab clients who currently have a margin account and meet the requirements outlined below:

- \$125,000 in current equity
- Full options trading approval
- Must achieve a score of 80%, or better, on an options trading test
- If approved, the account's total net liquidated value must remain above \$100,000

Approved clients also receive 24/7 account support and free access to trading specialists for help with executing their strategies.

*Portfolio margining involves a great deal more risk than cash accounts and is not suitable for all investors. Minimum qualification requirements apply. Portfolio margining is not available in all account types.*

*Use of portfolio margin involves unique and significant risks, including increased leverage, which increases the amount of potential loss. There are also shortened, stricter time frames for meeting deficiencies, which increase the risk of involuntary liquidation. Client, account, and position eligibility requirements exist, and approval is not guaranteed.*

*Carefully read* [*The Charles Schwab & Co., Inc. Guide to Margin*](https://www.schwab.com/resource/charles-schwab-guide-to-margin) *for more details. For specific questions, please contact us at 877-752-9749.*

## How do margin loans work at Schwab?

Learn more

## More from Charles Schwab

### Intraday Margin Buying Power

Article \| Nov 2, 2026

### What Is Day Trading?

Article \| Oct 29, 2026

### Three Ways to Use Margin

Video \| Aug 27, 2026

## Explore more topics

Options carry a high level of risk and are not suitable for all investors. Certain requirements must be met to trade options through Schwab. Please read the Options Disclosure Document titled "Characteristics and Risks of Standardized Options" before considering any option transaction. Supporting documentation for any claims or statistical information is available upon request.

When considering a margin loan, you should determine how the use of margin fits your own investment philosophy. Because of the risks involved, it is important that you fully understand the rules and requirements involved in trading securities on margin.

Margin trading increases your level of market risk. Your downside is not limited to the collateral value in your margin account.

Schwab may initiate the sale of any securities in your account, without contacting you, to meet a margin call.

Schwab may increase its "house" maintenance margin requirements at any time and is not required to provide you with advance written notice.

You are not entitled to an extension of time on a margin call.

Hedging and protective strategies generally involve additional costs and do not assure a profit or guarantee against loss.

With long options, investors may lose 100% of funds invested.

This material is intended for general informational and educational purposes only. This should not be considered an individualized recommendation or personalized investment advice. The securities, investment products and investment strategies mentioned may not be suitable for everyone. Each investor needs to review an investment strategy for his or her own particular situation before making any investment decisions.

All expressions of opinion are subject to change without notice in reaction to shifting market, economic or political conditions. Data contained herein from third party providers is obtained from what are considered reliable sources. However, its accuracy, completeness or reliability cannot be guaranteed.

For illustrative purpose(s) only. Individual situations will vary. Not intended to be reflective of results you can expect to achieve.

Investing involves risk, including loss of principal, and for some products and strategies, loss of more than your initial investment.

Backtesting results presented are hypothetical, they did not actually occur and there is no guarantee that the same strategy implemented today would produce similar results.

Past performance is no guarantee of future results.

​Use of portfolio margin involves unique and significant risks, including increased leverage, which increases the amount of potential loss, and shortened and stricter time frames for meeting deficiencies, which increase the risk of involuntary liquidation. Client, account, and position eligibility requirements exist, and approval is not guaranteed. Carefully read the Charles Schwab & Co. Guide to Margin and the Charles Schwab & Co.  Margin Overview and Disclosure Statement for specific disclosures and more details. Charles Schwab & Co. Guide to Margin: https://www.schwab.com/resource/charles-schwab-guide-to-margin

Charles Schwab & Co.  Margin Overview and Disclosure Statement: https://www.schwab.wallst.com/pdf/activetrader/marginriskdisclosure.pdf

It is the client’s obligation to evaluate the risks of portfolio margin when making investment decisions. Charles Schwab & Co. (Schwab) reserves the right at its sole discretion to decline a client the use of portfolio margin.  In the event Schwab decides to terminate a client’s use of portfolio margin, the client’s account may be converted to the standard margin account.  The conversion of a portfolio margin account to a margin account may require the liquidation of positions.

1125-A4X9
