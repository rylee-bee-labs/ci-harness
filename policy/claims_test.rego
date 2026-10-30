# policy/claims_test.rego
#
# Unit tests for claims.rego. Run with
#   conftest verify --rego-version v0 --policy policy/
# (which invokes `opa test`). --rego-version v0 is REQUIRED: conftest
# 0.46+ defaults to Rego v1 and every file in policy/ is v0 syntax.
# Each test feeds a synthetic text blob and asserts the expected
# deny/warn count.
#
# Mirrors compose_test.rego's shape: one positive (rule fires) and
# one negative (rule passes) test per rule, plus guard tests for
# benign input and missing fields.

package main

# Helper: build the input shape claims.rego expects.
with_text(s) := {"text": s}

# ---------------------------------------------------------------------------
# Rule 1: strong count claim
# ---------------------------------------------------------------------------

test_strong_count_without_verify_denies {
    input := with_text("30 tests pass")
    count(deny) > 0 with input as input
}

test_strong_count_with_verify_passes {
    input := with_text("30 tests pass\nVerify by running: pytest tests/\n30 passed")
    count(deny) == 0 with input as input
}

test_strong_count_with_dollar_block_passes {
    input := with_text("0 errors\n\n```\n$ flake8\n0 findings\n```")
    count(deny) == 0 with input as input
}

test_strong_count_with_template_placeholders_denies {
    input := with_text("30 tests pass\n\n```\n$ <command>\n<output>\n```")
    count(deny) > 0 with input as input
}

test_strong_count_with_command_without_output_denies {
    input := with_text("30 tests pass\n\n$ pytest")
    count(deny) > 0 with input as input
}

test_strong_count_with_placeholder_output_denies {
    input := with_text("30 tests pass\n\n$ pytest\n<output>")
    count(deny) > 0 with input as input
}

# ---------------------------------------------------------------------------
# Rule 1: strong pass/fail claim
# ---------------------------------------------------------------------------

test_strong_pf_without_verify_denies {
    input := with_text("all green in 22s")
    count(deny) > 0 with input as input
}

test_strong_pf_with_verify_passes {
    input := with_text("passed in 22.77s\n\nVerify by running:\n$ pytest\n30 passed")
    count(deny) == 0 with input as input
}

# ---------------------------------------------------------------------------
# Rule 2: soft claim -> warn (not deny)
# ---------------------------------------------------------------------------

test_soft_without_verify_warns_not_denies {
    input := with_text("this should work")
    count(warn) > 0 with input as input
    count(deny) == 0 with input as input
}

test_soft_with_verify_passes {
    input := with_text("this should work\nVerify by running: make test\nchecks passed")
    count(warn) == 0 with input as input
    count(deny) == 0 with input as input
}

# ---------------------------------------------------------------------------
# Guards: benign text and missing fields must not fire any rule.
# ---------------------------------------------------------------------------

test_benign_text_passes {
    input := with_text("fix typo in README")
    count(deny) == 0 with input as input
    count(warn) == 0 with input as input
}

test_missing_text_passes {
    # No "text" key -> rules must not fire and must not error.
    input := {}
    count(deny) == 0 with input as input
    count(warn) == 0 with input as input
}

test_empty_text_passes {
    input := with_text("")
    count(deny) == 0 with input as input
    count(warn) == 0 with input as input
}

# ---------------------------------------------------------------------------
# Cross-check: a paragraph that has BOTH a strong and a soft claim
# without verify fires deny exactly (warn suppressed to avoid
# double-noise).
# ---------------------------------------------------------------------------

test_strong_and_soft_without_verify_denies_only {
    input := with_text("30 tests pass; this should work")
    count(deny) > 0 with input as input
    count(warn) == 0 with input as input
}

# ---------------------------------------------------------------------------
# Widen 2026-10-06: the new rules
# ---------------------------------------------------------------------------

test_count_noun_new_denies {
    input := with_text("17 units, 0 missing, 0 unanchored")
    count(deny) > 0 with input as input
}

test_count_noun_vulnerabilities_denies {
    input := with_text("0 vulnerabilities introduced by the branch")
    count(deny) > 0 with input as input
}

