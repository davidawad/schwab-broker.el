Captured 2026-11-10 via BrowserOS neo (rendered page text). Source: https://toslc.thinkorswim.com/center/howToTos/thinkManual/Miscellaneous/RBC-Margin

Real-Time Data (RTD) Function for thinkorswim®
Binary Options
Server-Side and Device-Stored Settings
Risk-Based Concentration (RBC) Margin System: How It Works

Risk-based concentration (RBC) margin is a margin system applied to all margin-approved retail accounts. RBC margin is a model that compares the theoretical loss of a position in your account to your account’s net liquidation value.  If the position loss creates a negative net liquidation value in your account, this creates “exposure” in the account. Position/s with “exposure” will be subject to higher maintenance requirements as described below.

We maintain an Expected Price Range (EPR) for each security for which you can trade. This EPR is a theoretical estimate in which the security could potentially move up or down a given amount in a single day. The EPR is not a predictor of price movement.  Rather, it is a calculation of how much the security’s price could realistically move in a day in response to external factors such as news or a general market shock.  This calculation is based on criteria such as the security’s volatility, historical data, liquidity, among others.

Similarly, a Point of No Return (PNR) is calculated for each underlying security in your account. This represents the percentage move the security would have to make, based on your direction of risk, before you would lose your entire account value. Beyond this point, the account could become unsecured. An example of these EPR and PNR values is shown in figure 1. Simply put, this percentage represents how much of a price movement your security can support before your account value goes to zero.

FIGURE 1: EXAMPLE OF RBC MARGIN RISK METRICS. This table displays the position’s maintenance requirements and shows the account’s PNR versus the stock’s EPR. In this example, the account can handle a 55.32% move on XYZ and the theoretical expected price range is 50%. Source: thinkorswim. For illustrative purposes only. Past performance does not guarantee future results.

RBC margin compares these two figures. If the PNR of a position is outside of the EPR range we have for the security, you would be held at the house maintenance requirement which may still be higher than the minimum 30%, depending on special margin requirements. However, if your position's PNR falls within this range, then that position has “exposure” and your account can no longer support a full EPR move. An example representing exposure can be seen in figure 2.  Another way to view this:  if your account (PNR) is inside the expected potential price movement (EPR), your account is in danger of having a negative value, which we call the risk exposure amount.

FIGURE 2: EXAMPLE OF RBC MARGIN EXPOSURE. Note how the PNR is now in red, this indicates this position has exposure. In this example, XYZ has the base requirement of 40%, but the exposure would cause the requirement to become 50%. Source: thinkorswim. For illustrative purposes only. Past performance does not guarantee future results.

This exposure causes the maintenance requirement to be held at the EPR percentage in the direction of risk, which is often higher than the base requirement. In turn, this new requirement can sometimes lead to a significant change to your available funds which can create a margin call. This margin call is due immediately.

Please note: depending on the exposure of the position, we may require or take immediate action at any time to reduce the risk.

There are ways to track this exposure on the thinkorswim platform when trading. Under Monitor > Activity & Positions you can click on the numerical value on the far right of your underlying position either labeled BP Effect or Margin Req. This will show you the upside and downside EPR for the security, as well as where your PNR lies. If the number is in red, this means that your PNR would be achieved prior to the EPR and that you are carrying too much exposure in that position.

Margin involves a great deal more risk than cash accounts and is not suitable for all investors. Minimum qualification requirements apply. This is not an all-inclusive metric to the risk in any account.  We evaluate numerous other house risk metrics and rules that may require you to reduce a position(s) for other reasons.

Use of RBC margin involves unique and significant risks, including increased leverage, which increases the amount of potential loss, and shortened and stricter time frames for meeting deficiencies, which increase the risk of involuntary liquidation.

When considering a margin loan, you should determine how the use of margin fits your own investment philosophy. Because of the risks involved, it is important that you fully understand the rules and requirements involved in trading securities on margin. Margin trading increases your level of market risk. Your downside is not limited to the collateral value in your margin account. Schwab may initiate the sale of any securities in your account, without contacting you, to meet a margin call. Schwab may increase its "house" maintenance margin requirements at any time and is not required to provide you with advance written notice. You are not entitled to an extension of time on a margin call.

Portfolio Margin
