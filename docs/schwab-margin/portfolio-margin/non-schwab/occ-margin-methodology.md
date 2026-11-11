Captured 2026-11-10 via BrowserOS neo. Source: https://www.theocc.com/risk-management/margin-methodology

Risk exposure is a focal point of vital importance for all international markets and clearing organizations. As world financial derivatives markets expand and counterparty credit risk increases in size and complexity, an organization's ability to assess its exposure to credit risk has become even more critical. OCC's System for Theoretical Analysis and Numerical Simulations ("STANS®") provides a sophisticated risk assessment capability.

OCC is the first derivatives clearinghouse in the world to use a large-scale Monte Carlo-based risk management methodology. The STANS methodology is used to measure the exposure of portfolios of options, futures and cash instruments cleared and carried by OCC on behalf of its clearing member firms ("CMs"). STANS allows clearing institutions to measure, monitor and manage the level of risk exposure of their members' portfolios.

1. Introduction

This page offers an overview of OCC's margin methodology. Section 2 describes the general features of the methodology. Section 3 adds an explanation of the basis upon which CMs can make intraday withdrawals of excess margin or substitute one collateral asset for another.

2. General Features

OCC applies margin requirements on a daily basis to each account maintained at OCC by its CMs. Intraday calls for additional margin may be made on accounts incurring significant losses.

Under the STANS methodology, which went into effect in August 2006, the daily margin calculation for each account is based on full portfolio1 Monte Carlo simulations and - as set out in more detail below - is constructed conservatively to ensure a very high level of assurance that the overall value of cleared products in the account, plus collateral posted to meet margin requirements, will not be appreciably negative at a two-day horizon.

Until February 2010, securities posted as collateral were not included in the Monte Carlo simulations, but were subjected to traditional "haircuts." Since then, the "collateral in margins" scheme has taken effect, whereby some collateral securities - specifically equity securities - have instead been included in the Monte Carlo simulations. Thus, the margin calculations now reflect the scope for price movements in these forms of collateral to exacerbate or mitigate losses on the cleared products on the account.

The Monte Carlo simulations are based on econometric models of the joint behavior of the risk factors affecting values of CM accounts at OCC. The majority of risk factors pertain to the prices and option-implied volatilities of individual equity securities. The modeling of each risk factor allows for volatility clustering and fat-tailed innovations. The joint behavior is addressed by combining the marginal behaviors of individual risk factors by means of a copula function that takes account of correlations and allows for tail-dependence.

The Monte Carlo simulations use, for the volatility of each risk factor, the greater of the short-term level predicted by the model and an estimate of its longer-run level.

The base component of the margin requirement for each account is obtained from the risk measure known as 99% Expected Shortfall. That is to say, the account has a base margin excess (deficit) if its positions in cleared products, plus all existing collateral - whether of types included in the Monte Carlo simulation or of types subjected to traditional "haircuts" - would have a positive (negative) net worth after incurring a loss equal to the average of all losses beyond the 99% VaR point.

The base component is adjusted by the addition of a stress test component. The stress test component is obtained from consideration of the increases in Expected Shortfall that would arise from market movements that are especially large and/or in which various kinds of risk factor exhibit perfect or zero correlations in place of their correlations estimated from historical data, or from extreme adverse idiosyncratic movements in individual risk factors to which the account is particularly exposed.

Brief technical details concerning the base and stress components are provided in the Appendix. Several other components of the overall margin requirement exist, but are typically considerably smaller than the base and stress test components, and many of them affect only a minority of accounts. CMs on elevated Watch Levels as specified in OCC rules may be subject to additional margin requirements.

3. Intraday Withdrawal and Deposits of Collateral

A CM may make intraday withdrawals of excess collateral on an account, and/or deposit fresh collateral assets in place of others.

For collateral types that are subject to a traditional "haircut," the impact of a withdrawal or deposit upon the margin excess incorporates the "haircut."

