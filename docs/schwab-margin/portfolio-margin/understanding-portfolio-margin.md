Source URL: https://www.schwab.com/learn/story/understanding-portfolio-margin
Fetched: 2026-11-10

Capture note: text extracted from the HTML page (curl + pandoc); images, tooltips-as-images and video content are not captured. Tables are preserved where the page used HTML tables; some option tables render as flattened lists.

---

Margin

# Understanding Portfolio Margin

Qualified traders have access to portfolio margin, which can offer a way to increase a trader's available budget.

December 20, 2024 • Advanced

- 
- 
- 
- 
- 

------------------------------------------------------------------------

Portfolio margin was introduced as a way for retail traders to access leverage similar to their professional counterparts. Portfolio margin offers a way to calculate a trader's margin requirements based on the overall risk of their portfolio and the trade.

## What is portfolio margin?

Portfolio margin can be applied in real time to approved Schwab accounts that have an initial minimum equity that exceeds \$125,000. Portfolio margin (PM) uses an options pricing model to calculate the margin requirements of different strategies in an individual security—such as long stock, short puts, straddles, and others—as one aggregate position.

Traditional margin rules follow the Federal Reserve Board's Regulation T1 (Reg T) when determining the margin requirements for positions in margin accounts. The Financial Industry Regulatory Authority (FINRA) also applies strategy-based rules for margin and cash accounts, meaning each strategy has specific requirements. For example, the minimum to buy stock in a margin account is generally 50% of the value of the stock shares. To buy 100 shares of a \$50 stock, for example, the Reg T margin requirement would usually be \$2,500.

When calculating PM, the margin on the long stock is based on what its largest theoretical loss would be if the stock rose or dropped 15%.2  That 15% is generally the minimum percent change for equities but can be adjusted to a larger percent change if the risk of the stock or position warrants it. 

For example, a long stock position would have its largest theoretical loss over that plus or minus 15% range if the price dropped 15%. For the same long 100 shares of a \$50 stock, a 15% drop would cause a \$750 loss (.15 x \$5,000). So, the PM requirement would be \$750. 

Portfolio margins are determined by a "stress test," where the theoretical profit or loss (P&L)3 is calculated if and when the price of a stock or index drops or rises, and volatility drops and rises, by percentages determined by PM rules. The PM requirement is the largest theoretical loss across those various "stress test" scenarios on a risk array of price movement and percentages. In some cases, the PM real time can be much lower than the Reg T margin.

For example, the margin requirement for a vertical spread strategy in stock XYZ is \$A, a short strangle is \$B, and a long stock and covered call are \$C. Under normal margin rules the total margin would be (\$A + \$B + \$C). But under PM, all these positions would be assessed together in its test. If some of the positions in XYZ have a theoretical profit when XYZ is down, they can offset theoretical losses on other positions in XYZ, and the PM requirement, as a result, can be lower.

A lower margin requirement for a position allows a trader to add more, or larger, positions in their account. When using margin, though, the trader should understand that losses can potentially be bigger due to additional leverage. In addition, risk models used for portfolio margin may not account for all potential portfolio risks.

## How do margin loans work at Schwab?

Learn more

## Examples of portfolio margin

To calculate PM, an options pricing model focuses on the following inputs:

- Underlying price
- Strike price
- Time to expiration
- Volatility
- Risk-free interest rate
- Dividend yield

For equities, the PM calculation theoretically moves the price of the stock up and down 15% and divides that range into 10 equidistant points. For broad-based equity indexes like the S&P 500® index (SPX) and the Nasdaq-100® (NDX), the assessment range is down 15% to up 15%, and the range is divided into 20 equidistant points to capture more price moves on the risk array. Then, for each price point in that range of scenarios, PM calculates the position's theoretical value, and determines the position's P&L at those theoretical values. The largest theoretical loss across these scenarios is the PM requirement.  

Below are some example strategies and how they work with portfolio margin.

### Short put

For example, a trader could sell short a naked 120 put for \$0.80 credit on XYZ stock trading at \$125. The Reg T margin would be nearly \$2,000. The portfolio margin, on the other hand, would be approximately \$1,350. If the price of the shares went down 15%, from \$125 to \$106.25, the put would have its largest theoretical loss of \$1,350, and that's the PM requirement.

*Margin recap on short put:*

Reg T = \$2,000

PM = \$1,350

### Covered call

Next, let's look how portfolio margin might be calculated for a covered call with long stock and a short out-of-the-money call.4 A trader might buy 100 shares of a stock at \$41.35 and short a 44 call at \$0.35. In a margin account, the Reg T requirement would be 50% of the value of the stock—100 shares at \$41.35 multiplied by 50%—minus the credit for selling the call. That's \$2,067.50 – \$35 = \$2,032.50. In a PM account, the loss when the stock is down 15% would be about \$590. Therefore, that would be the margin required to do that covered call.

