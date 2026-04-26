#!/usr/bin/env bash
# Run shellcheck across every shell script bundled with a skill. Discovers
# scripts under skills/*/scripts/ (*.sh) and skills/*/tests/{*.bash,stubs/*}.
# Pass paths as arguments to scope to specific files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: `shellcheck` is not installed.
Install with:
  macOS:  brew install shellcheck
  Linux:  apt-get install shellcheck
EOF
  exit 127
fi

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  while IFS= read -r f; do FILES+=("$f"); done < <(
    {
      find skills -type f -name '*.sh'
      find skills -type f -name '*.bash'
      find skills -type f -path '*/tests/stubs/*'
      find tools -type f -name '*.sh'
    } 2>/dev/null | sort -u
  )
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no shell scripts found to lint" >&2
  exit 0
fi

# .bats files are bats syntax (extends bash), shellcheck doesn't grok @test.
# We skip them — the bats suite itself catches their issues at run time.

# --shell=bash forces interpretation for files without a shebang (helpers.bash).
# --external-sources lets shellcheck follow `source helpers` from .bats neighbors.
echo "shellcheck: ${#FILES[@]} file(s)"
shellcheck --shell=bash --external-sources --check-sourced "${FILES[@]}"
echo "OK: shellcheck clean"
