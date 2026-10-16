"""Put this fixture's own modules on sys.path, however pytest is invoked.

`tests/test_calc.py` imports `calc` and `tests/test_text.py` imports `text`, both
of which live at the fixture root, not in `tests/` — the same shape as a repo's
tests importing from its source root. pytest's rootdir-relative `pythonpath = .`
(see pytest.ini) covers that when the fixture IS the rootdir. This file is the
fallback for every other invocation: a copy of the fixture in RUNNER_TEMP driven
by self-smoke's `affected-fixture` job, and a repo-wide run from ci-harness's own
root (excluded by the root pytest.ini, but excluded because it is a foreign repo,
not because its imports are broken).

Deliberately not an `__init__.py` in tests/: that would make pytest import the
tests as `tests.test_calc`, which is a different collection shape than the real
repos this fixture stands in for.
"""

import sys
from pathlib import Path

ROOT = str(Path(__file__).resolve().parent)
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)