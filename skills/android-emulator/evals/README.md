# Evals for `android-emulator`

Behavior eval suite for the android-emulator skill, following the pattern in https://agentskills.io/skill-creation/evaluating-skills.

## What's here

- [`evals.json`](evals.json) — test cases the skill should pass. Each one has a realistic user prompt, a description of what success looks like, and a list of assertions a grader can verify against the agent's transcript.

Run outputs (`outputs/`, `timing.json`, `grading.json`, `benchmark.json`) are produced by the runner and live in a sibling workspace directory (`android-emulator-workspace/iteration-N/`), intentionally outside the skill itself so generated artifacts don't leak into the published bundle.

## What each test case covers

| id | What it stress-tests |
|---|---|
| `launch-and-discover-ui` | Cold-boot happy path. `boot` → `run` paired with `wait-run` (not `sleep`). Defaults to `ui-list` over `screenshot`. |
| `tap-by-label-not-coords` | Preferred input path: `tap-label` over coordinate `tap`, with substring match against multi-line labels. |
| `long-press-not-fake-swipe` | Gotcha: agent uses `hold`/`hold-label` instead of faking long-press with same-coord `swipe` (Flutter treats that as a cancelled tap). |
| `multi-touch-pinch-via-qemu` | Gotcha: agent uses the `pinch` command (qemu console) rather than trying to script multi-touch via adb. |
| `stop-flutter-cleanly` | Gotcha: agent stops the backgrounded daemon with `kill-run`, not `TaskStop`. |
| `diagnose-empty-semantics` | Gotcha: when `ui-list` is empty, agent fixes the *app* (`ensureSemantics()` / `Semantics(label:)`), not the workflow (coordinate-guessing). |
| `screenshot-uses-printed-path` | Concurrency gotcha: agent reads the per-invocation JPEG path the script printed, not the bare `/tmp/android-emu-shot.jpg`. |

## Environment requirements

Most evals need a working device under the agent's control:

- Android SDK with `adb` and `emulator` on `$PATH` (or in `~/Library/Android/sdk/` / `~/Android/Sdk/`).
- At least one AVD created (e.g. `Pixel_6_API_34`).
- Flutter (or [`fvm`](https://fvm.app/)) installed.
- macOS for `sips` (the screenshot resampler).
- A Flutter project to point the skill at — the skill walks up from `$PWD` looking for `pubspec.yaml`.

`diagnose-empty-semantics` is purely diagnostic and needs no live device — the prompt itself supplies the simulated `ui-list` output.

The runner is responsible for the test environment, not the skill. Eval prompts mirror what a real user would type, so the agent must detect missing prerequisites itself.

## Running the suite

The eval format is compatible with [`skill-creator`](https://github.com/anthropics/skills/tree/main/skills/skill-creator), which is the recommended runner — it spawns a fresh subagent per test case (clean context, no leftover state), captures `outputs/` + `timing.json`, grades each assertion, and writes the aggregated `benchmark.json`.

High-level loop, per [the eval doc](https://agentskills.io/skill-creation/evaluating-skills#running-evals):

1. **Snapshot the current skill** so the baseline run uses the version on disk today, not a moving target:
   ```bash
   mkdir -p skills/android-emulator-workspace
   cp -r skills/android-emulator skills/android-emulator-workspace/skill-snapshot
   ```
2. **For each test case in `evals.json`, spawn two runs**, each in its own clean subagent context:
   - `with_skill/` — skill installed, current HEAD version.
   - `without_skill/` (or `old_skill/` if comparing against the snapshot) — same prompt, no skill (or the snapshot).
3. **Save outputs** to `skills/android-emulator-workspace/iteration-N/<eval-id>/{with_skill,without_skill}/outputs/` plus `timing.json` (token count + duration).
4. **Grade** by checking each assertion against the transcript and producing `grading.json` per the doc's schema.
5. **Aggregate** into `iteration-N/benchmark.json` (mean pass rate, time, tokens, and the with-vs-without delta).
6. **Review** any always-pass / always-fail / high-stddev assertions and update `evals.json` for iteration N+1.

If you don't have skill-creator handy, the same loop runs by hand — fire two `claude -p` (or equivalent SDK) invocations per test case, one with the skill installed and one with `--no-plugins` (or whatever your harness's "no skills" flag is), then grade their transcripts against the assertion list.

## When to re-run

**Re-running matters most when you change:**

- `SKILL.md` body — command lists, gotchas, decision rules ("default to ui-list", "always pair run with wait-run", etc.).
- Any subcommand in `scripts/emu.sh` that an eval references (`boot`, `run`, `wait-run`, `screenshot`, `ui-list`, `tap-label`, `hold`, `hold-label`, `pinch`, `kill-run`, `exit`).
- Auto-detection logic, env-var defaults, or default flags — these change what the agent's first invocation looks like.

For doc-only edits to ancillary files, a re-run is rarely worth it.

### For AI agents modifying this skill

Do **not** run the suite on your own — ask the developer first. A one-sentence prompt is enough, e.g.:

> *"This change touches the android-emulator skill, which has an eval suite. Want me to run `skills/android-emulator/evals/` to check for regressions? It needs an Android emulator + AVD + a Flutter project on macOS, and spawns two subagent runs per test case (~14 runs total) so token cost is non-trivial."*

If the developer says yes, run the suite and attach `iteration-N/benchmark.json` (with an honest note on any regressed assertions) to the PR description. If they say no, just mention in the PR that the suite was skipped so reviewers know.

## Iterating on the suite

Per [the eval doc](https://agentskills.io/skill-creation/evaluating-skills#analyzing-patterns):

- **Always-pass-in-both assertions** are dead weight — the model handles them without help. Strengthen or drop.
- **Always-fail assertions** are either broken or genuinely uncovered by the skill. Decide which, then fix the assertion or the skill.
- **High-stddev assertions** point to ambiguity in `SKILL.md` — tighten the relevant instruction.
- **Pass-with-skill, fail-without** is where the skill is earning its keep — keep, and consider whether the same lesson applies to a related case worth adding.

Drop new findings into `iteration-N+1/` and repeat. Stop when feedback is consistently empty or improvements have plateaued.
