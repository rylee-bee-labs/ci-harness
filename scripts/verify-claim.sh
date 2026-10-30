#!/usr/bin/env bash
# scripts/verify-claim.sh -- check a text blob for honest claims.
#
# Enforces the "Honesty is the simplest policy" rule from rylee.md
# (lines 170-195): a strong claim (counts, pass/fail) must include
# the command that produces the evidence and its observed output.
#
# Usage:
#   scripts/verify-claim.sh "<commit message or PR body>"
#   echo "<text>" | scripts/verify-claim.sh -
#   scripts/verify-claim.sh - < msg.txt
#
# Exit codes:
#   0  no strong claim is missing evidence (soft claims may
#      warn to stderr but still exit 0)
#   2  at least one strong claim lacks command plus output evidence
#   3  usage error
#
# Evidence is a non-placeholder command followed by a non-placeholder
# observed-output line. Commands may follow "Verify by running:" or
# begin with "$ ", matching the PR template shape. A command line ending in
# a backslash continues onto the next line; the output is the first flush-left
# line after the command (see the evidence block below and policy/claims.rego).
#
# Patterns MUST match policy/claims.rego. If you change one, change
# both. The rego is the source of truth for the PR-time CI check; this
# script is the commit-time check.
#
# "MUST" is now enforced rather than requested:
# tests/test_claim_policy_drift.py runs this script and
# policy/claims.rego over the same corpus and fails if the two ever
# return different verdicts. It used to be a comment nobody ran.
#
# Bypass (emergency only):
#   git commit --no-verify    # skips the commit-msg hook entirely
# The PR-time CI job (pr-claims-verified) is the backstop.

set -euo pipefail

text=""
if [[ $# -eq 0 ]]; then
  text="$(cat)"
elif [[ $# -eq 1 ]]; then
  if [[ "$1" == "-" ]]; then
    text="$(cat)"
  else
    text="$1"
  fi
else
  echo "usage: $0 \"<text>\"  (or pipe via -)" >&2
  exit 3
fi

if [[ -z "$text" ]]; then
  exit 0
fi

# ---- claim patterns (mirror policy/claims.rego) ----
#
# Strong claims:
#   count    "<number> <countable noun>"          e.g. "17 units", "0 vulnerabilities"
#   pf       "<pass/fail> (in|on) <number>"       e.g. "passed in 22.77s"
#   nopass   "<all|every|each> <noun> <pass/fail>"e.g. "All checks passed"
#   allclear "<no|nothing|zero> ... found/changed"
#   recently "<verb> now|again|still"             e.g. "secret-scan passes now"
# Soft claims:
#   "verified", "works", "expected", "should"
#
# grep -E = ERE, which has no \b, so word boundaries are written
# explicitly as (^|[^[:alnum:]]) ... ([^[:alnum:]]|$). The rego side uses
# \b for the same thing; tests/test_claim_policy_drift.py runs BOTH
# implementations over this file's own corpus and fails if they ever
# disagree, so edit both sides together.
strong_count_re='(^|[^[:alnum:]])[0-9]+[[:space:]]+(adapters?|adopters?|alerts?|branches|bytes|checks?|dismissals?|errors?|files?|findings?|invariants?|issues?|jobs?|lines?|packages|prs?|repos?|secrets?|services?|tests?|timers?|units?|vulnerabilit(y|ies)|vulns?|warnings?)([^[:alnum:]]|$)'
strong_pf_re='(^|[^[:alnum:]])(pass(ed)?|fail(ed)?|green|red)[[:space:]]+(in|on)[[:space:]]+[0-9]'
strong_nopass_re='(^|[^[:alnum:]])(all|every|each)[[:space:]]+[[:alnum:]_-]+[[:space:]]+(green|red|passing|passes|passed|failing|fails|failed|clear|clean|done|complete)([^[:alnum:]]|$)'
strong_allclear_re='(^|[^[:alnum:]])(no|none|nothing|zero)[[:space:]]+[[:alnum:]_-]*[[:space:]]*(found|detected|discovered|reported|changed|differing|outstanding|remaining|affected)([^[:alnum:]]|$)'
strong_recently_re='(^|[^[:alnum:]])(passes|works|fails|fixed|resolved|installed)[[:space:]]+(now|again|still)([^[:alnum:]]|$)'
soft_re='(^|[^[:alnum:]])(verified|works|expected|should)([^[:alnum:]]|$)'

has_strong=0
has_soft=0

# grep exits 0 on match, 1 on no-match; under `set -e` we guard with `|| true`.
for rx in "$strong_count_re" "$strong_pf_re" "$strong_nopass_re" \
          "$strong_allclear_re" "$strong_recently_re"; do
  if printf '%s' "$text" | grep -Eiq "$rx"; then
    has_strong=1
  fi
done
if printf '%s' "$text" | grep -Eiq "$soft_re"; then
  has_soft=1
fi

has_evidence=0
# Evidence, line by line, the way policy/claims.rego reads it (ci-harness#61):
#   * a command is a "$ " line, a "Verify by running: <cmd>" line, or the line
#     after a bare "Verify by running:";
#   * a command line that ends in a backslash continues onto the next physical
#     line, whatever it holds, and so on while each line ends in one;
#   * the observed output is the first line AFTER the command and must start
#     flush left with something other than a placeholder (< # $ or a backtick).
#     An indented line is a continuation or noise, never the output.
# Every line is tried as a possible start, like the regexes: another command
# between a command and its output does not hide the second command.
if printf '%s\n' "$text" | awk '
  function ok_first(s) {
    return s != "" && s !~ /^[[:blank:]<#$`]/
  }
  { sub(/\r$/, ""); L[NR] = $0 }
  END {
    found = 0
    for (i = 1; i <= NR && !found; i++) {
      s = L[i]
      k = 0
      if (s ~ /^[$][[:blank:]]+/) {
        sub(/^[$][[:blank:]]+/, "", s)
        if (ok_first(s)) k = i
      } else if (s ~ /^Verify by running:/) {
        rest = s
        sub(/^Verify by running:/, "", rest)
        if (rest ~ /^[[:blank:]]+[^[:blank:]]/) {
          sub(/^[[:blank:]]+/, "", rest)
          if (ok_first(rest)) k = i
        } else if (rest ~ /^[[:blank:]]*$/) {
          if (i < NR && ok_first(L[i + 1])) k = i + 1
        }
      }
      if (k == 0) continue
      while (k <= NR && L[k] ~ /\\$/) k++
      if (k < NR && ok_first(L[k + 1])) found = 1
    }
    exit(found ? 0 : 1)
  }
'; then
  has_evidence=1
fi

if [[ $has_strong -eq 1 && $has_evidence -eq 0 ]]; then
  echo "verify-claim: strong claim (count or pass/fail) without a non-placeholder command and observed output" >&2
  echo "verify-claim: add command plus output evidence, or use --no-verify (emergency only; PR check still catches it)" >&2
  exit 2
fi

if [[ $has_soft -eq 1 && $has_evidence -eq 0 ]]; then
  echo "verify-claim: warning -- soft claim ('verified'/'works'/'expected'/'should') without verification" >&2
  echo "verify-claim: add command plus observed output to make it checkable" >&2
fi

exit 0
