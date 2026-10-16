# CI speed knobs (reusable-python / reusable-node)

## pytest-select: affected tests on PRs

`pytest-select: affected` runs only the tests pytest-testmon says a pull request touched.
Default is `all`.

- **Data, self-hosted.** A push to the default branch runs the full suite under `--testmon-noselect` and, only
  if it is green, publishes the testmon db as
  `<runner.tool_cache>/testmon/<owner>/<repo>/<branch>/<commit sha>.testmondata` (older files for
  that branch are removed). A PR copies the file named after its merge commit's first parent
  (the base tip) and never writes back.
- **Data, hosted.** Runners are throwaway, so the db goes through `actions/cache/save` and
  `actions/cache/restore` (v6.1.0, pinned by SHA). A green push to the default branch saves
  `.testmondata` under `testmon-<os>-<python>-<hash of project-directory>-<github.sha>`. A PR restores the
  exact key for `pull_request.base.sha`, else the newest entry with the same prefix. Stale data is safe: testmon
  compares current file fingerprints with the stored ones, so it can only select more tests. Nothing restored
  means the full suite. The job summary says whether the data was for the base or older.
- **Full-suite fallbacks**, each stated in the job summary: no data (self-hosted: none for the
  PR's base commit; hosted: nothing restored), a changed `conftest.py`, `pyproject.toml`, `uv.lock`,
  `setup.cfg`, `pytest.ini`, `tox.ini` or `.github/workflows/*` file (anywhere in the repo), a non-PR
  event, **any changed file that is not a `.py` file under `project-directory`**, and testmon selecting
  zero tests (pytest exit 5 or an empty junit file).
- **xdist.** testmon runs are serial: `pytest-workers` is ignored in `affected` and refresh
  modes. The self-smoke job `affected-fixture` probes xdist + testmon and prints whether it works
  there; the template does not depend on it. The refresh stays serial because that probe is informational, not proof, and bad recorded data would make later runs select too little.
- testmon tracks Python files it saw run **in the pytest process**, under its rootdir. That is why
  any non-`.py` change (data, templates, markdown a test reads, extensionless scripts) and any
  Python outside `project-directory` runs the full suite. It also cannot see code a test runs in a
  **subprocess**: a repo whose tests mostly drive scripts through `subprocess` should not opt in,
  because testmon would select too few tests there.

## pytest-workers: auto

`auto` = `max(1, min(cap_cores, 8) // max(1, busy_jobs))`

- `cap_cores`: `/sys/fs/cgroup/cpu.max` quota / period (`600000 100000` is 6). `max` or a missing
  file means `nproc`.
- `busy_jobs`: files in `<runner.tool_cache>/busy-jobs`. The pytest step creates one on start
  (so the count includes itself) and removes it in an `EXIT` trap; files older than
  360 minutes (GitHub's job maximum, one bound for every job whatever its `timeout-minutes`) are
  pruned as leftovers of a killed runner. Each lock records pid, run id and start time.
- Hosted runners: `nproc`, no lock dir.
- 6-CPU cap: 1 job gets 6, 2 get 3, 3 get 2, 4 or more get 1. Jobs that overlap by a few seconds
  can both count each other and run under-sized; they never over-subscribe.
- The default is still `0` (serial). The input is now a string; a caller passing a bare number
  must quote it: pass `pytest-workers: "6"` or `pytest-workers: "auto"`, never a bare `6`.
  A contract test runs the step with both `"6"` and `auto`.

## Warm dependency caches

- **Self-hosted** (`runner.environment == 'self-hosted'`): `UV_CACHE_DIR=<runner.tool_cache>/uv-cache`
  (every Python job, and reusable-node when `setup-python` is on) and
  `npm_config_cache=<runner.tool_cache>/npm-cache` (reusable-node). One dir per runner host, shared by
  all jobs; both tools are safe for concurrent use. A dir that cannot be created or written
  produces a warning and the tool's default cache.
- **Hosted**: reusable-node uses setup-node's `cache: npm` (keyed on the package-lock.json under
  `working-directory`). reusable-python uses `astral-sh/setup-uv` v10.3.0
  (`1c37ad07…`, resolved with `git ls-remote` 2026-10-15, in `pins/ACTIONS.md`) with `enable-cache: true`,
  keyed on `**/uv.lock`. It caches uv's package cache only.
- Hosted `pytest-select: affected` also keeps the testmon db in `actions/cache` (see above).
- `.venv` and `node_modules` are never cached or shared; a contract test checks that no cache step's
  `path` includes them.
