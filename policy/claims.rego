# policy/claims.rego
#
# Policy-as-code for commit messages and PR descriptions. Enforces
# the "Honesty is the simplest policy" rule from rylee.md
# (lines 170-195): a strong claim (counts, pass/fail) must include
# the command that produces the evidence and its observed output.
#
# Input contract: conftest is fed a JSON object of the shape
#   {"text": "<commit message or PR body>"}
# The CI job (.github/workflows/validate.yml -> the [pr-claims-verified] steps)
# builds this from GITHUB_EVENT_PATH (PR body); the commit-msg hook
# builds it from the commit message file. The rego rules are agnostic
# to the source.
#
# Two rule classes, mirroring compose.rego:
#   deny -- strong claim (counts, pass/fail) without command plus output
#          -> CI fails / hook blocks the commit.
#   warn -- soft claim ("should work", "verified") without a Verify
#          block -> CI passes, hook exits 0 with a warning.
#
# Scoping: whole-text, not per-paragraph. The PR template puts
# claims in `## What changed` and the evidence block in
# `## Verification` (separate paragraphs); same-paragraph scoping
# would break that flow. v1 goal: make the agent include SOME
# verify command. Widen to per-paragraph only if a false-negative
# is reported.
#
# Adding a pattern: append a regex to strong_claim_re or
# soft_claim_re, add a unit test in claims_test.rego, run
#   conftest verify --rego-version v0 --policy policy/
# (the --rego-version v0 flag is REQUIRED: conftest 0.46+ defaults to
# Rego v1 and every file in policy/ is v0 syntax. The header of
# claims_test.rego used to omit this flag -- following it verbatim
# failed to parse all five policy files.)
#
# The bash helper scripts/verify-claim.sh MUST carry the same patterns
# for the commit-msg hook. That duplication used to be held together by
# a comment and nothing else. tests/test_claim_policy_drift.py now
# runs both implementations over a shared corpus and fails on any
# disagreement -- see the "MIRROR" section there before editing either
# side. A one-sided edit fails CI instead of silently drifting.
#
# ---------------------------------------------------------------------------
# WIDENING 2026-10-06 -- what was added, and what was rejected as false
# positives
#
# Twelve real claims from an estate audit were run through the v1
# patterns. Exactly one was denied. The patterns below close the
# gaps that were measured, not guessed.
#
# Every candidate below was first measured against the 60 most recent
# merged homelab PR bodies (106k chars of real traffic that already
# passed this gate). "hits" = bodies the regex matches; a hit is only
# a problem if has_evidence is false, because a body that shows the
# command and its output is doing the thing the policy asks for.
#
#   ADDED  count nouns      4/60 newly hit. The "2 warnings in 0.13s"
#                           hit is pytest observed output, so
#                           has_evidence is true and nothing fires.
#   ADDED  no-number pf     9/60 hit, every one of them quoting a real
#                           pytest run ("All checks passed!" after a
#                           $ pytest line) -> has_evidence true.
#   ADDED  negative all-clear 1/60, ships its own git command.
#   ADDED  verb+now         0/60. Free.
#
#   REJECTED  completion verbs (merged|deployed|installed|shipped|
#   resolved|activated|promoted): 17/60 bodies match, and they are
#   overwhelmingly innocent. "bin/deployed-drift" is a real tool in
#   this repo, so the bare word collides with a filename;
#   "lab_content.py resolved its engine to ..." and "whether it is
#   installed ... is unverified" are ordinary prose, and the last is
#   already correct hedging. Denying on these would block honest PRs.
#   They stay out until a shape that does not collide is found.
# ---------------------------------------------------------------------------

package main

# Guard: if input.text is missing or not a string, no rules fire.
# This makes the policy safe to run against an empty API response
# (conftest exits 0; the CI job itself errors separately on a
# fetch failure).
text := input.text

