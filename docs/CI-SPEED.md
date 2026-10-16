# CI speed knobs (reusable-python / reusable-node)

## pytest-select: affected tests on PRs

`pytest-select: affected` runs only the tests pytest-testmon says a pull request touched.
Default is `all`.

- **Data.** A push to the default branch runs the full suite under `--testmon-noselect` and, only
  if it is green, publishes the testmon db as
  `<runner.tool_cache>/testmon/<owner>/<repo>/<branch>/<commit sha>.testmondata` (older files for
  that branch are removed). A PR copies the file named after its merge commit's first parent
  (the base tip) and never writes back.
- **Full-suite fallbacks**, each stated in the job summary: no data, data for another base commit,
  a changed `conftest.py`, `pyproject.toml`, `uv.lock`, `setup.cfg`, `pytest.ini`, `tox.ini` or
  `.github/workflows/*` file, a non-PR event, and testmon selecting zero tests while a non-markdown
  file changed under `project-directory` (pytest exit 5 becomes a full run).
- **xdist.** testmon runs are serial: `pytest-workers` is ignored in `affected` and refresh
  modes. The self-smoke job `affected-fixture` probes xdist + testmon and prints whether it works
  there; the template does not depend on it.
- **Hosted runners** have no runner-local store, so the data travels through `actions/cache`
  (pinned in `pins/ACTIONS.md`):
  - a PR restores `testmon-v1-<repo>-<base branch>-<base sha>`, with the branch prefix as a
    fallback, from `<runner.temp>/hosted/testmon/<owner>/<base branch>`;
  - a green push to the default branch saves the same directory under
    `testmon-v1-<repo>-<default branch>-<sha>`;
  - the repository is in every key, so no repo ever reads another's data, and the fallback only
    helps when the file the select step needs is really there — otherwise it says "no testmon data
    for base <sha>" and runs the full suite. On a cold cache a PR gets one `Path Validation Error`
    warning from the cache action (nothing to restore, nothing to save) and the full suite.
- testmon tracks Python files. A PR that changes only data files a test reads can be skipped by
  testmon; put such paths in the fallback list if a repo needs it.

## Open items

- Hosted testmon data accumulates one cache entry per push to the default branch (the key carries
  the sha). GitHub expires them, but a repo that wants fewer entries can keep its own history
  short; nothing depends on the old entries.

## pytest-workers: auto

`auto` = `max(1, min(cap_cores, 8) // max(1, busy_jobs))`

- `cap_cores`: `/sys/fs/cgroup/cpu.max` quota / period (`600000 100000` is 6). `max` or a missing
  file means `nproc`.
- `busy_jobs`: files in `<runner.tool_cache>/busy-jobs`. The pytest step creates one on start
  (so the count includes itself) and removes it in an `EXIT` trap; files older than
  `timeout-minutes` are pruned as leftovers of a killed runner.
- Hosted runners: `nproc`, no lock dir.
- 6-CPU cap: 1 job gets 6, 2 get 3, 3 get 2, 4 or more get 1. Jobs that overlap by a few seconds
  can both count each other and run under-sized; they never over-subscribe.
- The default is still `0` (serial).

### Callers must quote `pytest-workers`

`pytest-workers` is a **string** input, because `auto` is not a number. GitHub validates every
value in a caller's `with:` block against the declared input type, and `6` in YAML is an integer,
not a string: a bare `pytest-workers: 6` is rejected as a type error before any job runs — the
caller's workflow does not start, so it looks like a broken pin rather than a quoting mistake.
Always write it quoted:

```yaml
      pytest-workers: "6"        # correct: a string, 6 workers
      pytest-workers: auto        # also correct: bare auto is already a string
      # pytest-workers: 6        # wrong: YAML int, rejected as a string input
```

ci-harness's own callers (self-smoke.yml) pass no value today and take the `"0"` default.
`tests/test_workflow_contracts.py::CallerQuotingTest` fails if any workflow in this repo passes a
bare number for it.

## Warm dependency caches

- **Self-hosted** (`runner.environment == 'self-hosted'`): `UV_CACHE_DIR=<runner.tool_cache>/uv-cache`
  (every Python job, and reusable-node when `setup-python` is on) and
  `npm_config_cache=<runner.tool_cache>/npm-cache` (reusable-node). One dir per runner host, shared by
  all jobs; both tools are safe for concurrent use. A dir that cannot be created or written
  produces a warning and the tool's default cache. uv is installed with `pip install uv==<pin>` here.
- **Hosted**: reusable-python uses `astral-sh/setup-uv` with `enable-cache: true`, keyed on the
  `uv.lock` under `project-directory`; reusable-node uses setup-node's `cache: npm` (keyed on the
  package-lock.json under `working-directory`). Both actions are pinned by full SHA in
  `pins/ACTIONS.md`.
- `.venv` and `node_modules` are never cached or shared; a contract test enforces it, and every
  cache key names its repository so no two repos share an entry.
