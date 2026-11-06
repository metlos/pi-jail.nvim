#!/usr/bin/env bash
# Test runner: executes every tests/test_*_spec.lua in headless nvim from repo root.
set -u
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

total=0
failed=0
for spec in tests/test_*_spec.lua; do
  [ -e "$spec" ] || continue
  total=$((total + 1))
  if nvim --headless -u NONE -c "luafile $spec" -c "qa!" >/dev/null 2>&1; then
    echo "ok   $spec"
  else
    failed=$((failed + 1))
    echo "FAIL $spec"
  fi
done

if [ "$total" -eq 0 ]; then
  echo "FAIL no test specs found"
  exit 1
fi
if [ "$failed" -eq 0 ]; then
  echo "PASS $total/$total tests"
  exit 0
fi
echo "FAIL $failed/$total tests"
exit 1
