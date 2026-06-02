#!/bin/bash
# Inject vendored test files into the leanVM workspace.
# Called by correctness.sh before running cargo test.
# Idempotent — safe to run multiple times.
#
# This eliminates the need to cherry-pick test branches into every experiment.

set -e

LM_DIR="${LM_DIR:-$HOME/zk-autoresearch/leanVM}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUINTIC_DIR="$LM_DIR/crates/backend/koala-bear/src/quintic_extension"

# 1. Copy quintic extension tests
cp "$SCRIPT_DIR/quintic_extension_tests.rs" "$QUINTIC_DIR/tests.rs"

# 2. Ensure mod.rs declares the tests module
if ! grep -q "^mod tests;" "$QUINTIC_DIR/mod.rs" && ! grep -q "^#\[cfg(test)\]" "$QUINTIC_DIR/mod.rs"; then
  # Add test module declaration after the last pub mod line
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' '/^pub(crate) mod packing;/a\'$'\n''#[cfg(test)]\'$'\n''mod tests;' "$QUINTIC_DIR/mod.rs"
  else
    sed -i '/^pub(crate) mod packing;/a #[cfg(test)]\nmod tests;' "$QUINTIC_DIR/mod.rs"
  fi
fi
