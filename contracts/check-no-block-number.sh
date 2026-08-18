#!/usr/bin/env bash
# §12: all timing is timestamp-denominated. On Arbitrum-stack chains `block.number` tracks an
# approximation of the L1 block number, so block-denominated logic is wrong by construction.
#
# This cannot be a Solidity test: the property is about source text, not runtime behaviour, and a
# contract cannot read its own source. So it is a grep, run in CI.
set -euo pipefail
cd "$(dirname "$0")"

if hits=$(grep -rn --include='*.sol' 'block\.number' src/ script/ 2>/dev/null); then
  echo "block.number is forbidden (§12). Found:"
  echo "$hits"
  exit 1
fi

echo "ok: block.number appears nowhere in src/ or script/"
