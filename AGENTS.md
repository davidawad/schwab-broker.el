# AGENTS.md — schwab-broker.el

Standalone Emacs package: pure-elisp Charles Schwab API client — OAuth
(manual-authorize paste flow), chmod-600 token store at
`~/.config/schwab/token.json` (shared with other consumers of that
file), full Trader API (accounts, orders, transactions, user
preference) and Market Data API (quotes, price history, option/
expiration chains, movers, market hours, instrument search) coverage.
url.el-only, zero external elisp deps. See `ROADMAP.md` for the
per-endpoint coverage matrix.

## For contributors and agents

- Read `README.md` first ("Getting a token" covers the OAuth flow and
  the ~30s authorization-code expiry) and `ROADMAP.md` (per-endpoint
  coverage matrix, live-test status).
- Tests:
  - Mocked ERT in `test/schwab-broker-test.el`, HTTP mocked — offline,
    no credentials needed, runs in CI. Run with:

    ```
    emacs -Q --batch -L . -L test -l test/schwab-broker-test.el -f ert-run-tests-batch-and-exit
    ```

  - LIVE ERT in `test/live/schwab-broker-live-test.el` — hits the real
    Schwab API against a REAL brokerage account with NO sandbox. Every
    test in it self-skips unless a token file with a still-live
    refresh token exists; never run in CI. Run with
    `test/live/run-live-tests.sh` (resolves credentials from David's
    resolver, never prints them).
- Byte-compile clean (warnings as errors), `checkdoc`-clean, and
  `package-lint`-clean; keep it that way.
- Known constraint, documented in `schwab-broker-oauth.el`: Emacs's
  built-in GnuTLS is client-mode only, so a pure-elisp HTTPS callback
  listener is not implementable and the paste flow is the native
  default. Do not "fix" this by shelling out to external servers
  without discussing it first.
- Order safety, GATED (not read-only) as of v0.2.0: this is a
  REAL-MONEY brokerage account API with no sandbox.
  `schwab-broker-place-order`, `schwab-broker-replace-order`, and
  `schwab-broker-cancel-order` all signal a `user-error` unless the
  defcustom `schwab-broker-allow-orders` is non-nil (default nil).
  `schwab-broker-preview-order` is never gated -- it only simulates.
  Do not loosen or bypass this gate without explicit direction, and
  never call place/replace/cancel from a live test.
- Zero external elisp dependencies. Keep it that way.
- The Streamer WebSocket API is out of scope for this package -- see
  ROADMAP.md. Do not add it without explicit direction.
