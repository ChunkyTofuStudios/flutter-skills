#!/usr/bin/env bats
# Tests for help output, unknown-command behavior, and a couple of cross-cutting
# safety properties (e.g. no command silently swallows missing args).

load helpers

setup()    { emu_setup; }
teardown() { emu_teardown; }

@test "help command prints the section headers from the usage block" {
  run_emu help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Emulator lifecycle:"* ]]
  [[ "$output" == *"App control:"* ]]
  [[ "$output" == *"Input"* ]]
  [[ "$output" == *"Label-based input"* ]]
  [[ "$output" == *"Auto-detection:"* ]]
  [[ "$output" == *"Env:"* ]]
}

@test "no arguments falls through to help" {
  run_emu
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: scripts/emu.sh"* ]]
}

@test "an unknown command falls through to help" {
  run_emu zxcv-not-a-command
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: scripts/emu.sh"* ]]
}

@test "help documents the ANDROID_EMU_TMP_DIR override" {
  run_emu help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANDROID_EMU_TMP_DIR"* ]]
}

@test "every input command rejects missing args with a 'usage:' message" {
  for cmd in tap hold swipe pinch ui-find tap-label hold-label; do
    run_emu "$cmd"
    [ "$status" -ne 0 ] || { echo "$cmd unexpectedly succeeded with no args"; return 1; }
    [[ "$output" == *"usage:"* ]] || { echo "$cmd missing 'usage:' in output: $output"; return 1; }
  done
}