# ---------------------------------------------------------------------------
# Strong claims: counts and pass/fail results.
#
# Rule 1 -- "<number> <countable noun>"
# The noun list is closed and alphabetical. It was widened from
# tests|errors|files|bytes|lines|jobs to cover the nouns an agent
# actually uses when describing this estate: "17 units, 0 missing",
# "0 vulnerabilities", "13 of 28 repos", "4 commits", "6 adapters".
#
# Rule 2 -- "<pass/fail verb> (in|on) <number>"  e.g. "passed in 22.77s"
#
# Rule 3 -- pass/fail asserted with NO number. This was the largest
# real gap: v1 only matched pass/fail next to a digit, so "All checks
# passed" and "every job is green" sailed through despite being
# exactly the claim the rule exists to police.
#
# Rule 4 -- negative all-clear: "no delta found", "nothing changed",
# "no issues detected". A false all-clear is worse than no claim at
# all, because it is trusted; this is the shape an unauthenticated
# or partial API read produces when it is mistaken for a full one.
#
# Rule 5 -- "<verb> now|again|still": "secret-scan passes now".
# ---------------------------------------------------------------------------

# NOTE: these are written out in full rather than composed from shared
# fragments. Rego has no string concatenation, and a v1 attempt at
# `a := "x" + b` compiles to nothing -- conftest then exits 1 on the
# policy error and every input looks like a denial. Full literals
# cannot half-build. The rego<->bash equivalence is enforced by
# tests/test_claim_policy_drift.py, not by a shared constant.

# Rule 1: "<number> <countable noun>"
# "commits" was tried here and removed. Measured on 60 real merged PRs it
# caused 2 of the 3 regressions, both of them descriptive build metadata
# rather than claims: "Worker: MiniMax M3.1 (sandboxed offload agent,
# 2 commits)" and a `git log` table captioned "- 4 commits:". The one
# claim it would have caught ("150 commits sat merged, green and tested")
# is carried by "green" anyway. Low value, real friction.
strong_claim_re := "(?i)\\b[0-9]+\\s+(adapters?|adopters?|alerts?|branches|bytes|checks?|dismissals?|errors?|files?|findings?|invariants?|issues?|jobs?|lines?|packages|prs?|repos?|secrets?|services?|tests?|timers?|units?|vulnerabilit(y|ies)|vulns?|warnings?)\\b"

# Rule 2: "<pass/fail verb> (in|on) <number>"  e.g. "passed in 22.77s"
strong_pf_re := "(?i)\\b(pass(ed)?|fail(ed)?|green|red)\\s+(in|on)\\s+[0-9]"

# Rule 3: pass/fail asserted with NO number -- "all checks passed"
strong_nopass_re := "(?i)\\b(all|every|each)\\s+[\\w-]+\\s+(green|red|passing|passes|passed|failing|fails|failed|clear|clean|done|complete)\\b"

# Rule 3b was RETRACTED. It read "<checks|tests|...> (are|is|all|now)? <pf>"
# and was measured on 60 real merged PRs, where it was the sole cause of
# two of three regressions:
#   "This PR merges itself once every check is green (never with an
#    admin override)" -- that is the merge POLICY being described, not
#    a claim that checks are green. Denying it punishes honesty about
#    how the repo gates itself.
#   "... -> All checks passed" -- quoting a real result, which Rule 3
#    already covers via the leading "All".
# Rule 3 catches every case Rule 3b was added for ("All checks passed",
# "every job is green") without the optional is/are connector that made
# conditional prose match. Do not re-add it without re-measuring.

# Rule 4: negative all-clear -- "no delta found", "nothing changed"
strong_allclear_re := "(?i)\\b(no|none|nothing|zero)\\s+[\\w-]*\\s*(found|detected|discovered|reported|changed|differing|outstanding|remaining|affected)\\b"

# Rule 5: "<verb> now|again|still" -- "secret-scan passes now"
strong_recently_re := "(?i)\\b(passes|works|fails|fixed|resolved|installed)\\s+(now|again|still)\\b"

strong_claim {
    regex.match(strong_claim_re, text)
}

strong_claim {
    regex.match(strong_pf_re, text)
}

strong_claim {
    regex.match(strong_nopass_re, text)
}

strong_claim {
    regex.match(strong_allclear_re, text)
}

strong_claim {
    regex.match(strong_recently_re, text)
}

# ---------------------------------------------------------------------------
# Soft claims: hedging language that implies verification happened.
#
# Matches (case-insensitive, whole word):
#   - "verified", "works", "expected", "should"
# These warrant a warning rather than a block: a commit that says
# "this should work" without proof is suspect, but the bar for
# blocking is higher than for "30 tests pass".
# ---------------------------------------------------------------------------

