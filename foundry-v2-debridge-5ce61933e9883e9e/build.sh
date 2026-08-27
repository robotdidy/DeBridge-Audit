#!/usr/bin/env bash
# Instascope v2 — build all chain Foundry roots
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Building Instascope v2 multi-chain project at $ROOT"

failures=()
for chain_dir in "$ROOT"/chains/*/; do
  [ -d "$chain_dir" ] || continue
  chain_id="$(basename "$chain_dir")"
  if ! cd "$chain_dir"; then
    failures+=("$chain_id")
    echo "  FAIL $chain_id (could not enter directory)"
    continue
  fi
  if ./build.sh; then
    echo "  OK $chain_id"
  else
    failures+=("$chain_id")
    echo "  FAIL $chain_id"
  fi
  cd "$ROOT"
done

if [ ${#failures[@]} -gt 0 ]; then
  echo
  echo "Failed chain builds:"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi

echo "All chain builds succeeded"
