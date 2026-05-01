#!/usr/bin/env bats
# Regression test: shell metacharacters that arrive via the trace file or
# mapping.txt must never be executed. They should round-trip through the
# symbolizer as literal text.

load helpers

setup()    { sym_setup; }
teardown() { sym_teardown; }

@test "shell metacharacters in trace frames are not interpreted as commands" {
  canary_dir="$TEST_TMP/canaries"
  mkdir -p "$canary_dir"

  trace="$TEST_TMP/metachars.log"
  # Each frame embeds an expression that, IF the symbolizer ever fed line
  # contents through `eval` or an unquoted command, would create one of the
  # canary files below. The format strings are single-quoted so bash itself
  # doesn't expand them at fixture-write time — only %s substitutes the
  # canary path.
  {
    printf '"main" tid=1 Native\n'
    printf '  #00  pc 0x000000000001cd644  /data/app/com.example/base.apk (Foo;touch %s+8)\n' \
      "$canary_dir/c1"
    printf '  #01  pc 0x000000000001cd4b0  /memfd:jit-cache (Bar&&touch %s+0)\n' \
      "$canary_dir/c2"
    printf '  #02  pc 0x0000000000380e22  /data/app/com.example/base.apk (Baz`touch %s`+12)\n' \
      "$canary_dir/c3"
    # Metachars in the bin_path field too. The `;` is part of the matched
    # `[^[:space:]]+` capture and would be a shell separator if the script
    # ever expanded the value unquoted.
    printf '  #03  pc 0x00000000000abcde  /data/app/inj;touch_%s/base.apk (Class.method+4)\n' \
      "$canary_dir/c4"
  } > "$trace"

  # Use a mapping.txt fixture whose entries reference one of the obfuscated
  # classes from above (Foo). This exercises the deobfuscation path so the
  # extracted refs flow through awk -v / python stdin.
  mapping="$TEST_TMP/mapping-meta.txt"
  {
    printf 'com.example.RealClass -> Foo:\n'
    printf '    1:1:void doIt():10:10 -> doIt\n'
  } > "$mapping"

  run_sym "$trace" "$SYM_FIXTURES_DIR/symbols" "$mapping"
  [ "$status" -eq 0 ]

  # The blast-radius check: if any canary was created, the symbolizer
  # executed embedded shell.
  [ ! -e "$canary_dir/c1" ]
  [ ! -e "$canary_dir/c2" ]
  [ ! -e "$canary_dir/c3" ]
  [ ! -e "$canary_dir/c4" ]

  # Output file exists and contains the literal frame text (metachars and
  # all). The script writes each input line to OUT_FILE verbatim, so the
  # bytes should round-trip.
  out="$TEST_TMP/metachars.symbolized.txt"
  [ -f "$out" ]
  grep -F 'Foo;touch' "$out"
  grep -F 'Bar&&touch' "$out"
  grep -F 'Baz`touch' "$out"
  grep -F '/data/app/inj;touch_' "$out"
}

@test "shell metacharacters in a mapping.txt method spec are not interpreted" {
  # If a malicious mapping.txt contains shell metacharacters in the original
  # method-spec LHS, the parser may extract them into the deobfuscated
  # output. That output is then echoed into a `[JAVA: ...]` annotation —
  # which must use the value as data, not as a shell expression.
  canary_dir="$TEST_TMP/canaries-mapping"
  mkdir -p "$canary_dir"

  trace="$TEST_TMP/mapping-meta-trace.log"
  {
    printf '"main" tid=1 Native\n'
    printf '  #00  pc 0x000000000001cd644  /data/app/com.example/base.apk (Ka.n.l+8)\n'
  } > "$trace"

  mapping="$TEST_TMP/mapping-rhs-meta.txt"
  # The class header & obfuscated names must conform to the parser's regex
  # (`[\w.$]+` etc.), but the original method spec on the LHS is captured
  # by `(.+?)` and only post-processed by string splits — never executed.
  {
    printf 'com.example.Pwned -> Ka.n:\n'
    printf '    1:1:void rm_rf$(touch %s)():10:10 -> l\n' "$canary_dir/cm1"
  } > "$mapping"

  run_sym "$trace" "$SYM_FIXTURES_DIR/symbols" "$mapping"
  [ "$status" -eq 0 ]

  [ ! -e "$canary_dir/cm1" ]
}
