#!/usr/bin/env bats
# Tests for the case-statement dispatch in emu.sh: input commands, app
# control, lifecycle. Each test runs emu.sh as a subprocess and inspects
# $STUB_LOG to confirm the script invoked adb / nc / sips with the right args.

load helpers

setup()    { emu_setup; }
teardown() { emu_teardown; }

# --- tap / swipe / hold ------------------------------------------------------

@test "tap scales screenshot coords to device pixels and calls adb input tap" {
  run_emu tap 180 200
  [ "$status" -eq 0 ]
  # 180 screenshot px → 540 device px on a 1080-wide device, same scale on Y.
  assert_called "adb -s emulator-5554 shell input tap 540 600"
}

@test "tap fails with usage when given fewer than 2 args" {
  run_emu tap 100
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "swipe defaults to 300ms when duration is omitted" {
  run_emu swipe 10 20 30 40
  [ "$status" -eq 0 ]
  assert_called "adb -s emulator-5554 shell input swipe 30 60 90 120 300"
}

@test "swipe accepts an explicit duration" {
  run_emu swipe 10 20 30 40 750
  [ "$status" -eq 0 ]
  assert_called "adb -s emulator-5554 shell input swipe 30 60 90 120 750"
}

@test "swipe fails with usage when fewer than 4 args" {
  run_emu swipe 10 20 30
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "hold sends DOWN, sleeps the requested ms, then sends UP" {
  run_emu hold 100 200 800
  [ "$status" -eq 0 ]
  assert_called "adb -s emulator-5554 shell input motionevent DOWN 300 600"
  assert_called "sleep 0.800"
  assert_called "adb -s emulator-5554 shell input motionevent UP 300 600"

  # Order check: DOWN must precede UP in the call log.
  local down_line up_line
  down_line=$(grep -n 'motionevent DOWN' "$STUB_LOG" | head -1 | cut -d: -f1)
  up_line=$(grep -n 'motionevent UP' "$STUB_LOG" | head -1 | cut -d: -f1)
  [ "$down_line" -lt "$up_line" ]
}

@test "hold defaults to 800ms when duration is omitted" {
  run_emu hold 100 200
  [ "$status" -eq 0 ]
  assert_called "sleep 0.800"
}

# --- pinch -------------------------------------------------------------------

@test "pinch fails when direction is neither 'in' nor 'out'" {
  run_emu pinch sideways
  [ "$status" -ne 0 ]
  [[ "$output" == *"direction must be"* ]]
}

@test "pinch out routes events through the qemu console (nc)" {
  run_emu pinch out
  [ "$status" -eq 0 ]
  assert_called "nc -w 5 localhost 5554"
  # The auth token line is what emu_console prepends.
  grep -F 'auth fake-token' "$STUB_LOG" >/dev/null
  # 20 incremental motion frames plus DOWN/UP framing — sanity check.
  [ "$(grep -c 'event send' "$STUB_LOG")" -ge 20 ]
}

# --- launch / stop / app-running / kill-run ----------------------------------

@test "launch invokes monkey with the detected applicationId" {
  ANDROID_EMU_PKG=com.example.demo run_emu launch
  [ "$status" -eq 0 ]
  assert_called "monkey -p com.example.demo"
}

@test "stop invokes 'am force-stop' with the detected applicationId" {
  ANDROID_EMU_PKG=com.example.demo run_emu stop
  [ "$status" -eq 0 ]
  assert_called "am force-stop com.example.demo"
}

@test "app-running greps dumpsys output for the focused package" {
  STUB_ADB_FG_PKG=com.example.demo ANDROID_EMU_PKG=com.example.demo run_emu app-running
  [ "$status" -eq 0 ]
}

@test "app-running exits 1 when a different app is foregrounded" {
  STUB_ADB_FG_PKG=com.other ANDROID_EMU_PKG=com.example.demo run_emu app-running
  [ "$status" -ne 0 ]
}

@test "kill-run runs pkill and force-stops the app" {
  ANDROID_EMU_PKG=com.example.demo run_emu kill-run
  [ "$status" -eq 0 ]
  assert_called "pkill -f"
  assert_called "am force-stop com.example.demo"
}

# --- screenshot --------------------------------------------------------------

@test "screenshot pipes screencap into sips and prints the resized path" {
  run_emu screenshot
  [ "$status" -eq 0 ]
  assert_called "screencap -p"
  assert_called "sips --resampleWidth 360"
  # Output is the path to the resized JPEG.
  [[ "$output" == *"$TEST_TMP/android-emu-shot-bats.jpg"* ]]
}

# --- read-only inspection commands ------------------------------------------

@test "devices proxies to 'adb devices'" {
  run_emu devices
  [ "$status" -eq 0 ]
  [[ "$output" == *"emulator-5554"* ]]
}

@test "size queries adb shell wm size" {
  run_emu size
  [ "$status" -eq 0 ]
  [[ "$output" == *"Physical size: 1080x2400"* ]]
}

@test "foreground extracts mFocusedApp from dumpsys" {
  run_emu foreground
  [ "$status" -eq 0 ]
  [[ "$output" == *"mFocusedApp"* ]]
}

# --- wait-run ----------------------------------------------------------------

@test "wait-run exits 0 when flutter reports the app attached" {
  echo "Flutter run key commands." > "$TEST_TMP/android-emu-flutter.log"
  run_emu wait-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"flutter run attached"* ]]
}

@test "wait-run exits 1 and prints the error line on Gradle failure" {
  printf 'building...\nGradle build failed: oh no\n' > "$TEST_TMP/android-emu-flutter.log"
  run_emu wait-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Gradle build failed"* ]]
}

# --- log ---------------------------------------------------------------------

@test "log tails the flutter daemon log with a default of 50 lines" {
  for i in $(seq 1 100); do echo "line $i"; done > "$TEST_TMP/android-emu-flutter.log"
  run_emu log
  [ "$status" -eq 0 ]
  [[ "$output" == *"line 100"* ]]
  [[ "$output" != *"line 50"* ]]      # 50 lines means lines 51..100
  [[ "$output" == *"line 51"* ]]
}

@test "log respects a custom line count argument" {
  for i in $(seq 1 100); do echo "line $i"; done > "$TEST_TMP/android-emu-flutter.log"
  run_emu log 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"line 96"* ]]
  [[ "$output" != *"line 95"* ]]
}