test_count_noun_ratio_denies {
    input := with_text("13 of 28 repos visible via the API endpoint")
    count(deny) > 0 with input as input
}

test_count_noun_with_verify_passes {
    input := with_text("17 units, 0 missing\nVerify by running: bash estate-switch-on.sh\n17 units, 0 missing, 0 unanchored")
    count(deny) == 0 with input as input
}

test_allclear_denies {
    input := with_text("No delta found across the estate")
    count(deny) > 0 with input as input
}

test_allclear_with_verify_passes {
    input := with_text("No delta found across the estate\n$ lab delta --quiet\nclean")
    count(deny) == 0 with input as input
}

test_recently_denies {
    input := with_text("secret-scan passes now")
    count(deny) > 0 with input as input
}

test_nopass_denies {
    input := with_text("All checks passed")
    count(deny) > 0 with input as input
}

test_nopass_with_verify_passes {
    input := with_text("All checks passed\n$ pytest tests/ -q\n33 passed in 4.10s")
    count(deny) == 0 with input as input
}

# ---------------------------------------------------------------------------
# Negative guards for the three candidates that were REJECTED after being
# measured against 60 real merged PRs. These exist so the next person does
# not re-add the patterns having rediscovered the false positives the hard
# way. See the WIDENING block in claims.rego for the counts.
# ---------------------------------------------------------------------------

test_conditional_green_prose_is_not_a_claim {
    # "once every check is green" describes the merge policy. The retracted
    # Rule 3b matched this via its optional "is" connector.
    input := with_text("This PR merges itself once every check is green (never with an admin override)")
    count(deny) == 0 with input as input
}

test_filename_mention_is_not_a_claim {
    # "deployed-drift" is a real binary in this repo. Completion verbs were
    # rejected because the bare word collides with this filename.
    input := with_text("tests live in agent-platform beside bin/deployed-drift and bin/ci-runners-health")
    count(deny) == 0 with input as input
    count(warn) == 0 with input as input
}

test_commit_count_metadata_is_not_a_claim {
    # "commits" was dropped from the count-noun list: 2 of 3 corpus
    # regressions were descriptive build metadata like this.
    input := with_text("Worker: MiniMax M3.1 (sandboxed offload agent, 2 commits)")
    count(deny) == 0 with input as input
}

test_word_boundary_on_soft_claim {
    # "workshop" must not read as the soft claim "works".
    input := with_text("workshop and shoulder padding")
    count(warn) == 0 with input as input
    count(deny) == 0 with input as input
}

# ---------------------------------------------------------------------------
# ci-harness#61: commands continued with a trailing backslash, and indented
# lines. scripts/verify-claim.sh must give the same verdicts; the shared
# fixtures live in tests/test_claim_policy_drift.py (PARITY_CASES).
# ---------------------------------------------------------------------------

test_continued_command_with_output_passes {
    input := with_text("30 tests pass\n$ pytest \\\n    tests/\n30 passed")
    count(deny) == 0 with input as input
}

test_continued_command_over_three_lines_passes {
    input := with_text("30 tests pass\n$ pytest \\\n  -q \\\n  tests/\n30 passed")
    count(deny) == 0 with input as input
}

test_continued_command_without_output_denies {
    input := with_text("30 tests pass\n$ pytest \\\n    tests/")
    count(deny) > 0 with input as input
}

test_continuation_swallows_the_line_after_it {
    # A backslash continues the command, so "30 passed" is part of it, not the output.
    input := with_text("30 tests pass\n$ pytest \\\n30 passed")
    count(deny) > 0 with input as input
}

test_continued_verify_block_with_output_passes {
    input := with_text("30 tests pass\nVerify by running:\npytest \\\n  tests/\n30 passed")
    count(deny) == 0 with input as input
}

test_indented_output_is_not_observed_output {
    input := with_text("30 tests pass\n$ pytest\n    30 passed")
    count(deny) > 0 with input as input
}

test_a_second_command_does_not_hide_the_first_pair {
    input := with_text("30 tests pass\n$ pytest\n$ ruff check\nAll good")
    count(deny) == 0 with input as input
}
