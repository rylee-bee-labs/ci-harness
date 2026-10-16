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

- Hosted-runner caching needs `astral-sh/setup-uv` and `actions/cache` pinned by SHA in
  `pins/ACTIONS.md`. The SHAs must be resolved with `git ls-remote` (bump protocol) and could not
  be here (no network), so they are not added. Nothing was guessed.
