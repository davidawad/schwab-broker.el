# AGENTS.md — schwab-broker.el

Standalone, publishable Emacs package: pure-elisp Charles Schwab API
client — OAuth (manual-authorize paste flow), chmod-600 token store at
`~/.config/schwab/token.json` (shared with other consumers of that
file), quotes, price history, full option-chain parameter surface,
read-only accounts/positions. url.el-only, zero external elisp deps.

## For agents

- Read `README.md` first ("Getting a token" covers the OAuth flows and
  the ~30s authorization-code expiry).
- Tests: ERT in `test/schwab-broker-test.el`, HTTP mocked — offline, no
  credentials needed.
- Known constraint, documented in `schwab-broker-oauth.el`: Emacs's
  built-in GnuTLS is client-mode only, so a pure-elisp HTTPS callback
  listener is structurally impossible; `schwab-broker-authorize-listen`
  explains this and the paste flow is the native default. Do not "fix"
  this by shelling out to external servers without the owner's
  direction.
- READ-ONLY by design in v1: no order placement. Do not add order
  submission without the owner's explicit direction.
- Zero references to the owner's dotfiles are allowed here — the repo
  must remain publishable as-is. The canonical development copy is
  mirrored in the owner's dotfiles under
  `config/terminal/emacs/custom-plugins/schwab-broker/`; substantive
  changes should land in both.
- Authorized: david, swe.
