# schwab-broker.el

A pure-Elisp client for the [Charles Schwab Trader & Market Data
APIs](https://developer.schwab.com/products), built entirely on Emacs's
built-in `url.el` (HTTP) and native JSON (`json-parse-buffer` /
`json-serialize`) support. No external binary, no Python, no
third-party HTTP or JSON library. Requires Emacs 27.1+.

## Install

Copy `schwab-broker.el`, `schwab-broker-oauth.el`, `schwab-broker-marketdata.el`, and
`schwab-broker-trader.el` somewhere on your `load-path`, then:

```elisp
(require 'schwab-broker)
```

(Or, with `use-package` and a local/straight recipe pointing at this
repo, `(use-package schwab-broker)`.)

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

Schwab's `code=` authorization code expires in about **30 seconds**.
That is the whole reason two flows exist below: the straightforward
paste flow is usually fast enough, but it lost that race once, live
(2026-09-15) -- typing/pasting the redirect URL back into Emacs took
just long enough for the code to expire, and the exchange failed. A
`schwab-broker-authorize-listen` command exists to close that race by
serving the callback instead of round-tripping through your clipboard
and the minibuffer -- see below for its current, honest limitation.

Both flows write to the same place, `schwab-broker-token-file`
(default `~/.config/schwab/token.json`, created with file mode `600`):
whichever one you use, the result is the same on-disk token. That file
is also this package's interop point with any other consumer of the
same OAuth app -- notably its Python-side sibling implementation
(`tradeboards auth schwab`), which reads and refreshes the identical
JSON shape. Point both at the same path and either one's refresh is
immediately visible to the other (see "Token-file interop note"
below).

### Paste flow (the default, always works)

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
   prompt and hit `RET`.

`schwab-broker-authorize` extracts the `code=` parameter, exchanges it for an
access/refresh token pair, and writes them to `schwab-broker-token-file`.
Every subsequent call in this package refreshes that token on disk
automatically as it nears expiry -- you only need to re-run
`schwab-broker-authorize` again if the *refresh* token itself expires
(Schwab's refresh tokens last about 7 days).

If you're regularly losing the 30-second race against the clipboard
and minibuffer, that's exactly the failure `schwab-broker-authorize-listen`
exists to fix -- see the next section for its current status.

### Listener flow (`schwab-broker-authorize-listen`) -- not usable yet

```
M-x schwab-broker-authorize-listen
```

**As currently shipped, this command always signals an error.** It
opens the same consent page `schwab-broker-authorize` does (so that
half works), but Emacs's built-in GnuTLS integration only supports
*client*-mode TLS -- it cannot terminate the inbound HTTPS connection
Schwab's callback URL requires, so it cannot actually catch and
exchange the redirect. This was investigated and confirmed live, not
assumed: standing up a `make-network-process` server with
`:tls-parameters` and connecting to it with a real TLS client shows the
accepted connection receiving the still-encrypted `ClientHello` bytes
verbatim -- no server-side handshake is ever attempted. See
`schwab-broker--listener-ensure-tls-available`'s docstring in
`schwab-broker-oauth.el` for the full evidence.

Until Emacs (or this package, via some future pluggable TLS backend)
gains real server-role TLS support, use one of:

- `schwab-broker-authorize` -- the paste flow above, unaffected by any
  of this.
- `tradeboards auth schwab --listen` -- this package's Python-side
  sibling CLI *does* have a working callback listener (Python's `ssl'
  module supports server-role TLS), writing to the same
  `~/.config/schwab/token.json` this package reads.

The request-parsing/exchange/one-shot/timeout machinery
`schwab-broker-authorize-listen` would use, once real TLS support
exists, is implemented and tested regardless (`schwab-broker--listener-run'
and its siblings in `schwab-broker-oauth.el`) -- only the TLS
termination step itself is the gap. Customization variables
`schwab-broker-tls-cert-file`/`schwab-broker-tls-key-file` (an ephemeral
self-signed cert auto-generated via `openssl` if neither is set) and
`schwab-broker-listener-timeout` are ready for whenever that gap closes.

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
| `schwab-broker-authorize-listen` | Interactive callback-listener flow -- currently always errors; see "Getting a token" above. |
| `schwab-broker-auth-status` | Interactive: report authentication state via `message`. |

### Market data (`schwab-broker-marketdata.el`, `https://api.schwabapi.com/marketdata/v1`)

| Function | Description |
| --- | --- |
| `schwab-broker-quote SYMBOL CALLBACK` | Single symbol's quote. |
| `schwab-broker-quotes SYMBOLS CALLBACK` | Batch quotes; `SYMBOLS` is a list or comma-separated string. |
| `schwab-broker-price-history SYMBOL CALLBACK &key period-type period frequency-type frequency start end need-extended-hours-data need-previous-close` | OHLCV candles. |
| `schwab-broker-option-chain SYMBOL CALLBACK &key contract-type strike-count include-underlying-quote strategy interval strike range from-date to-date volatility underlying-price interest-rate days-to-expiration exp-month option-type` | Full option-chain parameter surface. |
| `schwab-broker-market-hours MARKETS CALLBACK &key date` | Market-hours for one or more markets. |
| `schwab-broker-movers INDEX CALLBACK &key sort frequency` | Top movers for an index/exchange. |
| `schwab-broker-show-quote SYMBOL` | Interactive demo: fetch + `message` a quote's last/mark price. |

### Trader (`schwab-broker-trader.el`, `https://api.schwabapi.com/trader/v1`)

| Function | Description |
| --- | --- |
| `schwab-broker-account-numbers CALLBACK` | Account-number/hash-value mappings. |
| `schwab-broker-accounts CALLBACK &key positions` | All accounts, optionally with positions. |
| `schwab-broker-positions CALLBACK` | Flattened positions across all accounts, each tagged with its `accountNumber`. |

**No order placement.** There is no `schwab-broker-place-order`/`schwab-broker-stage-order`
function anywhere in this package, by construction -- everything above
is read-only market data and account access.

## Token-file interop note

`schwab-broker-token-file` (default `~/.config/schwab/token.json`) uses the
same JSON shape as a reference Python-side sibling implementation of
this same OAuth flow: `access_token`, `refresh_token`,
`access_token_expires_at`, `refresh_token_expires_at`, `obtained_at`
(the two `_expires_at` fields are ISO-8601 UTC strings). A Python
client written against that shape and this Emacs client can point at
the same file and share one authorization -- whichever one refreshes
first (serialized on the Emacs side by a `mkdir`-based lockfile,
`TOKEN-FILE.lock`, alongside the token file) writes the new tokens back
for the other to pick up. This is a best-effort lock: it only
serializes concurrent refreshes issued from within one Emacs process,
not true cross-process mutual exclusion with a separately-running
script refreshing at the exact same instant.

## Roadmap

- Order placement (staging/firing trades) is explicitly out of scope
  for this initial version and not implemented anywhere in this
  package.
- Streamer (Schwab's WebSocket-based real-time streaming quotes) is
  not implemented.
- Transaction history and account-level order/transaction endpoints
  are not yet covered.
- `schwab-broker-authorize-listen` cannot actually serve HTTPS today --
  Emacs's built-in GnuTLS only supports client-mode TLS. See "Getting a
  token" above for the investigation and the working alternatives.

## Development

Tests live in `test/schwab-broker-test.el` (ERT), mocking the built-in
`url-retrieve` boundary -- no real network access, no real credentials.
Byte-compiles clean and is `checkdoc`-clean.
