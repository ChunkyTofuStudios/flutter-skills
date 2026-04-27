#!/usr/bin/env bats
# Tests for screenshot_preview.sh — Chrome flag plumbing, output paths,
# state-file URL resolution, error paths.

load helpers

setup()    { pw_setup; }
teardown() { pw_teardown; }

# Helper: write a fake state file as if start_preview.sh had run.
write_state() {
  local url="${1:-http://localhost:51530}"
  mkdir -p "$PREVIEW_WIDGET_STATE_DIR"
  cat > "$PREVIEW_WIDGET_STATE_DIR/server.json" <<EOF
{
  "url": "$url",
  "pid": 1,
  "log": "/tmp/x.log",
  "started_at": "2026-01-01T00:00:00Z"
}
EOF
}

@test "captures with defaults (URL from state file, auto-incrementing path)" {
  write_state
  run_screenshot
  [ "$status" -eq 0 ]

  # stdout = output path, and that path exists.
  out_path=$(printf '%s\n' "$output" | grep -E '\.png$' | head -n 1)
  [ -n "$out_path" ]
  [ -f "$out_path" ]
  [[ "$out_path" == "$PREVIEW_WIDGET_OUT_DIR/preview-001.png" ]]
}

@test "auto-increments output filename across runs" {
  write_state
  run_screenshot
  [ "$status" -eq 0 ]
  run_screenshot
  [ "$status" -eq 0 ]
  run_screenshot
  [ "$status" -eq 0 ]

  [ -f "$PREVIEW_WIDGET_OUT_DIR/preview-001.png" ]
  [ -f "$PREVIEW_WIDGET_OUT_DIR/preview-002.png" ]
  [ -f "$PREVIEW_WIDGET_OUT_DIR/preview-003.png" ]
}

@test "--out writes to the requested path and creates parents" {
  write_state
  target="$TEST_TMP/nested/dir/shot.png"
  run_screenshot --out "$target"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [[ "$output" == *"$target"* ]]
}

@test "--url overrides the state file (no state file present is OK)" {
  run_screenshot --url "http://127.0.0.1:7777" --out "$TEST_TMP/x.png"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/x.png" ]
  assert_called "http://127.0.0.1:7777"
}

@test "passes --window-size, --virtual-time-budget, and --headless=new to chrome" {
  write_state
  run_screenshot --size 1920x4000 --wait 15000 --out "$TEST_TMP/x.png"
  [ "$status" -eq 0 ]
  assert_called "--window-size=1920,4000"
  assert_called "--virtual-time-budget=15000"
  assert_called "--headless=new"
  assert_called "--screenshot=$TEST_TMP/x.png"
}

@test "errors when no state file and no --url is provided" {
  run_screenshot --out "$TEST_TMP/x.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No state file"* ]]
  [ ! -f "$TEST_TMP/x.png" ]
}

@test "errors when state file exists but has no \"url\" field" {
  mkdir -p "$PREVIEW_WIDGET_STATE_DIR"
  echo '{"pid": 1}' > "$PREVIEW_WIDGET_STATE_DIR/server.json"
  run_screenshot --out "$TEST_TMP/x.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse"* ]]
}

@test "honors CHROME_BIN override pointing at a missing path" {
  # CHROME_BIN auto-detect on macOS hardcodes /Applications/Google Chrome.app
  # ahead of PATH lookup, so simulating "no Chrome installed" cleanly on a
  # dev Mac is brittle. This test instead asserts that an explicit CHROME_BIN
  # bypasses auto-detect: pointing at a non-existent path means the script
  # tries to run it, the exec fails, the file isn't produced → exit 1 with
  # the expected error.
  write_state
  CHROME_BIN="/definitely/not/here" run_screenshot \
    --out "$TEST_TMP/x.png" --url "http://localhost:1234"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not produce a screenshot"* ]]
}

@test "errors when chrome runs but no file is produced" {
  write_state
  STUB_CHROME_NO_OUTPUT=1 run_screenshot --out "$TEST_TMP/x.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not produce"* ]]
  [ ! -f "$TEST_TMP/x.png" ]
}

@test "isolated user-data-dir flag is set so the call doesn't share the user's profile" {
  write_state
  run_screenshot --out "$TEST_TMP/x.png"
  [ "$status" -eq 0 ]
  assert_called "--user-data-dir="
}
