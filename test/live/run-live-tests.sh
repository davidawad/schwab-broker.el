#!/usr/bin/env bash
# Run schwab-broker.el's LIVE ERT suite (test/live/schwab-broker-live-test.el)
# against the real Schwab API. Requires a token file with a still-live
# refresh token at ~/.config/schwab/token.json -- if `M-x
# schwab-broker-auth-status` reports it expired, run `M-x
# schwab-broker-authorize` in Emacs first (its authorization code
# expires in ~30s, so that step cannot be scripted headlessly).
#
# Resolves SCHWAB_APP_KEY/SCHWAB_SECRET via David's credential resolver
# at $DOTFILES/infrastructure/trading/credentials.py (default
# ~/.dotfiles) and exports them only into this script's own Emacs
# subprocess -- never printed, logged, or written to disk.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dotfiles_root="${DOTFILES:-$HOME/.dotfiles}"
emacs_bin="${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}"

if [[ ! -d "$dotfiles_root/infrastructure/trading" ]]; then
  echo "schwab-broker live: credential resolver not found under $dotfiles_root/infrastructure/trading (set \$DOTFILES)" >&2
  exit 1
fi

creds="$(python3 -c "
import sys
sys.path.insert(0, '$dotfiles_root')
from infrastructure.trading import credentials
key = credentials.resolve('SCHWAB_APP_KEY')
secret = credentials.resolve('SCHWAB_SECRET')
if not key or not secret:
    sys.exit('schwab-broker live: SCHWAB_APP_KEY/SCHWAB_SECRET not resolvable')
print(key)
print(secret)
")"

SCHWAB_APP_KEY="$(sed -n '1p' <<< "$creds")"
SCHWAB_SECRET="$(sed -n '2p' <<< "$creds")"
unset creds

export SCHWAB_APP_KEY SCHWAB_SECRET
"$emacs_bin" -Q --batch \
  -L "$repo_root" -L "$repo_root/test" -L "$repo_root/test/live" \
  -l "$repo_root/test/live/schwab-broker-live-test.el" \
  -f ert-run-tests-batch-and-exit
