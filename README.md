# ci-harness

ci-harness is a set of ready-made GitHub Actions workflows ("templates") that other
repositories call from their own CI, so each repo writes a short contract instead of
copy-pasting checkout, install, test, secret-scanning, and telemetry plumbing. The
templates own the machinery; each repo still owns which checks run and what they mean,
so repo-specific gates stay in the repo that has them.

## Is it running?

Every push and pull request runs three checks here: `actionlint-selfcheck`,
`self-smoke`, and `secret-scan-selfcheck`. Whether the latest one passed is only knowable
from GitHub, and this command prints it:

```sh
gh run list -R rylee-bee-labs/ci-harness
```

Latest result: UNKNOWN from a clone — GitHub holds that fact, and the command above is
the only honest source for it. `self-smoke` is the check that matters: it really executes
every template against the small sample projects in `fixtures/`, rather than only linting
the YAML.

## How to use it

1. Pick a template in `.github/workflows/`, and get a commit SHA to pin it to:

   ```sh
   git ls-remote https://github.com/rylee-bee-labs/ci-harness refs/heads/main
   ```

2. Call it from your own workflow, at that SHA, passing your repo's own arguments:

   ```yaml
   jobs:
     test:
       uses: rylee-bee-labs/ci-harness/.github/workflows/reusable-python.yml@<sha>
       with:
         sync-args: "--extra test"
         pytest-args: "--timeout=30"
   ```

   A merge to this repo's `main` changes nothing for you: you keep running the commit you
   pinned until you move the pin yourself.

   If the diff is docs-only, `reusable-python.yml` takes a `skip-reason: "<why>"` input: the job
   still runs, under its normal `<job> / python tests` name, and goes green without running a suite.
   It skips the python tests only — secret scanning, claims and every release or identity gate still
   run. See [docs/CI-SPEED.md](docs/CI-SPEED.md).

3. Read the result:

   ```sh
   gh pr checks <your-pull-request-number>
   ```

## Where to read more

- [AGENTS.md](AGENTS.md) — the full template table, what a caller keeps owning, the
  permission and telemetry rules, and how work is done in this repo.
- [pins/ACTIONS.md](pins/ACTIONS.md) — every pinned action version and how to bump one.
- [docs/ACTIONS-COST-DISCIPLINE.md](docs/ACTIONS-COST-DISCIPLINE.md) — the cost rules a
  new workflow has to follow.
- [docs/BACKLOG.md](docs/BACKLOG.md) — work this repo has agreed to do.