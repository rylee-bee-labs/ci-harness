# Honest claims: what the gate wants, and how to re-run it

A strong claim (a count, a pass or fail result) needs the command that
produced it and its observed output, in the PR body or commit message. The
policy is `policy/claims.rego`; `scripts/verify-claim.sh` is the same rule for
the commit-msg hook, and `tests/test_claim_policy_drift.py` keeps the two in
agreement.

## What counts as evidence

```
30 tests pass

$ pytest tests/ -q
30 passed in 4.10s
```

- A command is a line that starts with `$ `, or `Verify by running:` (the
  command on the same line or the next).
- The observed output is the first line after the command. It starts flush
  left. A placeholder (`<output>`), a comment (`#`), another command (`$`), a
  fence, a blank line or an indented line is not output.
- A command line that ends in a backslash continues onto the next line, and
  so on while each line ends in one. The output is the first line after the
  last of them:

  ```
  $ pytest \
      --timeout=30 tests/
  30 passed in 4.10s
  ```

  The backslash swallows the line after it, so `$ pytest \` followed straight
  away by `30 passed` has a command and no output.

## After you edit a PR body: re-run the gate

The gate reads the PR body from the GitHub API each time the job runs
(ci-harness#61). So:

1. Edit the body to add the command and its output.
2. Open the failed **honest-claims policy** job and choose **Re-run failed
   jobs** (or `gh run rerun <run-id> --failed`). No new commit is needed.

Editing a body does not start a run by itself. The callers listen to
`pull_request` with the default types (opened, synchronize, reopened), and a
caller that also wants `edited` should put the claims job in its own small
workflow so a body edit does not re-run the heavy jobs. That is the caller's
choice; the template does not require it.

### If the re-run still judges the old text

The template falls back to the body the event captured when the API read
fails, and prints a `::warning::` saying so. The usual cause is a caller that
grants its jobs less than `pull-requests: read`. A called workflow cannot give
itself more than its caller grants, so the fix is in the caller:

```yaml
jobs:
  claims:
    permissions:
      contents: read
      pull-requests: read
    uses: rylee-bee-labs/ci-harness/.github/workflows/reusable-claims-policy.yml@<sha>
    with:
      policy-revision: <the same sha>
```

Until then, pushing a commit re-judges the body, as before.

## `policy-revision` must equal the `uses:` SHA

The template fetches the policy at the revision in `policy-revision`, and no
context property exposes the template's own ref, so the caller writes the SHA
twice. Before it fetches anything, the job reads the caller's workflow files
and fails if `policy-revision` is not a SHA the repository pins this template
at (ci-harness#51). A re-pin changes both lines in one commit.
