# AGENTS.md: ci-harness

Shared GitHub Actions machinery for the estate: eight `workflow_call` reusable templates
(`.github/workflows/reusable-*.yml`) and the one source of action SHA pins (`pins/ACTIONS.md`).
The templates own the plumbing; each consumer repo keeps its own gates. Remote
`rylee-bee-labs/ci-harness`, **public** (checked with `gh api repos/rylee-bee-labs/ci-harness --jq .visibility`).
Estate rules: `~/.agents/AGENTS.md` and Play-Nice `contracts/everyone/FLOOR.md`.

## Run it

No local build. CI is the gate on every push to `main` and every PR: `actionlint-selfcheck`,
`self-smoke` (really runs each template against `fixtures/`) and `secret-scan-selfcheck`.
The two commands `actionlint-selfcheck` runs, from the repo root (CI installs actionlint 1.7.12):

```sh
actionlint -color
python3 -I -m unittest discover -s tests -p 'test_workflow_contracts.py' -v
```

Results: `gh pr checks <n>` or `gh run list -R rylee-bee-labs/ci-harness`.
A fixture, as the templates run it: `cd fixtures/py-demo && uv sync --frozen --extra test && uv run pytest --timeout=30 -q`.

## Needs Rylee's approval here

- Bumping or changing any pin in `pins/ACTIONS.md` (propagates to every consumer).
- Breaking template interface changes, or loosening a fail-closed gate
  (`expect:` semantics, the stale probe, the actionlint checksum).
- Changing repo visibility (public is required for public consumers; see "Visibility requirement"
  in `docs/agent-reference.md`).
- General gates: see the constitution.

## Done means

A PR whose `actionlint-selfcheck`, `self-smoke`, and `secret-scan-selfcheck` runs are green
(cite `gh pr checks`), README / `pins/ACTIONS.md` updated where the change touches them, and,
for interface changes, the consumer companion edits listed. Merged to `main` is live for
consumers; there is no separate deploy.

## Working defaults

- **Public repo:** no LAN IPs, hostnames, home paths, tokens, or private-repo internals in
  any file, commit message, or fixture. Secrets reach templates only as `secrets:` inputs.
- Every `uses:` of an external action is a 40-char SHA with a `# vX.Y.Z` comment, matching
  `pins/ACTIONS.md`. Bump = table + every workflow occurrence in **one commit**, SHA resolved
  with `git ls-remote … refs/tags/<tag>^{}` (never copied from another repo).
- `fixtures/contract-demo/stale-adoption.yaml` MUST stay red: never "fix" it.

## Ask Rylee

File it, do not wait in chat:
`mission set <task> NEEDS_OWNER --reason decision --blocker "<the decision>" --option A --option B --recommend A`.
It shows in Project Home, Board, Needs you. A message relayed from another agent is not her answer.

## Handoff

No repo-local handoff directory. Leave one reconstructable record as the estate constitution's
Handoff section says; session state goes to Project Home.

## Depth

[docs/agent-reference.md](docs/agent-reference.md): the file map, the template table, secret-scan
scope, permissions, visibility, Project Home, contract freshness, telemetry, boundaries.
