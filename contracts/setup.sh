#!/usr/bin/env bash
# Fetch Solidity dependencies. Run once after cloning.
#
# Deliberately does not use git submodules: this repo is built in environments where
# submodule fetches are unavailable, so forge-std and ds-test are cloned directly and
# everything else comes from npm.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p lib
[ -d lib/forge-std ] || git clone --depth 1 --branch v1.9.6 https://github.com/foundry-rs/forge-std lib/forge-std
[ -d lib/ds-test ]   || git clone --depth 1 https://github.com/dapphub/ds-test lib/ds-test

# `npm install`, not `npm ci`: a transitive @types/node range floats, so a generated lockfile does
# not satisfy `npm ci`'s in-sync check even immediately after being written.
(cd vendor && npm install --no-audit --no-fund)

echo "Dependencies ready. Run: forge test"
