#!/usr/bin/env bats
# Unit tests for the pure helper functions inside emu.sh.
# These source the script and call the functions directly — no subprocess.

load helpers

setup()    { emu_setup; source_emu; }
teardown() { emu_teardown; }

# --- detect_pkg --------------------------------------------------------------

@test "detect_pkg parses applicationId from build.gradle" {
  local root; root=$(make_flutter_project foo gradle com.example.foo)
  cd "$root"
  run detect_pkg
  [ "$status" -eq 0 ]
  [ "$output" = "com.example.foo" ]
}

@test "detect_pkg parses applicationId from build.gradle.kts" {
  local root; root=$(make_flutter_project bar kts com.example.bar)
  cd "$root"
  run detect_pkg
  [ "$status" -eq 0 ]
  [ "$output" = "com.example.bar" ]
}

@test "detect_pkg returns 1 when no gradle file is present" {
  local root; root=$(make_flutter_project baz none unused)
  cd "$root"
  run detect_pkg
  [ "$status" -ne 0 ]
}

@test "detect_pkg picks the first applicationId when multiple flavors are defined" {
  local root; root=$(make_flutter_project multi gradle com.example.first)
  printf '\n  productFlavors {\n    pro {\n      applicationId "com.example.second"\n    }\n  }\n' \
    >> "$root/android/app/build.gradle"
  cd "$root"
  run detect_pkg
  [ "$status" -eq 0 ]
  [ "$output" = "com.example.first" ]
}

# --- project_root ------------------------------------------------------------

@test "project_root finds pubspec.yaml in the current directory" {
  local root; root=$(make_flutter_project p1 gradle com.x.y)
  cd "$root"
  run project_root
  [ "$status" -eq 0 ]
  [ "$output" = "$root" ]
}

@test "project_root walks up from a nested subdirectory" {
  local root; root=$(make_flutter_project p2 gradle com.x.y)
  mkdir -p "$root/lib/feature/sub"
  cd "$root/lib/feature/sub"
  run project_root
  [ "$status" -eq 0 ]
  [ "$output" = "$root" ]
}

@test "project_root returns 1 when no pubspec.yaml is found" {
  cd "$TEST_TMP"
  run project_root
  [ "$status" -ne 0 ]
}

@test "project_root honors ANDROID_EMU_PROJECT_ROOT override" {
  ANDROID_EMU_PROJECT_ROOT="/tmp/explicit/path" run project_root
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/explicit/path" ]
}

# --- flutter_cmd -------------------------------------------------------------

@test "flutter_cmd returns 'flutter' when no .fvm directory is present" {
  local root; root=$(make_flutter_project f1 gradle com.x.y)
  cd "$root"
  run flutter_cmd
  [ "$status" -eq 0 ]
  [ "$output" = "flutter" ]
}

@test "flutter_cmd returns 'fvm flutter' when .fvm/ exists and fvm is on PATH" {
  local root; root=$(make_flutter_project f2 gradle com.x.y)
  mkdir "$root/.fvm"
  cd "$root"
  run flutter_cmd
  [ "$status" -eq 0 ]
  [ "$output" = "fvm flutter" ]
}

@test "flutter_cmd falls back to 'flutter' when .fvm/ exists but fvm is not on PATH" {
  local root; root=$(make_flutter_project f3 gradle com.x.y)
  mkdir "$root/.fvm"
  cd "$root"
  # Drop the stubs dir from PATH so `command -v fvm` fails.
  PATH="/usr/bin:/bin" run flutter_cmd
  [ "$status" -eq 0 ]
  [ "$output" = "flutter" ]
}

@test "flutter_cmd honors ANDROID_EMU_FLUTTER_CMD override" {
  ANDROID_EMU_FLUTTER_CMD="/opt/myflutter/bin/flutter" run flutter_cmd
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/myflutter/bin/flutter" ]
}

# --- to_dev (coordinate scaling) --------------------------------------------

@test "to_dev scales screenshot coords to device pixels (1080-wide device)" {
  # SHOT_WIDTH is 360 in emu.sh; size cache pre-seeded to 1080 in emu_setup.
  run to_dev 180
  [ "$status" -eq 0 ]
  [ "$output" = "540" ]
}

@test "to_dev scales 0 to 0" {
  run to_dev 0
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "to_dev scales using cached device size on a different resolution" {
  echo "720 1600" > "$TEST_TMP/android-emu-device-size"
  # 360 screenshot px → 720 device px (2x scale)
  run to_dev 100
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}
