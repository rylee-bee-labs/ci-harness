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
- **Hosted runners** have no testmon store yet (see Open items), so `affected` there always falls
  back to the full suite and says "no testmon data".
- testmon tracks Python files. A PR that changes only data files a test reads can be skipped by
  testmon; put such paths in the fallback list if a repo needs it.

## Open items

- Hosted runners restore and save uv's cache with `astral-sh/setup-uv` v10.3.0 (`1c37ad07…`, resolved with `git ls-remote` 2026-10-15, recorded in `pins/ACTIONS.md`), keyed on `**/uv.lock`.

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
- The default is still `0` (serial). The input is now a string; a caller passing a bare number
  should quote it (`pytest-workers: "6"`).

## Warm dependency caches

- **Self-hosted** (`runner.environment == 'self-hosted'`): `UV_CACHE_DIR=<runner.tool_cache>/uv-cache`
  (every Python job, and reusable-node when `setup-python` is on) and
  `npm_config_cache=<runner.tool_cache>/npm-cache` (reusable-node). One dir per runner host, shared by
  all jobs; both tools are safe for concurrent use. A dir that cannot be created or written
  produces a warning and the tool's default cache.
- **Hosted**: reusable-node uses setup-node's `cache: npm` (keyed on the package-lock.json under
  `working-directory`). reusable-python keeps uv's default cache: see Open items.
- `.venv` and `node_modules` are never cached or shared; a contract test enforces it.