soft_claim_re := "(?i)\\b(verified|works|expected|should)\\b"

soft_claim {
    regex.match(soft_claim_re, text)
}

# ---------------------------------------------------------------------------
# Evidence: a real command followed immediately by observed output.
#
# Accepted command forms are "Verify by running:" and a line beginning
# with "$ ". Angle-bracket placeholders, headings, comments, fences,
# blank lines, and another command do not count as observed output.
#
# Continued commands (ci-harness#61). A command line that ends in a backslash
# continues onto the next physical line, whatever that line holds (indented,
# empty, even placeholder-looking), and so on while each line ends in a
# backslash. The observed output is the first line AFTER the command:
#
#     $ pytest \
#         --timeout=30 tests/        <- still the command
#     30 passed in 4.10s             <- the observed output
#
# The output line must start flush left with something other than a
# placeholder: an indented line is a continuation or noise, never the
# observed output. scripts/verify-claim.sh implements the same rule line by
# line; tests/test_claim_policy_drift.py holds the shared fixtures.
#
# The tail below is written out in full three times, like every pattern in
# this file. Read it as: the command's first line, then EITHER a line ending
# in a backslash followed by any number of further backslash lines and one
# final line that does not end in one, OR a first line that does not end in a
# backslash; then a newline and the output line.
# ---------------------------------------------------------------------------

dollar_evidence_re := "(?m)^\\$[ \\t]+(?:(?:\\\\|[^<#$` \\t\\r\\n][^\\r\\n]*\\\\)\\r?\\n(?:[^\\r\\n]*\\\\\\r?\\n)*(?:[^\\r\\n]*[^\\\\\\r\\n])?|(?:[^<#$` \\t\\r\\n\\\\]|[^<#$` \\t\\r\\n][^\\r\\n]*[^\\\\\\r\\n]))\\r?\\n[^<#$` \\t\\r\\n][^\\r\\n]*"
inline_evidence_re := "(?m)^Verify by running:[ \\t]+(?:(?:\\\\|[^<#$` \\t\\r\\n][^\\r\\n]*\\\\)\\r?\\n(?:[^\\r\\n]*\\\\\\r?\\n)*(?:[^\\r\\n]*[^\\\\\\r\\n])?|(?:[^<#$` \\t\\r\\n\\\\]|[^<#$` \\t\\r\\n][^\\r\\n]*[^\\\\\\r\\n]))\\r?\\n[^<#$` \\t\\r\\n][^\\r\\n]*"
block_evidence_re := "(?m)^Verify by running:[ \\t]*\\r?\\n(?:(?:\\\\|[^<#$` \\t\\r\\n][^\\r\\n]*\\\\)\\r?\\n(?:[^\\r\\n]*\\\\\\r?\\n)*(?:[^\\r\\n]*[^\\\\\\r\\n])?|(?:[^<#$` \\t\\r\\n\\\\]|[^<#$` \\t\\r\\n][^\\r\\n]*[^\\\\\\r\\n]))\\r?\\n[^<#$` \\t\\r\\n][^\\r\\n]*"

has_evidence {
    regex.match(dollar_evidence_re, text)
}

has_evidence {
    regex.match(inline_evidence_re, text)
}

has_evidence {
    regex.match(block_evidence_re, text)
}

# ---------------------------------------------------------------------------
# Rule 1: strong claim without verification -> deny
# ---------------------------------------------------------------------------

deny[msg] {
    strong_claim
    not has_evidence
    msg := "strong claim (count or pass/fail) without a non-placeholder command and observed output; see docs/guides/honest-claims.md"
}

# ---------------------------------------------------------------------------
# Rule 2: soft claim without verification -> warn
#
# The `not strong_claim` guard prevents double-noise: if the same
# text has both a strong and a soft claim and no verify, the deny
# already covers it.
# ---------------------------------------------------------------------------

warn[msg] {
    soft_claim
    not has_evidence
    not strong_claim
    msg := "soft claim ('verified'/'works'/'expected'/'should') without verification; add command plus observed output to make it checkable"
}