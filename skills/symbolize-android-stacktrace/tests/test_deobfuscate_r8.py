"""Unit tests for deobfuscate_r8.py.

Stdlib-only — same convention as test_codemagic_fetch.py. Run via:

    python3 -m unittest discover \\
        -s skills/symbolize-android-stacktrace/tests -p 'test_*.py'

`tools/run-tests.sh` discovers these alongside the bats suites.
"""

from __future__ import annotations

import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

# Make the bundled script importable as a module for direct function tests.
SCRIPT_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

import deobfuscate_r8 as dr  # noqa: E402


def _write(content: str) -> Path:
    """Write `content` (de-dented) to a temp file and return the path."""
    f = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    f.write(textwrap.dedent(content).lstrip("\n"))
    f.close()
    return Path(f.name)


class ParseMappingTests(unittest.TestCase):
    def test_basic_class_and_method_mapping(self) -> None:
        path = _write("""
            io.flutter.embedding.engine.FlutterJNI -> Ka.n:
                1:1:void onSurfaceDestroyed():123:123 -> l
                void onSurfaceCreated(android.view.Surface) -> a
        """)
        self.addCleanup(path.unlink)
        table = dr.parse_mapping(path)
        self.assertIn("Ka.n", table)
        orig_cls, methods = table["Ka.n"]
        self.assertEqual(orig_cls, "io.flutter.embedding.engine.FlutterJNI")
        self.assertEqual(methods["l"], "onSurfaceDestroyed")
        self.assertEqual(methods["a"], "onSurfaceCreated")

    def test_inner_classes_use_dollar_sign(self) -> None:
        path = _write("""
            io.flutter.engine.FlutterJNI$Inner -> Ka.n$a:
                1:1:void surfaceDestroyed() -> b
        """)
        self.addCleanup(path.unlink)
        table = dr.parse_mapping(path)
        self.assertIn("Ka.n$a", table)
        self.assertEqual(table["Ka.n$a"][0], "io.flutter.engine.FlutterJNI$Inner")

    def test_field_lines_are_skipped(self) -> None:
        # Field lines have no `(`. Stack frames only reference methods, so the
        # parser must not produce a method entry for them.
        path = _write("""
            com.example.Foo -> a.b:
                int someField -> f
                java.lang.String message -> g
                1:1:void doThing():10:10 -> h
        """)
        self.addCleanup(path.unlink)
        table = dr.parse_mapping(path)
        _, methods = table["a.b"]
        self.assertNotIn("f", methods)
        self.assertNotIn("g", methods)
        self.assertEqual(methods["h"], "doThing")

    def test_comments_and_blank_lines_are_ignored(self) -> None:
        path = _write("""
            # preamble comment
            # another
            io.example.A -> X:

                # this is a method comment
                1:1:void m():1:1 -> a

            io.example.B -> Y:
                void n() -> b
        """)
        self.addCleanup(path.unlink)
        table = dr.parse_mapping(path)
        self.assertEqual(set(table), {"X", "Y"})
        self.assertEqual(table["X"][1]["a"], "m")
        self.assertEqual(table["Y"][1]["b"], "n")

    def test_overload_collapse_keeps_first_seen(self) -> None:
        # Two methods share the obfuscated short name `a`. Without source-line
        # info we can't disambiguate, so we keep the first.
        path = _write("""
            com.example.Overload -> O:
                1:1:void send(int):1:1 -> a
                1:1:void send(java.lang.String):2:2 -> a
        """)
        self.addCleanup(path.unlink)
        _, methods = dr.parse_mapping(path)["O"]
        self.assertEqual(methods["a"], "send")  # name is the same, just one entry

    def test_method_name_is_extracted_correctly_when_signature_has_qualifiers(self) -> None:
        # Real R8 mappings prefix method specs with optional `<obf_line>:<obf_line>:`,
        # then `<return_type> <name>(<args>):<orig_line>:<orig_line>`.
        path = _write("""
            com.example.X -> X:
                1:1:int <init>(java.lang.String,java.util.List<java.lang.Integer>):42:42 -> <init>
        """)
        self.addCleanup(path.unlink)
        _, methods = dr.parse_mapping(path)["X"]
        self.assertEqual(methods["<init>"], "<init>")

    def test_synthetic_lambda_dotted_method_name_drops_origin_prefix(self) -> None:
        # R8 emits fully-qualified method specs for synthesized lambdas, e.g.
        # `void e8.CustomThreadFactory$$ExternalSyntheticLambda0.run()`. The
        # obfuscated class already names the host class — the method name in
        # the trace is just `run`, not the dotted origin.
        path = _write("""
            com.google.firebase.concurrent.CustomThreadFactory$$ExternalSyntheticLambda0 -> e8.a:
                1:8:void e8.CustomThreadFactory$$ExternalSyntheticLambda0.run():0:0 -> run
        """)
        self.addCleanup(path.unlink)
        _, methods = dr.parse_mapping(path)["e8.a"]
        self.assertEqual(methods["run"], "run")


class DeobfuscateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.table = {
            "Ka.n": ("io.flutter.embedding.engine.FlutterJNI", {
                "l": "onSurfaceDestroyed",
                "a": "onSurfaceCreated",
            }),
            "Ka.n$a": ("io.flutter.embedding.engine.FlutterJNI$Inner", {
                "surfaceDestroyed": "surfaceDestroyed",
            }),
        }

    def test_class_and_method_mapped(self) -> None:
        self.assertEqual(
            dr.deobfuscate(self.table, "Ka.n.l"),
            "io.flutter.embedding.engine.FlutterJNI.onSurfaceDestroyed",
        )

    def test_class_mapped_method_unmapped_falls_back_to_obfuscated_method(self) -> None:
        # The class header tells us the original FQN; the method name might
        # still be useful (e.g. inherited from a kept superclass), so we
        # render the original class with the obfuscated method name rather
        # than failing the whole lookup.
        self.assertEqual(
            dr.deobfuscate(self.table, "Ka.n.UNKNOWN"),
            "io.flutter.embedding.engine.FlutterJNI.UNKNOWN",
        )

    def test_class_not_mapped_returns_empty(self) -> None:
        self.assertEqual(dr.deobfuscate(self.table, "com.notmapped.Foo.bar"), "")

    def test_query_with_no_dot_returns_empty(self) -> None:
        # No way to split into class + method.
        self.assertEqual(dr.deobfuscate(self.table, "single_token"), "")

    def test_inner_class_method_resolves(self) -> None:
        self.assertEqual(
            dr.deobfuscate(self.table, "Ka.n$a.surfaceDestroyed"),
            "io.flutter.embedding.engine.FlutterJNI$Inner.surfaceDestroyed",
        )


if __name__ == "__main__":
    unittest.main()
