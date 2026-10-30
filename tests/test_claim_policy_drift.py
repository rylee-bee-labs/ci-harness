"""The bash mirror and the rego policy must never disagree.

`scripts/verify-claim.sh` (commit-time, pure bash) and `policy/claims.rego`
(PR-time, conftest) carry the same claim patterns. For years that duplication
was held together by a comment saying "Patterns MUST match policy/claims.rego"
and nothing checked, which is why the two could drift in silence.

This test runs BOTH implementations over the same corpus and fails when they
return different verdicts. Editing one side without the other now fails CI.

Verdict classes compared: "deny", "warn", "pass".

Two roots, because this file serves two callers:

  * ci-harness itself, and any consumer that vendored the files -- default.
  * A consuming repo, via the reusable-claims-policy template. That job checks
    out ci-harness into a side directory and runs this file with
    CLAIMS_REPO_ROOT pointing at the CONSUMER's tree, so the comparison is
    between the canonical policy and the mirror the consumer actually ships.

conftest is required. It is installed by the `[pr-claims-verified]` CI job; the
workflow step that runs this file asserts conftest is on PATH first, so the
skip below cannot hide a missing binary in CI.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(
    os.environ.get("CLAIMS_REPO_ROOT", Path(__file__).resolve().parents[1])
).resolve()
VERIFY_CLAIM = REPO / "scripts" / "verify-claim.sh"
CLAIMS_REGO = Path(
    os.environ.get("CLAIMS_REGO_PATH", REPO / "policy" / "claims.rego")
)

CONFTEST = shutil.which("conftest")

needs_conftest = pytest.mark.skipif(
    CONFTEST is None,
    reason="conftest not on PATH; the claims.rego half cannot be checked",
)

# KNOWN GAP, recorded rather than papered over: "every job is green" and
# "the checks are passing" are genuine claims that neither rule catches.
# Catching them needs an optional is/are connector, which was measured
# against 60 real merged PRs and denied homelab describing its own merge
# policy ("this PR merges itself once every check is green"). Trading a
# real false positive for a real false negative is not worth it. If a
# future shape separates assertion from condition, close this.

# Cases that pin the widened rules. The expected verdict is asserted as well as
# the agreement, so this file fails loudly if BOTH sides drift the same way.
CORPUS = [
    # --- pre-existing v1 coverage, must keep working ---
    ("30 tests pass", "deny"),
    ("0 errors", "deny"),
    ("passed in 22.77s", "deny"),
    ("30 tests pass\n$ pytest\n30 passed", "pass"),
    ("30 tests pass\nVerify by running: pytest\n30 passed", "pass"),
    ("30 tests pass\n$ pytest", "deny"),  # command, no observed output
    ("30 tests pass\n$ <command>\n<output>", "deny"),  # placeholders
    # --- soft tier: warns, never blocks ---
    ("this should work", "warn"),
    ("the gate works correctly today", "warn"),
    # --- benign ---
    ("fix: typo", "pass"),
    ("fix typo in README", "pass"),
    ("", "pass"),
    # --- Rule 1: widened count nouns ---
    ("17 units, 0 missing, 0 unanchored", "deny"),
    ("0 vulnerabilities introduced by the branch", "deny"),
    ("13 of 28 repos visible via the API endpoint", "deny"),
    ("6 alerts dismissed", "deny"),
    ("3 adapters registered", "deny"),
    # --- Rule 3: pass/fail with no number (the big v1 gap) ---
    ("All checks passed", "deny"),
    ("every job is green", "pass"),  # see note below
    ("All checks passed\n$ pytest tests/ -q\n33 passed in 4.10s", "pass"),
    # --- Rule 4: negative all-clear ---
    ("No delta found across the estate", "deny"),
    ("nothing changed", "deny"),
    ("no issues detected", "deny"),
    # --- Rule 5: recently ---
    ("secret-scan passes now", "deny"),
    # --- word boundaries ---
    ("workshop and shoulder padding", "pass"),
]


# ci-harness#61: the two halves disagreed on indentation and on commands
# continued with a trailing backslash. The rules both sides now implement:
#   * a command line that ends in `\` continues onto the next physical line,
#     whatever that line holds (indented, empty, even a placeholder-looking one);
#   * the observed output is the first line after the command, and it must start
#     flush left with something other than a placeholder (`<`, `#`, `$`, backtick);
#   * an indented line is a continuation or noise, never the observed output.
# Each case is named so `-k continued` / `-k indented` selects the family.
PARITY_CASES = [
    ("continued_indented_command_then_output", "30 tests pass\n$ pytest \\\n    tests/\n30 passed", "pass"),
    ("continued_flush_left_command_then_output", "30 tests pass\n$ pytest \\\n-q\n30 passed", "pass"),
    ("continued_three_lines_then_output", "30 tests pass\n$ pytest \\\n  -q \\\n  tests/\n30 passed", "pass"),
    ("continued_command_without_output", "30 tests pass\n$ pytest \\\n    tests/", "deny"),
    ("continued_command_swallows_the_would_be_output", "30 tests pass\n$ pytest \\\n30 passed", "deny"),
    ("continued_command_then_placeholder_output", "30 tests pass\n$ pytest \\\n    tests/\n<output>", "deny"),
    ("continued_crlf_command_then_output", "30 tests pass\r\n$ pytest \\\r\n    tests/\r\n30 passed", "pass"),
    ("continued_verify_inline_then_output", "30 tests pass\nVerify by running: pytest \\\n    tests/\n30 passed", "pass"),
    ("continued_verify_block_then_output", "30 tests pass\nVerify by running:\npytest \\\n  tests/\n30 passed", "pass"),
    ("indented_output_is_not_output", "30 tests pass\n$ pytest\n    30 passed", "deny"),
    ("indented_output_tab_is_not_output", "30 tests pass\n$ pytest\n\t30 passed", "deny"),
    ("indented_verify_inline_output_is_not_output", "30 tests pass\nVerify by running: pytest\n   30 passed", "deny"),
    ("indented_verify_block_command_is_not_a_command", "30 tests pass\nVerify by running:\n  pytest\n30 passed", "deny"),
    ("indented_second_command_then_output", "30 tests pass\n$ pytest\n$ ruff check\nAll good", "pass"),
]


def _bash_verdict(text):
    """Classify what the commit-time hook would do."""
    if not text:
        return "pass"  # empty input exits 0 before any pattern runs
    result = subprocess.run(
        [str(VERIFY_CLAIM), text], capture_output=True, text=True, check=False
    )
    if result.returncode == 2:
        return "deny"
    if result.returncode != 0:
        return f"bash-error-rc{result.returncode}"
    if "warning" in result.stderr:
        return "warn"
    return "pass"


def _rego_verdict(text, tmp_path):
    """Classify what the PR-time gate would do, reproducing the CI step exactly.

    The workflow pipes `jq -c '{text: ...}' | conftest test --policy
    policy/claims.rego -`. jq matters: feeding conftest from Python's
    json.dumps encodes non-BMP characters (emoji) as surrogate pairs, which is
    invalid and makes conftest fail to PARSE -- an error that looks exactly
    like a denial. jq emits literal UTF-8 and does not have that problem.
    """
    if not text:
        text = ""
    body = tmp_path / "body.txt"
    body.write_text(text, encoding="utf-8")
    payload = subprocess.run(
        ["jq", "-cRs", "{text: .}", str(body)],
        capture_output=True,
        text=True,
        check=True,
    )
    result = subprocess.run(
        [CONFTEST, "test", "--rego-version", "v0", "--policy", str(CLAIMS_REGO), "-"],
        input=payload.stdout,
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    for marker in ("rego_parse_error", "rego_type_error", "rego_compile_error"):
        if marker in output:
            return f"rego-{marker}"
    if "Error: running test" in output:
        return "rego-input-error"
    if result.returncode == 1:
        return "deny"
    if result.returncode != 0:
        return f"rego-error-rc{result.returncode}"
    return "warn" if "WARN" in output else "pass"


@needs_conftest
@pytest.mark.parametrize(("text", "expected"), CORPUS, ids=lambda v: v[:38])
def test_bash_and_rego_agree(text, expected, tmp_path):
    bash = _bash_verdict(text)
    rego = _rego_verdict(text, tmp_path)

    assert bash == rego, (
        "verify-claim.sh and claims.rego disagree on the same input.\n"
        f"  input : {text!r}\n"
        f"  bash  : {bash}\n"
        f"  rego  : {rego}\n"
        "Update both policy/claims.rego and scripts/verify-claim.sh together."
    )
    assert bash == expected, (
        f"both sides agree on {bash!r}, which is not the intended verdict "
        f"{expected!r} for {text!r}"
    )


@needs_conftest
@pytest.mark.parametrize(
    ("text", "expected"),
    [pytest.param(text, expected, id=name) for name, text, expected in PARITY_CASES],
)
def test_bash_and_rego_agree_on_continued_and_indented_evidence(text, expected, tmp_path):
    """ci-harness#61: one fixture, two implementations, one verdict."""
    bash = _bash_verdict(text)
    rego = _rego_verdict(text, tmp_path)

    assert bash == rego, (
        "verify-claim.sh and claims.rego disagree on the same input.\n"
        f"  input : {text!r}\n"
        f"  bash  : {bash}\n"
        f"  rego  : {rego}\n"
        "Update both policy/claims.rego and scripts/verify-claim.sh together."
    )
    assert bash == expected, (
        f"both sides agree on {bash!r}, which is not the intended verdict "
        f"{expected!r} for {text!r}"
    )


@needs_conftest
def test_rego_policy_file_compiles(tmp_path):
    """A policy that fails to compile makes conftest exit 1 on EVERY input.

    That reads as a universal denial rather than an error, so a syntax error
    would look like the gate working. Assert the policy compiles on its own.
    """
    result = subprocess.run(
        [CONFTEST, "test", "--rego-version", "v0", "--policy", str(CLAIMS_REGO), "-"],
        input=json.dumps({"text": "fix typo"}),
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert "rego_parse_error" not in output, output
    assert "rego_type_error" not in output, output
    assert result.returncode == 0, output