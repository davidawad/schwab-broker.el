# AGENTS.md — schwab-broker.el

Standalone Emacs package: pure-elisp Charles Schwab API client — OAuth
(manual-authorize paste flow), chmod-600 token store at
`~/.config/schwab/token.json` (shared with other consumers of that
file), quotes, price history, full option-chain parameter surface,
read-only accounts/positions. url.el-only, zero external elisp deps.

## For contributors and agents

- Read `README.md` first ("Getting a token" covers the OAuth flow and
  the ~30s authorization-code expiry).
- Tests: ERT in `test/schwab-broker-test.el`, HTTP mocked — offline, no
  credentials needed. Run with:

  ```
  emacs -Q --batch -L . -L test -l test/schwab-broker-test.el -f ert-run-tests-batch-and-exit
  ```

- Byte-compile clean (warnings as errors), `checkdoc`-clean, and
  `package-lint`-clean; keep it that way.
- Known constraint, documented in `schwab-broker-oauth.el`: Emacs's
  built-in GnuTLS is client-mode only, so a pure-elisp HTTPS callback
  listener is not implementable and the paste flow is the native
  default. Do not "fix" this by shelling out to external servers
  without discussing it first.
- READ-ONLY by design in v1: no order placement. Do not add order
  submission without explicit direction.
- Zero external elisp dependencies. Keep it that way.
