#!/usr/bin/env python3
"""M6 ratio/speed regression tracking (PROJECT_PLAN.md).

Packs a fixed set of test programs - the two existing FS-UAE e2e
programs (tests/uae/e2e/program.s, tests/uae/e2e_large's generated
prose program) plus every tests/corpus/gen_corpus.py item - with every
backend, and compares the resulting sizes against a committed baseline
(baseline.json, next to this script).

Unlike tests/uae/*, this needs no FS-UAE and no Kickstart ROM (it only
measures `execram pack`'s own output size and wall-clock time, not
whether the result boots correctly - that's what the FS-UAE tests are
for), so it runs in CI (.github/workflows/ci.yml) as well as locally.

A backend's output *growing* for any program versus the baseline is
treated as a regression and fails the run. A backend's output
*shrinking* is reported but not treated as a failure - compressor
improvements are always welcome and shouldn't need a baseline edit
just to keep CI green. Any change (bigger or smaller) is printed either
way, so it's never silent.

Usage:
  track_ratios.py <execram-binary> <vasm> <vlink> [--update-baseline]

--update-baseline overwrites baseline.json with the sizes just measured
(after printing the same comparison report against the *old* baseline)
- use this deliberately, after reviewing the report, not as a way to
silence a real regression.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
BASELINE_PATH = os.path.join(SCRIPT_DIR, "baseline.json")

BACKENDS = ["store", "inflate", "zultra", "zx0", "salvador", "shrinkler"]


def run(cmd, **kwargs):
    # No capture_output: let vasm/vlink/execram's own stdout/stderr flow
    # straight through to the console/CI log as it happens, so a
    # failure here is debuggable from the log directly rather than
    # needing to dig `.stdout`/`.stderr` out of a swallowed exception.
    return subprocess.run(cmd, check=True, **kwargs)


def build_test_programs(work_dir: str, vasm: str, vlink: str) -> dict[str, str]:
    """Returns {program_name: path to a linked hunk executable}."""
    programs = {}

    def link(name: str, src_path: str):
        obj = os.path.join(work_dir, f"{name}.o")
        exe = os.path.join(work_dir, f"{name}.exe")
        run([vasm, "-Fhunk", "-no-opt", "-quiet", "-o", obj, src_path])
        run([vlink, "-bamigahunk", "-o", exe, obj])
        programs[name] = exe

    # The small e2e program - static, not generated.
    link("small", os.path.join(REPO_ROOT, "tests", "uae", "e2e", "program.s"))

    # The large e2e program - same generator run_large_e2e_test.sh uses.
    large_s = os.path.join(work_dir, "large.s")
    large_expected = os.path.join(work_dir, "large.expected")
    run([sys.executable, os.path.join(REPO_ROOT, "tests", "uae", "e2e_large", "gen_large_program.py"), large_s, large_expected])
    link("large", large_s)

    # Every tests/corpus/gen_corpus.py item.
    corpus_dir = os.path.join(work_dir, "corpus")
    run([sys.executable, os.path.join(REPO_ROOT, "tests", "corpus", "gen_corpus.py"), corpus_dir])
    for entry in sorted(os.listdir(corpus_dir)):
        if entry.endswith(".s"):
            name = entry[: -len(".s")]
            link(f"corpus_{name}", os.path.join(corpus_dir, entry))

    # Real (not generator-produced) executables checked directly into
    # tests/corpus/ - already-linked hunk files, so no vasm/vlink step
    # needed, just reference them where they sit.
    for entry in sorted(os.listdir(os.path.join(REPO_ROOT, "tests", "corpus"))):
        if entry.endswith(".exe"):
            name = entry[: -len(".exe")]
            programs[f"corpus_{name}"] = os.path.join(REPO_ROOT, "tests", "corpus", entry)

    return programs


def measure(execram: str, programs: dict[str, str], work_dir: str) -> dict[str, dict[str, dict]]:
    """Returns {program: {backend: {"size": int, "seconds": float}}}."""
    results: dict[str, dict[str, dict]] = {}
    for name, exe_path in programs.items():
        results[name] = {}
        for backend in BACKENDS:
            out_path = os.path.join(work_dir, f"{name}_{backend}.packed")
            start = time.monotonic()
            run([execram, "pack", f"--backend={backend}", exe_path, out_path])
            elapsed = time.monotonic() - start
            size = os.path.getsize(out_path)
            results[name][backend] = {"size": size, "seconds": round(elapsed, 3)}
    return results


def load_baseline() -> dict:
    if not os.path.exists(BASELINE_PATH):
        return {}
    with open(BASELINE_PATH) as f:
        return json.load(f)


def save_baseline(data: dict):
    with open(BASELINE_PATH, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    execram, vasm, vlink = sys.argv[1:4]
    update_baseline = len(sys.argv) == 5 and sys.argv[4] == "--update-baseline"

    baseline = load_baseline()

    with tempfile.TemporaryDirectory() as work_dir:
        programs = build_test_programs(work_dir, vasm, vlink)
        current = measure(execram, programs, work_dir)

    regressed = False
    print(f"{'program':<24}{'backend':<12}{'baseline':>10}{'current':>10}{'delta':>10}  status")
    for name in sorted(current):
        for backend in BACKENDS:
            cur = current[name][backend]["size"]
            base = baseline.get(name, {}).get(backend, {}).get("size")
            if base is None:
                status = "NEW (no baseline yet)"
            elif cur > base:
                status = "REGRESSION"
                regressed = True
            elif cur < base:
                status = "improved"
            else:
                status = "unchanged"
            base_str = str(base) if base is not None else "-"
            delta_str = str(cur - base) if base is not None else "-"
            print(f"{name:<24}{backend:<12}{base_str:>10}{cur:>10}{delta_str:>10}  {status}")

    if update_baseline:
        save_baseline(current)
        print(f"\nWrote {BASELINE_PATH}")
        return 0

    if regressed:
        print("\nFAIL: at least one backend's output grew relative to the committed baseline.", file=sys.stderr)
        print("If this is an intentional, reviewed change, rerun with --update-baseline.", file=sys.stderr)
        return 1

    if not baseline:
        print("\nNo baseline.json found - nothing to compare against yet. Run with --update-baseline to create one.", file=sys.stderr)
        return 1

    print("\nPASS: no backend's output grew relative to the committed baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