For collateral types that are subject to "collateral in margins" treatment, the impact of a withdrawal or deposit is based upon a "portfolio specific haircut" (PSH) that is communicated to the applicable CM concerned on a daily basis. The PSH represents the sensitivity of the risk profile of that particular account to its position in the relevant security. In other words, the PSH applicable to any given movement of collateral is designed to provide an estimate of the resulting change in margin requirements if the entire margin calculation was recalculated following the movement.

Appendix

The base component corresponds to the Expected Shortfall (ES) of the portfolio computed at a 99% confidence level using historical estimates of correlations between risk factors:

The stress test component is whichever is the greater of two sub-components called Dependence and Concentration.

The Dependence sub-component can be thought of as a proportion of the extra risk that would arise if we go further out into the tail of the P&L distribution and consider the effects of replacing historical estimates of dependence between single-stock returns with either perfect correlation or zero correlation. ES is computed at a 99.5% confidence levels for each of the historic, perfect and independent correlation assumptions. The Dependence sub-component equals a proportion of the difference between the maximum of the three computations and the base risk requirement:

The Concentration sub-component can be thought of as a proportion of the extra risk that would arise from extreme adverse idiosyncratic moves in two risk-factors to which the portfolio is especially exposed2, coupled with marginally less severe experience in the remainder of the portfolio. ES is computed at a 99.5% confidence level for each of the two single-factor sub-portfolios having the greatest exposure at that level, and those two results are added to the ES of the residual portfolio computed at a 99% confidence level. The Concentration component is a proportion of the amount by which this sum exceeds the base component:

In order to maintain a conservative approach, all calculations of ES are computed using techniques from Extreme Value Theory, and the results are increased to take account of an estimate of the sampling error than arises in the Monte Carlo sample.

1 Long option positions held in customer accounts of CMs, and not part of various designated spread positions, are excluded altogether from OCC margin calculations for investor protection reasons. The effect of the exclusion is that the value of such options does not get used to collateralize other customers' short positions.

2 The single-factor sub-portfolios consist of all positions (options, stock loans, futures etc.) corresponding to one single risk factor. Not all risk factors are considered when selecting these risk factors: for instance positions pertaining to indices are excluded. This reflects the capture only of idiosyncratic risks in this test. If a portfolio contains exposure to less than two sources of idiosyncratic risk, then the formula is adapted in the obvious way.

Risk Management
Extended Trading Hours (ETH) Rules & Procedures
Default Rules & Procedures
Margin Methodology
PFMI Disclosures
Basel II
FSB Continuity of Access to FMIs for Firms in Resolution Survey
Cross Margin Programs
Options & Futures Risk Arrays (OFRA)
Risk Based Haircuts
Customer Portfolio Margin
RBH and CPM Documentation
Portfolio Margin Calculator
Risk Management Framework
Business Continuity

This web site discusses exchange-traded options issued by The Options Clearing Corporation. No statement in this web site is to be construed as a recommendation to purchase or sell a security, or to provide investment advice. Options involve risk and are not suitable for all investors. Prior to buying or selling an option, a person must receive a copy of Characteristics and Risks of Standardized Options. Copies of this document may be obtained from your broker, from any exchange on which options are traded or by contacting The Options Clearing Corporation, 125 S. Franklin Street, Suite 1200, Chicago, IL 60606 (investorservices@theocc.com).

© 2014-2026 The Options Clearing Corporation. All rights reserved.

OCC Website Terms and Conditions
Privacy Policy
Cookie Policy
OCC RSS Feeds
Copyright, Trademark, and Patent Information

This website uses tracking technologies to enhance user experience and to analyze performance. If you click "accept" you are directing us to share information about your visit with third parties. For more information on cookies, see our OCC Cookies Policy and Privacy Policy.

Do not accept analytic cookies
Accept analytic cookies
LINKS
 | https://www.theocc.com/getmedia/8d6a36c6-1aa4-4984-9333-d7b0a6a09be7/unscheduled-market-closings-guide.pdf;
