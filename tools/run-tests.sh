#!/usr/bin/env bash
# Run every skill's bats test suite. Each skill that ships tests puts them
# under skills/<name>/tests/ and they're discovered by file extension (*.bats).
#
# Skills without a tests/ directory are skipped — adding tests to a skill is
# a welcome contribution; see skills/android-emulator/tests/ for the layout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v bats >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: `bats` is not installed.
Install with:
  macOS:  brew install bats-core
  Linux:  apt-get install bats   (or: npm install -g bats)
EOF
  exit 127
fi

# Allow `tools/run-tests.sh skills/foo` to scope to one skill, otherwise
# discover all skills/*/tests directories.
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=()
  for d in skills/*/tests; do
    [ -d "$d" ] || continue
    TARGETS+=("$d")
  done
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "no skill test directories found under skills/*/tests" >&2
  exit 0
fi

fail=0
for target in "${TARGETS[@]}"; do
  files=()
  if [ -d "$target" ]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find "$target" -maxdepth 2 -name '*.bats' -type f | sort)
  elif [ -f "$target" ]; then
    files=("$target")
  else
    echo "skip: $target (not a directory or .bats file)" >&2
    continue
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    echo "skip: $target (no .bats files)" >&2
    continue
  fi

  printf '\n=== %s ===\n' "$target"
  if ! bats "${files[@]}"; then
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "FAIL: one or more bats suites failed" >&2
  exit 1
fi

echo
echo "OK: all bats suites passed"
