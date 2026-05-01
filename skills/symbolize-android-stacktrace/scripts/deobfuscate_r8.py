#!/usr/bin/env python3
"""Bulk R8 mapping.txt deobfuscator.

Reads obfuscated `<class>.<method>` references (one per line) from stdin,
writes one TSV row per query — `<query>\\t<deobfuscated>` — to stdout. An
empty deobfuscated value means the class wasn't in the mapping (the caller
should treat that as "leave the original name as-is").

Designed to be invoked once per trace: parses the mapping file once into an
in-memory index, then streams answers. The companion bash symbolizer
collects every Java reference up front so this process is spawned at most
once regardless of how many frames the trace has.

Usage:
    deobfuscate_r8.py <mapping.txt>      # reads stdin, writes stdout

Mapping file format (R8 / ProGuard):
    io.flutter.embedding.engine.FlutterJNI -> j$.a.a.a.a.b:
        1:1:void onSurfaceDestroyed():123:123 -> l
        void onSurfaceCreated(android.view.Surface) -> a

Method overloads with the same obfuscated short name collapse to the first
original we see — disambiguating further would require the runtime PC's
source-line offset, which Play Console traces don't ship.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# `OriginalClass -> ObfuscatedClass:` — class header, no leading whitespace.
CLASS_HEADER_RE = re.compile(r"^([\w.$]+) -> ([\w.$]+):\s*$")
# `   <return_type_and_signature_and_optional_line_ranges> -> <obfuscated_name>`
# We don't need to parse the signature precisely; just split on the
# unambiguous ` -> ` separator and pick out the method name from the LHS.
METHOD_LINE_RE = re.compile(r"^\s+(.+?)\s+->\s+([\w$<>]+)\s*$")

# Defensive caps so a malicious or corrupt mapping.txt can't OOM the parser.
# Real mapping files for very large Android apps top out around 100–200 MB and
# have lines well under 1 KB; the limits below are an order of magnitude more
# than that so legitimate inputs are never rejected. The file-size cap is the
# load-bearing one — it bounds total memory the parser can consume. The
# per-line cap is defence-in-depth: it skips pathological single lines (e.g.
# a 1 GB blob with no newlines smuggled into a real-looking mapping) without
# aborting the whole job.
MAX_MAPPING_FILE_BYTES = 1 * 1024 * 1024 * 1024  # 1 GiB
MAX_MAPPING_LINE_BYTES = 64 * 1024  # 64 KiB


def parse_mapping(path: Path) -> dict[str, tuple[str, dict[str, str]]]:
    """Parse `mapping.txt` into `{obf_class: (orig_class, {obf_method: orig_method})}`.

    `mapping.txt` is treated as untrusted input — it's pulled from CI and the
    user's build pipeline, but neither this script nor the caller validates
    its provenance per byte. The parser is purely line-oriented, never evals,
    execs, or imports based on its contents, and never feeds any field into
    a filesystem path. Size limits guard against denial-of-service from a
    pathologically large file.
    """
    try:
        size = path.stat().st_size
    except OSError as e:
        print(f"cannot stat {path}: {e}", file=sys.stderr)
        sys.exit(1)
    if size > MAX_MAPPING_FILE_BYTES:
        print(
            f"mapping file too large ({size} bytes > "
            f"{MAX_MAPPING_FILE_BYTES} byte cap)",
            file=sys.stderr,
        )
        sys.exit(1)

    out: dict[str, tuple[str, dict[str, str]]] = {}
    cur_obf: str | None = None
    cur_orig: str | None = None
    cur_methods: dict[str, str] = {}

    def flush() -> None:
        if cur_obf is not None and cur_orig is not None:
            out[cur_obf] = (cur_orig, cur_methods)

    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            if len(line) > MAX_MAPPING_LINE_BYTES:
                # Skip pathological lines without aborting; legitimate mapping
                # entries are well under this cap.
                continue
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if (m := CLASS_HEADER_RE.match(line)) is not None:
                flush()
                cur_orig, cur_obf = m.group(1), m.group(2)
                cur_methods = {}
                continue
            if cur_obf is None:
                continue
            if (mm := METHOD_LINE_RE.match(line)) is not None:
                spec = mm.group(1)
                obf_method = mm.group(2)
                # Field lines (e.g. `int foo -> a`) have no `(`. Stack frames
                # only reference methods, so skip fields entirely.
                if "(" not in spec:
                    continue
                # Method name is the last whitespace-separated token before `(`,
                # then the segment after the final `.` of that token. R8
                # sometimes emits fully-qualified method specs for synthesized
                # lambdas (e.g. `void e8.Foo$$Lambda0.run()`), and we want only
                # `run` — the dotted prefix is metadata about origin, not part
                # of the method name in the *obfuscated* class.
                # Examples: `void onSurfaceDestroyed(...)` -> `onSurfaceDestroyed`,
                #           `1:1:void <init>(...):52:52`     -> `<init>`,
                #           `void e8.Foo$$Lambda0.run()`     -> `run`.
                orig_method = spec.split("(", 1)[0].split()[-1].rsplit(".", 1)[-1]
                cur_methods.setdefault(obf_method, orig_method)
        flush()
    return out


def deobfuscate(table: dict[str, tuple[str, dict[str, str]]], query: str) -> str:
    """Return `<orig_class>.<orig_method>` or '' if `query`'s class isn't mapped."""
    if "." not in query:
        return ""
    cls, method = query.rsplit(".", 1)
    entry = table.get(cls)
    if entry is None:
        return ""
    orig_cls, methods = entry
    # Fallback to the input method name if the obfuscated short name isn't in
    # the per-class table — common for inherited / synthetic methods that R8
    # doesn't rewrite. The class-level rename still gives useful info.
    orig_method = methods.get(method, method)
    return f"{orig_cls}.{orig_method}"


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: deobfuscate_r8.py <mapping.txt>", file=sys.stderr)
        sys.exit(1)
    table = parse_mapping(Path(sys.argv[1]))
    for line in sys.stdin:
        query = line.strip()
        if not query:
            continue
        print(f"{query}\t{deobfuscate(table, query)}")


if __name__ == "__main__":
    main()
