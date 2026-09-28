# ROADMAP.md — schwab-broker.el API coverage

Coverage matrix for the Charles Schwab **Trader API** and **Market
Data API**. One row per Schwab endpoint. "Live-tested" reflects the
most recent run of `test/live/schwab-broker-live-test.el` (never run
in CI; requires a live refresh token at `~/.config/schwab/token.json`).

Last updated: 2026-09-28. As of this update, David's refresh token had
expired (2026-09-24) and had not yet been renewed via `M-x
schwab-broker-authorize`, so every live row below is "pending reauth"
rather than an actual pass/fail — see "Known blocker" at the bottom.

## Trader API (`https://api.schwabapi.com/trader/v1`)

| Method + path | Elisp function(s) | Mocked test | Live-tested | Notes |
|---|---|---|---|---|
| GET `/accounts/accountNumbers` | `schwab-broker-account-numbers`(`-sync`) | yes | pending reauth | account-number → hash-value mapping |
| GET `/accounts` | `schwab-broker-accounts`(`-sync`) | yes | pending reauth | `:positions t` requests the `positions` field |
| GET `/accounts/{accountNumber}` | `schwab-broker-account`(`-sync`) | yes | pending reauth | `accountNumber` is the opaque `hashValue`, not the plain account number |
| — (derived, no Schwab endpoint) | `schwab-broker-positions`(`-sync`) | yes | pending reauth | flattens `schwab-broker-accounts` `:positions t` across accounts |
| GET `/accounts/{accountNumber}/orders` | `schwab-broker-orders-for-account`(`-sync`) | yes | pending reauth | |
| POST `/accounts/{accountNumber}/orders` | `schwab-broker-place-order`(`-sync`) | yes | **not run** (real-money account; verified via previewOrder + mocks) | gated on `schwab-broker-allow-orders` |
| GET `/accounts/{accountNumber}/orders/{orderId}` | `schwab-broker-order`(`-sync`) | yes | pending reauth | |
| PUT `/accounts/{accountNumber}/orders/{orderId}` | `schwab-broker-replace-order`(`-sync`) | yes | **not run** (real-money account; verified via previewOrder + mocks) | gated on `schwab-broker-allow-orders` |
| DELETE `/accounts/{accountNumber}/orders/{orderId}` | `schwab-broker-cancel-order`(`-sync`) | yes | **not run** (real-money account; verified via previewOrder + mocks) | gated on `schwab-broker-allow-orders` |
| GET `/orders` | `schwab-broker-orders`(`-sync`) | yes | pending reauth | orders across all linked accounts |
| POST `/accounts/{accountNumber}/previewOrder` | `schwab-broker-preview-order`(`-sync`) | yes | pending reauth | never gated by `schwab-broker-allow-orders` -- simulates only |
| GET `/accounts/{accountNumber}/transactions` | `schwab-broker-transactions`(`-sync`) | yes | pending reauth | |
| GET `/accounts/{accountNumber}/transactions/{transactionId}` | `schwab-broker-transaction`(`-sync`) | yes | not run | needs a real `transactionId`, not exercised by the live suite (no synthetic id to fetch without first placing an order) |
| GET `/userPreference` | `schwab-broker-user-preference`(`-sync`) | yes | pending reauth | |

## Market Data API (`https://api.schwabapi.com/marketdata/v1`)

| Method + path | Elisp function(s) | Mocked test | Live-tested | Notes |
|---|---|---|---|---|
| GET `/quotes` | `schwab-broker-quotes`(`-sync`) | yes | pending reauth | batch quotes |
| GET `/{symbol_id}/quotes` | `schwab-broker-quote`(`-sync`) | yes | pending reauth | single quote |
| GET `/chains` | `schwab-broker-option-chain`(`-sync`) | yes | pending reauth | full parameter surface |
| GET `/expirationchain` | `schwab-broker-expiration-chain`(`-sync`) | yes | pending reauth | |
| GET `/pricehistory` | `schwab-broker-price-history`(`-sync`) | yes | pending reauth | |
| GET `/movers/{symbol_id}` | `schwab-broker-movers`(`-sync`) | yes | pending reauth | |
| GET `/markets` | `schwab-broker-market-hours`(`-sync`) | yes | pending reauth | multiple markets in one call |
| GET `/markets/{market_id}` | `schwab-broker-market`(`-sync`) | yes | pending reauth | single market |
| GET `/instruments` | `schwab-broker-instruments`(`-sync`) | yes | pending reauth | symbol search by projection |
| GET `/instruments/{cusip_id}` | `schwab-broker-instrument`(`-sync`) | yes | pending reauth | fundamentals by CUSIP |

## Order-spec builders (pure functions, no I/O)

Mirrors schwab-py's `schwab.orders.equities`/`schwab.orders.options`
templates. Not Schwab endpoints themselves -- they build the JSON body
that `schwab-broker-place-order`/`schwab-broker-preview-order`/
`schwab-broker-replace-order` send.

| Function | Mocked test | Notes |
|---|---|---|
| `schwab-broker-order-spec` | yes | generic builder every wrapper below is implemented on top of |
| `schwab-broker-order-equity-market` | yes | |
| `schwab-broker-order-equity-limit` | yes | |
| `schwab-broker-order-equity-stop` | yes | |
| `schwab-broker-order-equity-stop-limit` | yes | |
| `schwab-broker-order-option-market` | yes | |
| `schwab-broker-order-option-limit` | yes | |

## Out of scope for this version

| Item | Status | Notes |
|---|---|---|
| Streamer WebSocket API | out of scope | real-time push streaming is architecturally distinct from this package's request/response model (persistent connection, subscription protocol, its own auth handshake); a future addition, if ever made, belongs in its own file with its own review, not bolted onto this client |

## Order safety model

`schwab-broker-place-order`, `schwab-broker-replace-order`, and
`schwab-broker-cancel-order` (and their `-sync` forms) all signal a
`user-error` unless `schwab-broker-allow-orders` is non-nil; it
defaults to nil. `schwab-broker-preview-order` is never gated, since
Schwab's own `/previewOrder` endpoint only simulates an order and
places nothing. This replaces the earlier "read-only by design"
posture (no order endpoints existed at all) with a gated model: order
mutation endpoints exist, but are inert until explicitly armed.

Per direction, this package's own live-test suite never calls
place/replace/cancel against the real account, regardless of the gate
-- those three endpoints are verified by the mocked ERT suite (request
method/URL/body shape) plus a live `previewOrder` run against the same
kind of order spec, which exercises Schwab's real order-validation
logic without ever resting an order on the book.

## Known blocker: refresh token expired

David's refresh token at `~/.config/schwab/token.json` expired
2026-09-24 (Schwab refresh tokens live ~7 days and are not
long-lived). Reauthorizing requires running `M-x
schwab-broker-authorize` interactively -- it opens a browser consent
page and needs the redirect URL pasted back within Schwab's ~30-second
authorization-code window, which cannot be done headlessly by an
agent.

To pick every "pending reauth" row above up to pass/fail:

```
M-x schwab-broker-authorize
```

then run the live suite with one command:

```
test/live/run-live-tests.sh
```

(This resolves `SCHWAB_APP_KEY`/`SCHWAB_SECRET` from David's own
credential resolver and never prints them.)
