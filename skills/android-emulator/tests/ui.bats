#!/usr/bin/env bats
# Tests for the accessibility-tree commands: ui-list, ui-find, tap-label,
# hold-label. The `adb exec-out sh -c ...uiautomator dump...` invocation is
# stubbed to cat tests/fixtures/ui-dump.xml (set via STUB_ADB_UI_FIXTURE).

load helpers

setup() {
  emu_setup
  export STUB_ADB_UI_FIXTURE="$EMU_FIXTURES_DIR/ui-dump.xml"
}
teardown() { emu_teardown; }

# --- ui-list -----------------------------------------------------------------

@test "ui-list prints a header and one row per labelled node" {
  run_emu ui-list
  [ "$status" -eq 0 ]
  [[ "$output" == *"label"* ]]                  # header line
  [[ "$output" == *"'Welcome'"* ]]              # text label
  [[ "$output" == *"'Login'"* ]]                # button text
  [[ "$output" == *"'Settings'"* ]]             # content-desc on icon button
  [[ "$output" == *"'Login with Google'"* ]]
}

@test "ui-list flags clickable / long-clickable / scrollable nodes" {
  run_emu ui-list
  [ "$status" -eq 0 ]
  # Login button: clickable only.
  echo "$output" | grep -E "tap[[:space:]]+'Login'" >/dev/null
  # Settings: clickable AND long-clickable.
  echo "$output" | grep -E "tap,hold[[:space:]]+'Settings'" >/dev/null
  # ScrollView is scrollable (and unlabelled in our fixture except by resource-id).
  echo "$output" | grep "scroll" >/dev/null
}

@test "ui-list filters out zero-area nodes" {
  run_emu ui-list
  [ "$status" -eq 0 ]
  # The fixture has a node with bounds [0,0][0,0]; it should not appear.
  # We assert no row has zero coordinates by checking the empty <View> isn't listed.
  ! echo "$output" | grep -E "^\s*0\s+0\s" >/dev/null
}

@test "ui-list exits 2 with a hint when the dump has no labelled nodes" {
  printf '%s\n' \
    "<?xml version='1.0'?>" \
    "<hierarchy><node bounds='[0,0][100,100]' /></hierarchy>" \
    > "$TEST_TMP/empty-dump.xml"
  STUB_ADB_UI_FIXTURE="$TEST_TMP/empty-dump.xml" run_emu ui-list
  [ "$status" -eq 2 ]
  [[ "$output" == *"semantics"* ]] || [[ "$stderr" == *"semantics"* ]]
}

# --- ui-find -----------------------------------------------------------------

@test "ui-find returns bounds + screenshot/device centers for an exact match" {
  run_emu ui-find Login
  [ "$status" -eq 0 ]
  # Fixture: Login button bounds=[200,800][880,900], device 1080-wide.
  # Device center = (540, 850); screenshot center = (180, 283).
  [[ "$output" == *"device: 540 850"* ]]
  [[ "$output" == *"bounds: [200,800][880,900]"* ]]
}

@test "ui-find prefers an exact match over a substring match" {
  # Fixture has "Login" (exact) and "Login with Google" (substring of itself).
  # Searching "Login" must return the exact-match bounds, not the longer label.
  run_emu ui-find Login
  [ "$status" -eq 0 ]
  [[ "$output" == *"[200,800][880,900]"* ]]      # the "Login" button
  [[ "$output" != *"[200,950][880,1050]"* ]]     # not "Login with Google"
}

@test "ui-find falls back to substring when no exact match exists" {
  run_emu ui-find Google
  [ "$status" -eq 0 ]
  [[ "$output" == *"[200,950][880,1050]"* ]]
}

@test "ui-find dies when no node matches the label" {
  run_emu ui-find DoesNotExist
  [ "$status" -ne 0 ]
  [[ "$output" == *"no UI node matching"* ]]
}

@test "ui-find fails with usage when no label is given" {
  run_emu ui-find
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

# --- tap-label / hold-label --------------------------------------------------

@test "tap-label taps the device-px center of the matched node" {
  run_emu tap-label Login
  [ "$status" -eq 0 ]
  # Login bounds=[200,800][880,900] → center (540, 850) in device px.
  assert_called "adb -s emulator-5554 shell input tap 540 850"
}

@test "hold-label issues DOWN/sleep/UP at the matched node's center" {
  run_emu hold-label Settings 500
  [ "$status" -eq 0 ]
  # Settings bounds=[900,100][1000,200] → center (950, 150) in device px.
  assert_called "adb -s emulator-5554 shell input motionevent DOWN 950 150"
  assert_called "sleep 0.500"
  assert_called "adb -s emulator-5554 shell input motionevent UP 950 150"
}

@test "hold-label defaults to 800ms when duration is omitted" {
  run_emu hold-label Settings
  [ "$status" -eq 0 ]
  assert_called "sleep 0.800"
}

@test "tap-label dies when the label has no match" {
  run_emu tap-label NoSuchButton
  [ "$status" -ne 0 ]
  [[ "$output" == *"no UI node matching"* ]]
}
