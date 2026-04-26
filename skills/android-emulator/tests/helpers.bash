# Common bats helpers for android-emulator tests. Source from each .bats file:
#
#   load helpers
#
# Provides:
#   - emu_setup: per-test sandbox with stubs on PATH and isolated $TMPDIR
#   - emu_teardown: cleanup
#   - assert_called / refute_called: query the stub call log
#   - source_emu: source emu.sh into the current shell (functions become callable)

# shellcheck disable=SC2034  # consumed by .bats files via `load helpers`
EMU_SCRIPT="$BATS_TEST_DIRNAME/../scripts/emu.sh"
# shellcheck disable=SC2034
EMU_STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
# shellcheck disable=SC2034
EMU_FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"

emu_setup() {
  TEST_TMP="$(mktemp -d)"
  STUB_LOG="$TEST_TMP/calls.log"
  : > "$STUB_LOG"

  export STUB_LOG TEST_TMP
  export ANDROID_EMU_TMP_DIR="$TEST_TMP"
  export ANDROID_EMU_TMP_ID="bats"
  # Fake home so emu_console finds an auth token without touching the real one.
  export HOME="$TEST_TMP"
  printf 'fake-token\n' > "$TEST_TMP/.emulator_console_auth_token"

  # Prepend stubs so they shadow real adb/emulator/nc/sips/sleep/fvm.
  # Keep PATH pointed at the real shell utilities (awk, grep, python3, etc.).
  export PATH="$EMU_STUBS_DIR:$PATH"

  # Default device pixel size — tests can overwrite the cache to change this.
  echo "1080 2400" > "$TEST_TMP/android-emu-device-size"
}

emu_teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Source emu.sh into the current shell so its functions are callable directly.
# Use this for unit-testing pure helpers (detect_pkg, project_root, to_dev, ...).
source_emu() {
  # shellcheck disable=SC1090
  source "$EMU_SCRIPT"
  # emu.sh enables `set -euo pipefail` for its own dispatch. Turn that off in
  # the test shell so bats's `run` machinery (which expects to inspect $status
  # after a non-zero exit) keeps working.
  set +euo pipefail || true
}

# Run emu.sh as a subprocess. Use this for dispatch-level tests where stubs
# observe side effects via $STUB_LOG.
run_emu() {
  run "$EMU_SCRIPT" "$@"
}

assert_called() {
  local pattern="$1"
  if ! grep -F -- "$pattern" "$STUB_LOG" >/dev/null 2>&1; then
    {
      printf 'expected stub call matching: %s\n' "$pattern"
      printf '--- actual call log ---\n'
      cat "$STUB_LOG" 2>/dev/null || echo '(empty)'
      printf '-----------------------\n'
    } >&2
    return 1
  fi
}

refute_called() {
  local pattern="$1"
  if grep -F -- "$pattern" "$STUB_LOG" >/dev/null 2>&1; then
    {
      printf 'unexpected stub call matching: %s\n' "$pattern"
      printf '--- actual call log ---\n'
      cat "$STUB_LOG" 2>/dev/null || echo '(empty)'
      printf '-----------------------\n'
    } >&2
    return 1
  fi
}

# Build a fixture Flutter project under $TEST_TMP. Returns the path on stdout.
# Args: $1 = project subdir name, $2 = "gradle" or "kts", $3 = applicationId
make_flutter_project() {
  local name="$1" flavor="$2" appid="$3"
  local root="$TEST_TMP/$name"
  mkdir -p "$root/android/app"
  printf 'name: demo\n' > "$root/pubspec.yaml"
  case "$flavor" in
    gradle)
      cat > "$root/android/app/build.gradle" <<EOF
android {
  defaultConfig {
    applicationId "$appid"
  }
}
EOF
      ;;
    kts)
      cat > "$root/android/app/build.gradle.kts" <<EOF
android {
  defaultConfig {
    applicationId = "$appid"
  }
}
EOF
      ;;
    none)
      : # no gradle file
      ;;
    *)
      echo "make_flutter_project: unknown flavor '$flavor'" >&2
      return 1
      ;;
  esac
  echo "$root"
}