*Margin recap on covered call:*

Reg T = \$2,032.50

PM = \$590

## How to calculate PM with thinkorswim

The PM requirement for stock and equity positions, as well as options on broad-based indexes like the NDX and SPX, is based on a plus or minus 15% stress test. 

Additionally, if an account has most of its risk concentrated in a single stock, a larger percentage range is used to determine the PM requirement. (Schwab reserves the ability to hold higher margin requirements based on internal risk metrics.)

The thinkorswim® trading platform can calculate what the PM requirement might be for a position. The **Analyze** tab on thinkorswim lets traders review the daily loss of a position across the range of PM percent changes below or above in the underlying stock or index. That gives traders a real-time estimate of what the PM requirement might be.

For example, a trader might consider a short a put on the SPX in a PM account. They can use the **Analyze** tab to simulate a short SPX put by setting the price slices on the **Risk Profile **to see the range for the SPX price on the **Risk Profile**.

Source: thinkorswim platform

*For illustrative purposes only.*

Moving the cursor between the –15% or +15% range helps the trader find the largest loss possible for that day. Using a PM calculation could reduce the margin requirement of those short SPX puts because of the way the algorithm computes a maximum theoretical loss. PM thus can give traders more flexibility in strategy in addition to lower requirements.

## How to qualify for portfolio margin

To be eligible for PM with Schwab, a qualified trader must have an account with a net liquidation value of at least \$125,000. It's possible to apply for PM for an existing margin account. Additionally, an account must be approved for Level 3 options trading (all options strategies including uncovered options selling5). Finally, a trader must take an online test. The test consists of 20 questions that explore risk and options strategies that allow Schwab to determine whether a trader is sufficiently knowledgeable to handle a higher degree of risk.

## Important PM reminders

- To be eligible for portfolio margin, clients must be approved for writing uncovered options. 
- A margin deficiency in the PM account or sub-account, regardless of whether due to new commitments or the effect of adverse market movements on existing positions, must be met within two business days or may be due immediately because of market volatility. 
- Any shortfall in aggregate equity across accounts, when required, must be met within two business days. 
- Portfolio margin generally permits greater leverage in an account, which can create greater losses in the event of adverse market movements. 
- Because the maximum time limit for meeting a margin deficiency is shorter than in a standard margin account, there is increased risk that a client's portfolio margin account will be liquidated involuntarily, possibly causing losses to the client.

*The information presented is for informational and educational purposes only. Content presented is not an investment recommendation or advice and should not be relied upon in making the decision to buy or sell a security or pursue a particular investment strategy.* 

When considering a margin loan, you should determine how the use of margin fits your own investment philosophy. Because of the risks involved, it's important you fully understand the rules and requirements involved in trading securities on margin:  

- Margin trading increases your level of market risk.  
- Your downside is not limited to the collateral value in your margin account.  
- Schwab may initiate the sale of any securities in your account, without contacting you, to meet a margin call.  
- Schwab may increase its "house" maintenance margin requirements at any time and is not required to provide you with advance written notice.  
- You are not entitled to an extension of time on a margin call.

1Formally known as Regulation T, it's the initial margin requirement set by the Federal Reserve Board. According to Reg T requirements, you may borrow up to 50% of marginable securities that can be purchased (such as most listed stocks).

2Percentages and eligibility are subject to change.

3Profit and loss of the aggregate total of all gains and losses over a specific period of time (e.g., day, month, year). Often confused with ROI, which is just the return on investment of a single trade or position.

4Describes an option with no intrinsic value. A call option is out of the money (OTM) if its strike price is above the price of the underlying stock. A put option is OTM if its strike price is below the price of the underlying stock.

5A short call position is not considered covered if the writer does not have a long stock or long call position. A short put position is not considered covered if the writer is not short stock or long another put.

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

Spread trading must be done in a margin account.

Multiple leg options strategies will involve multiple transaction costs.

Uncovered options strategies are only appropriate for traders with the highest risk tolerance, may involve potential for unlimited risk, and are only allowed in margin accounts.

Commissions, taxes and transaction costs are not included in this discussion, but can affect final outcome and should be considered. Please contact a tax advisor for the tax implications involved in these strategies.

The information provided here is for general informational purposes only and should not be considered an individualized recommendation or personalized investment advice. The investment strategies mentioned here may not be suitable for everyone. Each investor needs to review an investment strategy for his or her own particular situation before making any investment decision. 

All expressions of opinion are subject to change without notice in reaction to shifting market conditions. Data contained herein from third-party providers is obtained from what are considered reliable sources. However, its accuracy, completeness, or reliability cannot be guaranteed. 

Examples provided are for illustrative purposes only and not intended to be reflective of results you can expect to achieve.

1224-BBRS
