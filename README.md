# schwab-broker.el

A pure-Elisp client for the [Charles Schwab Trader & Market Data
APIs](https://developer.schwab.com/products), built entirely on Emacs's
built-in `url.el` (HTTP) and native JSON (`json-parse-buffer` /
`json-serialize`) support. No external binary, no Python, no
third-party HTTP or JSON library. Requires Emacs 27.1+.

## Install

Copy `schwab-broker.el`, `schwab-broker-oauth.el`, `schwab-broker-marketdata.el`,
`schwab-broker-orders.el`, and `schwab-broker-trader.el` somewhere on
your `load-path`, then:

```elisp
(require 'schwab-broker)
```

Or, with `straight.el` and `use-package`:

```elisp
(use-package schwab-broker
  :straight (schwab-broker :type git :host github
                            :repo "davidawad/schwab-broker.el"
                            :files ("schwab-broker*.el")))
```

## Register an app

1. Go to <https://developer.schwab.com>, sign in with your Schwab
   account, and create an app (individual developer apps are fine for
   personal use).
2. Request access to both the **Accounts and Trading Production** and
   **Market Data Production** APIs on the app.
3. Set a callback/redirect URL. Schwab requires `https`, even for a
   loopback address you never actually serve; `https://127.0.0.1:3600`
   (this package's default) works and needs nothing listening on that
   port -- you only ever copy the browser's address bar after it
   redirects there, you never actually connect to it.
4. Wait for the app status to become "Ready For Use" (this can take a
   few minutes to a day). Note its **Consumer Key** and **Consumer
   Secret**.

## Configure credentials

Any one of, in this resolution order:

```elisp
;; 1. Customization variables (a literal string, or a function of no
;;    arguments that fetches one from your own secret manager):
(setq schwab-broker-app-key "your-consumer-key"
      schwab-broker-app-secret "your-consumer-secret")

;; 2. auth-source (e.g. an entry in ~/.authinfo.gpg):
;;      machine api.schwabapi.com login app-key password YOUR-CONSUMER-KEY
;;      machine api.schwabapi.com login app-secret password YOUR-CONSUMER-SECRET

;; 3. Environment variables, as a last resort:
;;      SCHWAB_APP_KEY=your-consumer-key
;;      SCHWAB_SECRET=your-consumer-secret
```

If you registered a callback URL other than the default
`https://127.0.0.1:3600`, also set:

```elisp
(setq schwab-broker-callback-url "https://127.0.0.1:YOUR-PORT")
```

## Getting a token

Schwab's `code=` authorization code expires in about **30 seconds**, so
move quickly through the paste step below.

Tokens are written to `schwab-broker-token-file` (default
`~/.config/schwab/token.json`, created with file mode `600`). That file
is also this package's interop point with any other client using the
same JSON shape -- see "Token-file interop note" below.

### Paste flow

Schwab's OAuth flow expects a real HTTP redirect target, which a
script/desktop client like this one doesn't run. The workaround --
"manual authorize" -- is: open the consent URL, log in and approve
access in the browser, then copy the URL the browser lands on
afterward (it 404s or shows a browser error page -- that's expected,
nothing is listening on the callback port) and paste it back.

```
M-x schwab-broker-authorize
```

1. Your default browser opens Schwab's login/consent page.
2. Log in and approve access for your app.
3. The browser redirects to your callback URL (e.g.
   `https://127.0.0.1:3600/?code=C0.b2F1dGgy...&session=...`) and
   fails to load anything there -- that's fine.
4. Copy that entire URL from the browser's address bar.
5. Back in Emacs, paste it at the `Paste the full redirect URL here:`
   prompt and hit `RET`. Do this quickly -- the `code=` value expires
   in about 30 seconds.

`schwab-broker-authorize` extracts the `code=` parameter, exchanges it for an
access/refresh token pair, and writes them to `schwab-broker-token-file`.
Every subsequent call in this package refreshes that token on disk
automatically as it nears expiry -- you only need to re-run
`schwab-broker-authorize` again if the *refresh* token itself expires
(Schwab's refresh tokens last about 7 days).

### Check auth state

Never prints token values, only presence/expiries:

```
M-x schwab-broker-auth-status
```

## Try it

```
M-x schwab-broker-show-quote RET AAPL RET
```

## Function reference

Every function below has a synchronous `-sync` sibling (e.g.
`schwab-broker-quote` / `schwab-broker-quote-sync`) built on top of the same async
implementation. The async form takes a trailing `CALLBACK` argument
called with two values, `(DATA ERR)`: on success `ERR` is nil and
`DATA` is the parsed JSON response (as nested alists); on failure
`DATA` is nil and `ERR` is a small plist describing what went wrong.
The `-sync` form blocks (bounded by `schwab-broker-http-timeout`, default 15s)
and either returns `DATA` directly or signals `schwab-broker-error` with
`ERR` as its condition data.

### Auth (`schwab-broker-oauth.el`)

| Function | Description |
| --- | --- |
| `schwab-broker-authorize` | Interactive manual-authorize (paste) flow (see above). |
| `schwab-broker-auth-status` | Interactive: report authentication state via `message`. |

### Market data (`schwab-broker-marketdata.el`, `https://api.schwabapi.com/marketdata/v1`)

| Function | Description |
| --- | --- |
| `schwab-broker-quote SYMBOL CALLBACK` | Single symbol's quote. |
| `schwab-broker-quotes SYMBOLS CALLBACK` | Batch quotes; `SYMBOLS` is a list or comma-separated string. |
| `schwab-broker-price-history SYMBOL CALLBACK &key period-type period frequency-type frequency start end need-extended-hours-data need-previous-close` | OHLCV candles. |
| `schwab-broker-option-chain SYMBOL CALLBACK &key contract-type strike-count include-underlying-quote strategy interval strike range from-date to-date volatility underlying-price interest-rate days-to-expiration exp-month option-type` | Full option-chain parameter surface. |
| `schwab-broker-expiration-chain SYMBOL CALLBACK` | Option expiration dates for a symbol. |
| `schwab-broker-market-hours MARKETS CALLBACK &key date` | Market hours for one or more markets. |
| `schwab-broker-market MARKET-ID CALLBACK &key date` | Market hours for a single market (`"equity"`, `"option"`, ...). |
| `schwab-broker-movers INDEX CALLBACK &key sort frequency` | Top movers for an index/exchange. |
| `schwab-broker-instruments SYMBOL PROJECTION CALLBACK` | Instrument search (`symbol-search`, `desc-search`, `fundamental`, ...). |
| `schwab-broker-instrument CUSIP CALLBACK` | Instrument fundamentals by CUSIP. |
| `schwab-broker-show-quote SYMBOL` | Interactive demo: fetch + `message` a quote's last/mark price. |

### Trader (`schwab-broker-trader.el`, `https://api.schwabapi.com/trader/v1`)

Every account-scoped function below takes an `ACCOUNT-HASH` -- the
opaque `hashValue` returned by `schwab-broker-account-numbers`, never
the plain account number.

| Function | Description |
| --- | --- |
| `schwab-broker-account-numbers CALLBACK` | Account-number/hash-value mappings. |
| `schwab-broker-accounts CALLBACK &key positions` | All accounts, optionally with positions. |
| `schwab-broker-account ACCOUNT-HASH CALLBACK &key positions` | One account. |
| `schwab-broker-positions CALLBACK` | Flattened positions across all accounts, each tagged with its `accountNumber`. |
| `schwab-broker-orders-for-account ACCOUNT-HASH CALLBACK &key max-results from-entered-time to-entered-time status` | List one account's orders. |
| `schwab-broker-place-order ACCOUNT-HASH ORDER-SPEC CALLBACK` | Place an order. **Gated** -- see "Order safety" below. |
| `schwab-broker-order ACCOUNT-HASH ORDER-ID CALLBACK` | Fetch one order. |
| `schwab-broker-replace-order ACCOUNT-HASH ORDER-ID ORDER-SPEC CALLBACK` | Replace an order. **Gated.** |
| `schwab-broker-cancel-order ACCOUNT-HASH ORDER-ID CALLBACK` | Cancel an order. **Gated.** |
| `schwab-broker-orders CALLBACK &key max-results from-entered-time to-entered-time status` | List orders across all linked accounts. |
| `schwab-broker-preview-order ACCOUNT-HASH ORDER-SPEC CALLBACK` | Simulate an order. Never gated -- places nothing. |
| `schwab-broker-transactions ACCOUNT-HASH CALLBACK &key start-date end-date symbol types` | List one account's transactions. |
| `schwab-broker-transaction ACCOUNT-HASH TRANSACTION-ID CALLBACK` | Fetch one transaction. |
| `schwab-broker-user-preference CALLBACK` | The caller's user preferences (streamer info, account nicknames/colors). |

### Order-spec builders (`schwab-broker-orders.el`)

Pure functions -- no network I/O -- that build the JSON alist
`schwab-broker-place-order`/`schwab-broker-preview-order`/
`schwab-broker-replace-order` send, mirroring schwab-py's order
templates. `INSTRUCTION` is one of Schwab's own enums: `"BUY"`/`"SELL"`
for equities, `"BUY_TO_OPEN"`/`"BUY_TO_CLOSE"`/`"SELL_TO_OPEN"`/
`"SELL_TO_CLOSE"` for options.

| Function | Description |
| --- | --- |
| `schwab-broker-order-spec &key order-type session duration order-strategy-type price stop-price legs` | Generic builder every wrapper below is implemented on top of. |
| `schwab-broker-order-equity-market SYMBOL INSTRUCTION QUANTITY` | Market order for shares. |
| `schwab-broker-order-equity-limit SYMBOL INSTRUCTION QUANTITY PRICE` | Limit order for shares. |
| `schwab-broker-order-equity-stop SYMBOL INSTRUCTION QUANTITY STOP-PRICE` | Stop order for shares. |
| `schwab-broker-order-equity-stop-limit SYMBOL INSTRUCTION QUANTITY STOP-PRICE PRICE` | Stop-limit order for shares. |
| `schwab-broker-order-option-market OPTION-SYMBOL INSTRUCTION QUANTITY` | Market order for an option contract. |
| `schwab-broker-order-option-limit OPTION-SYMBOL INSTRUCTION QUANTITY PRICE` | Limit order for an option contract. |

```elisp
;; Preview (never places) a limit buy of 1 share of AAPL at $150:
(let* ((hash (alist-get 'hashValue (car (schwab-broker-account-numbers-sync))))
       (spec (schwab-broker-order-equity-limit "AAPL" "BUY" 1 150.00)))
  (schwab-broker-preview-order-sync hash spec))
```

## Order safety

This is a **REAL-MONEY brokerage account API with no sandbox.**
`schwab-broker-place-order`, `schwab-broker-replace-order`, and
`schwab-broker-cancel-order` (and their `-sync` forms) all signal a
`user-error` unless the defcustom `schwab-broker-allow-orders` is
non-nil; it defaults to nil:

```elisp
(setq schwab-broker-allow-orders t) ; opt in, deliberately
```

`schwab-broker-preview-order` is never gated by this variable, since
Schwab's own `/previewOrder` endpoint only simulates an order and
places nothing.

## Token-file interop note

`schwab-broker-token-file` (default `~/.config/schwab/token.json`) uses a
simple JSON shape: `access_token`, `refresh_token`,
`access_token_expires_at`, `refresh_token_expires_at`, `obtained_at`
(the two `_expires_at` fields are ISO-8601 UTC strings). Any other
client using the same JSON shape can point at the same file and share
one authorization -- whichever one refreshes first (serialized on the
Emacs side by a `mkdir`-based lockfile, `TOKEN-FILE.lock`, alongside
the token file) writes the new tokens back for the other to pick up.
This is a best-effort lock: it only serializes concurrent refreshes
issued from within one Emacs process, not true cross-process mutual
exclusion with a separately-running script refreshing at the exact
same instant.

## Roadmap

See `ROADMAP.md` for the full per-endpoint coverage matrix (method +
path, elisp function, mocked/live test status). In short:

- Full Trader API and Market Data API coverage as of v0.2.0.
- The Streamer (Schwab's WebSocket-based real-time streaming quotes)
  is explicitly out of scope for this package -- see `ROADMAP.md`.
- A callback listener (to avoid the manual paste step) isn't possible
  yet -- Emacs's built-in GnuTLS only supports client-mode TLS, so it
  cannot terminate the inbound HTTPS connection Schwab's callback URL
  requires.

## Development

- Mocked tests live in `test/schwab-broker-test.el` (ERT), mocking the
  built-in `url-retrieve` boundary -- no real network access, no real
  credentials, runs in CI. Byte-compiles clean (warnings as errors),
  and is `checkdoc`-clean and `package-lint`-clean.
- LIVE tests live in `test/live/schwab-broker-live-test.el` -- hit the
  real Schwab API against a real account, self-skip without a live
  token, and never run in CI. Run via `test/live/run-live-tests.sh`.
