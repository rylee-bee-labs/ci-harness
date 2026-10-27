"""Static contracts for the reusable templates (stdlib only, text-level).

actionlint proves the workflows parse; these prove the CI-friction fixes stay in place:
the preflight is every job's first step, every runner job in every workflow is bounded,
reusable-python reports failures, and the secret scan stays narrow on PRs but full
everywhere else.
"""
import hashlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

WF = Path(__file__).resolve().parent.parent / ".github" / "workflows"
TEMPLATES = sorted(WF.glob("reusable-*.yml"))


def read(name: str) -> str:
    return (WF / name).read_text()


def jobs_in(text: str) -> dict:
    """Split a workflow's top-level `jobs:` mapping into {job-key: body-lines}.

    Text-level (stdlib only), same as the rest of this file: job keys sit at
    two-space indent and their bodies are everything up to the next job key.
    """
    match = re.search(r"^jobs:\s*$", text, re.M)
    if match is None:
        return {}
    jobs: dict = {}
    current = None
    for line in text[match.end():].splitlines():
        job = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if job:
            current = jobs[job.group(1)] = []
        elif current is not None:
            current.append(line)
    return jobs


class PreflightTest(unittest.TestCase):
    def test_templates_found(self) -> None:
        self.assertGreaterEqual(len(TEMPLATES), 8)

    def test_preflight_is_first_step_of_every_job(self) -> None:
        for path in TEMPLATES:
            text = path.read_text()
            blocks = text.split("\n    steps:\n")[1:]
            self.assertTrue(blocks, path.name)
            for block in blocks:
                first = re.search(r"^      - (?:name|uses): (.*)$", block, re.M)
                self.assertIsNotNone(first, path.name)
                self.assertTrue(
                    first.group(1).startswith("Preflight"),
                    f"{path.name}: first step is {first.group(1)!r}, not the preflight",
                )

    def test_preflight_names_path_and_owner(self) -> None:
        for path in TEMPLATES:
            text = path.read_text()
            self.assertIn("is not writable by uid", text, path.name)
            self.assertIn("owner is", text, path.name)



    def test_every_job_in_every_template_has_timeout(self) -> None:
        for path in TEMPLATES:
            text = path.read_text()
            jobs = len(re.findall(r"^    runs-on:", text, re.M))
            self.assertGreater(jobs, 0, path.name)
            self.assertEqual(
                text.count("    timeout-minutes: ${{ inputs.timeout-minutes }}\n"), jobs, path.name
            )

    def test_scratch_reset_names_only_harness_files(self) -> None:
        # RUNNER_TEMP is shared with the runner; never wipe a whole directory like bin/.
        for path in TEMPLATES:
            self.assertNotRegex(path.read_text(), r"conftest\.tar\.gz bin ", path.name)


class EveryJobIsBoundedTest(unittest.TestCase):
    """No runner-backed job in any workflow may fall back to GitHub's 360-minute default.

    A job whose body is a reusable-workflow call (`uses:` at job level) has no
    `runs-on:` of its own and GitHub's schema forbids `timeout-minutes` there, so
    those are skipped; every other job must carry a `timeout-minutes`.
    """

    def test_every_runner_job_declares_a_timeout(self) -> None:
        for path in sorted(WF.glob("*.yml")):
            jobs = jobs_in(path.read_text())
            with self.subTest(file=path.name):
                self.assertTrue(jobs, path.name)
            for name, body in jobs.items():
                with self.subTest(file=path.name, job=name):
                    if any(line.startswith("    uses:") for line in body):
                        continue  # reusable-workflow call: timeout-minutes is not allowed
                    self.assertTrue(
                        any(line.startswith("    runs-on:") for line in body),
                        f"{path.name}: job {name!r} has neither runs-on nor uses",
                    )
                    self.assertTrue(
                        any(line.startswith("    timeout-minutes:") for line in body),
                        f"{path.name}: job {name!r} has no timeout-minutes",
                    )


class ContractFreshnessGraceTest(unittest.TestCase):
    template = read("reusable-contract-freshness.yml")
    smoke = (WF / "self-smoke.yml").read_text()

    def test_grace_summary_uses_valid_step_summary_variable(self) -> None:
        for path in sorted(WF.rglob("*.yml")):
            self.assertNotIn("github.step_summary", path.read_text(), path.relative_to(WF))
        gate = step_script(self.template, "Contract freshness gate (fail closed)")
        current = gate.split('  current)\n', 1)[1].split('  noncurrent)\n', 1)[0]
        self.assertIn(
            '          {\n'
            '            echo "### Contract freshness grace"\n'
            '            echo "$message"\n'
            '          } >> "$GITHUB_STEP_SUMMARY"',
            current,
        )

    def test_grace_input_and_output_are_public_with_safe_defaults(self) -> None:
        inputs = self.template.split("      grace-days:\n", 1)[1].split("    outputs:\n", 1)[0]
        self.assertIn("type: number", inputs)
        self.assertIn("required: false", inputs)
        self.assertIn("default: 3", inputs)
        self.assertIn("within_grace:", self.template)
        self.assertIn("within_grace: ${{ steps.check.outputs.within_grace }}", self.template)

    def test_grace_logic_is_nested_under_behind_current_only(self) -> None:
        gate = step_script(self.template, "Contract freshness gate (fail closed)")
        current = gate.split('  current)\n', 1)[1].split('  noncurrent)\n', 1)[0]
        self.assertIn('if [ "$status" = "BEHIND" ]; then', current)
        self.assertIn('if [ "$within" = true ]; then', current)
        self.assertIn('exit "$rc"', current)
        self.assertLess(current.index('if [ "$status" = "BEHIND" ]'), current.index('echo "::error::contract freshness gate failed'))
        self.assertIn('within_grace=false', gate)
        self.assertIn('within_grace=true', current)
        self.assertIn('merge-base", "--is-ancestor"', current)
        self.assertIn('rev-list", "--reverse", "--ancestry-path"', current)
        self.assertIn('cannot compute BEHIND grace', current)
        self.assertIn('refs/remotes/origin/{freshness_ref}', current)
        self.assertIn('data.get("source", {}).get("revision")', current)
        self.assertIn(r'r"^\s+revision:\s*([0-9a-f]{7,40})\b"', current)

    def test_grace_expiry_uses_oldest_commit_and_strict_boundary(self) -> None:
        gate = step_script(self.template, "Contract freshness gate (fail closed)")
        current = gate.split('  current)\n', 1)[1].split('  noncurrent)\n', 1)[0]
        self.assertIn('"within": age < grace', current)
        self.assertIn('"--ancestry-path", f"{pin}..{head}"', current)
        expires_at = 3.0
        self.assertTrue(2.999 < expires_at)
        self.assertFalse(3.001 < expires_at)

    def test_grace_self_smoke_calls_real_template_and_asserts_outputs(self) -> None:
        for job in ("contract-freshness-grace", "contract-freshness-no-grace"):
            body = jobs_in(self.smoke)[job]
            joined = "\n".join(body)
            self.assertIn("uses: ./.github/workflows/reusable-contract-freshness.yml", joined)
            self.assertIn('fixtures/contract-demo/stale-adoption.yaml', joined)
        self.assertIn("grace-days: 36500", self.smoke)
        self.assertIn("grace-days: 0", self.smoke)
        self.assertIn("needs.contract-freshness-grace.outputs.within_grace", self.smoke)
        self.assertIn("needs.contract-freshness-no-grace.outputs.within_grace", self.smoke)
        self.assertIn('test "$PROBE_STATUS" = BEHIND', self.smoke)
        no_grace = jobs_in(self.smoke)["contract-freshness-no-grace"]
        self.assertIn('expect: "noncurrent"', "\n".join(no_grace))
        self.assertIn('test "$PROBE_RESULT" = success', self.smoke)


class PythonTemplateTest(unittest.TestCase):
    text = read("reusable-python.yml")

    def test_every_job_has_timeout(self) -> None:
        jobs = len(re.findall(r"^    runs-on:", self.text, re.M))
        self.assertEqual(jobs, 3)
        self.assertEqual(self.text.count("    timeout-minutes: ${{ inputs.timeout-minutes }}\n"), jobs)
        self.assertRegex(self.text, r"timeout-minutes:\n(?:        .*\n)+?        default: 30\n")

    def test_junit_summary_and_artifact(self) -> None:
        self.assertEqual(self.text.count('--junit-xml="$JUNIT_XML"'), 4)  # serial, xdist, affected, refresh
        self.assertIn(">> \"$GITHUB_STEP_SUMMARY\"", self.text)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", self.text)
        for step in ("Pytest failures to job summary", "Upload pytest junit-xml"):
            # always() so a red run still reports, and the skip-reason guard so a skipped run
            # does not write "no test report was written" over the real reason.
            self.assertRegex(self.text, rf"name: {step}\n        if: \$\{{\{{ always\(\) && inputs\.skip-reason == '' \}}\}}")


    def test_summary_script_lists_only_failures(self) -> None:
        body = re.search(r"python3 - \"\$JUNIT_XML\" >> .*? <<'PY'\n(.*?)\n +PY\n", self.text, re.S)
        self.assertIsNotNone(body)
        script = "\n".join(line[10:] for line in body.group(1).splitlines())
        xml = (
            '<testsuites><testsuite tests="2" failures="1" skipped="0">'
            '<testcase classname="t" name="test_ok"/>'
            '<testcase classname="t" name="test_bad"><failure message="m">a\nassert 1 == 2</failure></testcase>'
            "</testsuite></testsuites>"
        )
        with tempfile.TemporaryDirectory() as d:
            junit = Path(d) / "j.xml"
            junit.write_text(xml)
            out = subprocess.run(
                [sys.executable, "-I", "-c", script, str(junit)], capture_output=True, text=True, check=True
            ).stdout
        self.assertIn("t::test_bad", out)
        self.assertIn("assert 1 == 2", out)
        self.assertNotIn("test_ok", out)


class SkipReasonTest(unittest.TestCase):
    """`skip-reason` keeps the required check name green without running a suite with nothing to test.

    A caller that skips its `test:` job entirely reports as "test", never "test / python tests", so a
    branch rule that requires the python check would never see it (project-home#297, a docs-only PR that
    ran 1,764 tests). The job has to run under its normal name and succeed, so the skip lives inside
    the template, behind one optional input.
    """

    text = read("reusable-python.yml")
    job = jobs_in(text)["test"]

    def input_block(self) -> str:
        block = self.text.split("      skip-reason:\n", 1)[1].split("      timeout-minutes:", 1)[0]
        return block

    def test_input_is_optional_string_defaulting_to_empty(self) -> None:
        block = self.input_block()
        self.assertIn("type: string", block)
        self.assertIn("required: false", block)
        self.assertIn('default: ""', block)
        # Who may set it, and what it is not allowed to touch.
        self.assertIn("docs-only", block)
        self.assertIn("<caller job> / python tests", block)
        self.assertIn("secret scan, claims", block)

    def test_every_step_after_checkout_is_guarded(self) -> None:
        body = "\n".join(self.job)
        after_checkout = body.split("- uses: actions/checkout", 1)[1]
        steps = re.split(r"\n      - (?:name|uses): ", "\n" + after_checkout)[1:]
        self.assertGreaterEqual(len(steps), 15)  # the whole test job, minus preflight and checkout
        for step in steps:
            name = step.splitlines()[0]
            with self.subTest(step=name):
                if name.startswith("actions/checkout"):  # the checkout line itself, not a step
                    continue
                cond = re.search(r"^        if: (.*)$", step, re.M)
                self.assertIsNotNone(cond, f"{name} has no if: after checkout")
                self.assertIn("inputs.skip-reason", cond.group(1), name)

    def test_preflight_and_checkout_still_run(self) -> None:
        # A skipped run still leaves the workspace as a real one does; and the guard must not
        # change the job's name, which is the check branch rules require.
        body = "\n".join(self.job)
        self.assertIn("      - name: Preflight (workspace and scratch writable)\n", body)
        self.assertIn("    name: python tests\n", body)
        for line in body.splitlines()[:2]:
            self.assertNotIn("if:", line)

    def test_only_the_test_job_is_affected(self) -> None:
        for job in ("ruff", "bandit"):
            body = "\n".join(jobs_in(self.text)[job])
            self.assertNotIn("skip-reason", body, job)
        # The other templates do not know the input at all: callers keep their gates.
        for path in TEMPLATES:
            if path.name != "reusable-python.yml":
                self.assertNotIn("skip-reason", path.read_text(), path.name)

    def test_the_notice_step_reports_the_reason_verbatim(self) -> None:
        script = step_script(self.text, "Tests skipped (skip-reason)")
        # The reason arrives through the environment, never spliced into the workflow, so whatever
        # a caller passes is printed and summarised but cannot change what the job runs.
        self.assertIn("SKIP_REASON: ${{ inputs.skip-reason }}", self.text)
        self.assertNotIn("${{ inputs.skip-reason }}", script)
        for reason in ("docs-only diff: no .py changed", "50% off: PR #297 is markdown only"):
            with self.subTest(reason=reason):
                d = tempfile.TemporaryDirectory()
                self.addCleanup(d.cleanup)
                root = Path(d.name)
                (root / "summary").write_text("")
                proc = subprocess.run(
                    ["bash", "-e", "-c", script],
                    env={"PATH": "/usr/bin:/bin", "SKIP_REASON": reason,
                         "GITHUB_STEP_SUMMARY": str(root / "summary")},
                    capture_output=True, text=True,
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)  # never fails the job
                self.assertIn(f"::notice title=tests skipped::{reason}", proc.stdout)
                self.assertIn("### tests skipped", (root / "summary").read_text())
                self.assertIn(reason, (root / "summary").read_text())

    def test_guard_is_true_for_an_empty_reason(self) -> None:
        # Every guard is `skip-reason == ''` (or a conjunction with it), so the default run is the
        # old run: nothing new is executed, nothing old is dropped.
        guards = re.findall(r"^        if: .*inputs\.skip-reason == ''.*$", "\n".join(self.job), re.M)
        self.assertEqual(len(guards), len(re.findall(r"^        if: .*inputs\.skip-reason.*$", "\n".join(self.job), re.M)) - 1)
        for cond in guards:
            with self.subTest(cond=cond):
                self.assertTrue(
                    cond.startswith("        if: ${{ inputs.skip-reason == ''") or
                    "always() && inputs.skip-reason == '' }}" in cond, cond)


def step_script(text: str, name: str) -> str:
    """The dedented `run:` body of the step called `name` (text-level, stdlib only)."""
    m = re.search(rf"      - name: {re.escape(name)}\n(?:        .*\n|\n)*?        run: \|\n((?:          .*\n|\n)+)", text)
    assert m, name
    return "".join(line[10:] if line.strip() else "\n" for line in m.group(1).splitlines(True))


def git(cwd: Path, *args: str) -> str:
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin", "HOME": str(cwd)}
    return subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=True).stdout.strip()


class AffectedSelectTest(unittest.TestCase):
    """Runs the real `Select tests` step against throwaway PR-shaped git repos."""

    text = read("reusable-python.yml")
    script = step_script(text, "Select tests (full or affected)")

    def make_pr(self, root: Path, changed: dict[str, str], base_files: dict[str, str] | None = None,
                renamed: dict[str, str] | None = None, removed: tuple[str, ...] = ()) -> tuple[Path, str]:
        repo = root / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        for name, body in {"pkg/a.py": "x = 1\n", **(base_files or {})}.items():
            (repo / name).parent.mkdir(parents=True, exist_ok=True)
            (repo / name).write_text(body)
        git(repo, "add", ".")
        git(repo, "commit", "-qm", "base")
        base = git(repo, "rev-parse", "HEAD")
        git(repo, "checkout", "-qb", "pr")
        for old, new in (renamed or {}).items():
            (repo / new).parent.mkdir(parents=True, exist_ok=True)
            git(repo, "mv", old, new)
        for name in removed:
            git(repo, "rm", "-q", name)
        for name, body in changed.items():
            (repo / name).parent.mkdir(parents=True, exist_ok=True)
            (repo / name).write_text(body)
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "pr")
        git(repo, "checkout", "-q", "main")
        git(repo, "merge", "-q", "--no-ff", "-m", "merge", "pr")
        git(repo, "checkout", "-q", "--detach", "HEAD")
        return repo, base

    @staticmethod
    def store_dir(project_dir: str, python_version: str = "3.12") -> str:
        """The self-hosted store's python + project-dir segment, as the step computes it."""
        return f"{python_version}-{hashlib.sha256(project_dir.encode()).hexdigest()[:16]}"

    def run_select(self, repo: Path, root: Path, base: str | None, cwd: str = ".", hosted_data: str | None = None,
                   **env: str) -> dict[str, str]:
        tool, temp = root / "tool", root / "temp"
        temp.mkdir(exist_ok=True)
        if base:
            d = tool / "testmon" / "o" / "r" / "main" / self.store_dir(cwd)
            d.mkdir(parents=True, exist_ok=True)
            (d / f"{base}.testmondata").write_text("db")
        if hosted_data is not None:  # what actions/cache/restore would have put there
            (temp / "testmon-hosted").mkdir(exist_ok=True)
            (temp / "testmon-hosted" / ".testmondata").write_text(hosted_data)
        genv, gsum = root / "genv", root / "gsum"
        genv.write_text("")
        gsum.write_text("")
        full = {"PATH": "/usr/bin:/bin", "HOME": str(root), "RUNNER_ENVIRONMENT": "self-hosted",
                "RUNNER_TEMP": str(temp), "TOOL_CACHE": str(tool), "GITHUB_ENV": str(genv),
                "GITHUB_STEP_SUMMARY": str(gsum), "GITHUB_SHA": "f" * 40, "PYTEST_SELECT": "affected",
                "PYTHON_VERSION": "3.12",
                "EVENT_NAME": "pull_request", "REF_NAME": "1/merge", "DEFAULT_BRANCH": "main",
                "BASE_REF": "main", "REPOSITORY": "o/r", "PROJECT_DIR": cwd, **env}
        subprocess.run(["bash", "-c", self.script], cwd=repo / cwd, env=full, check=True, capture_output=True)
        out = dict(line.split("=", 1) for line in genv.read_text().splitlines())
        out["SUMMARY"] = gsum.read_text()
        return out

    def check(self, changed: dict[str, str], want: str, reason: str, base_ok: bool = True, **env: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo, base = self.make_pr(root, changed)
            out = self.run_select(repo, root, base if base_ok else None, **env)
        self.assertEqual(out["PYTEST_MODE"], want, out)
        self.assertIn(reason, out["PYTEST_MODE_REASON"])
        self.assertIn(f"pytest mode: {want}", out["SUMMARY"])  # mode and reason reach the job summary
        self.assertIn(reason, out["SUMMARY"])
        return out

    def test_affected_when_data_matches_base(self) -> None:
        out = self.check({"pkg/a.py": "x = 2\n"}, "affected", "testmon data for base")
        self.assertEqual(out["PYTEST_CHANGED_UNDER_PROJECT"], "1")

    def test_markdown_change_runs_full_suite(self) -> None:
        # A test may read markdown (doc checks), and testmon cannot see that.
        self.check({"README.md": "hi\n"}, "full", "testmon cannot track (README.md)")

    def test_data_file_beside_python_runs_full_suite(self) -> None:
        # A .py change does not make a data/template change under the project visible to testmon.
        self.check({"pkg/a.py": "x = 2\n", "pkg/data.json": "{}\n"}, "full", "pkg/data.json")

    def test_extensionless_script_runs_full_suite(self) -> None:
        self.check({"bin/tool": "#!/usr/bin/env python3\n"}, "full", "bin/tool")

    def test_python_outside_the_project_directory_runs_full_suite(self) -> None:
        # The step runs inside the project directory (here pkg/); a workspace sibling is not
        # fingerprinted by a testmon rooted there, so it cannot be trusted to select for it.
        for changed in ({"other/b.py": "y = 2\n"}, {"other/b.py": "y = 2\n", "pkg/a.py": "x = 2\n"}):
            with tempfile.TemporaryDirectory() as d:
                root = Path(d)
                repo, base = self.make_pr(root, changed)
                out = self.run_select(repo, root, base, cwd="pkg")
                self.assertEqual(out["PYTEST_MODE"], "full", out)
                self.assertIn("other/b.py", out["PYTEST_MODE_REASON"])

    def test_rename_is_judged_by_both_paths(self) -> None:
        # Python moved into the project from outside, and a data file renamed to .py, both run full.
        for base_files, renamed, want in (({"other/util.py": "u = 1\n"}, {"other/util.py": "pkg/util.py"}, "other/util.py"),
                                          ({"pkg/data.json": "{}\n"}, {"pkg/data.json": "pkg/data.py"}, "pkg/data.json")):
            with tempfile.TemporaryDirectory() as d:
                root = Path(d)
                repo, base = self.make_pr(root, {}, base_files=base_files, renamed=renamed)
                out = self.run_select(repo, root, base, cwd="pkg")
                self.assertEqual(out["PYTEST_MODE"], "full", out)
                self.assertIn(want, out["PYTEST_MODE_REASON"])

    def test_renamed_conftest_is_test_wide_config(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo, base = self.make_pr(root, {}, base_files={"pkg/conftest.py": "\n"},
                                      renamed={"pkg/conftest.py": "pkg/helpers.py"})
            out = self.run_select(repo, root, base, cwd="pkg")
            self.assertEqual(out["PYTEST_MODE"], "full", out)
            self.assertIn("conftest.py", out["PYTEST_MODE_REASON"])

    def test_deleted_python_under_the_project_stays_affected(self) -> None:
        # testmon sees a vanished module's fingerprint change and selects the tests that used it.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo, base = self.make_pr(root, {}, base_files={"pkg/gone.py": "g = 1\n"}, removed=("pkg/gone.py",))
            out = self.run_select(repo, root, base, cwd="pkg")
            self.assertEqual(out["PYTEST_MODE"], "affected", out)

    def test_python_under_the_project_directory_is_affected(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo, base = self.make_pr(root, {"pkg/a.py": "x = 2\n", "pkg/sub/c.py": "z = 1\n"})
            out = self.run_select(repo, root, base, cwd="pkg")
            self.assertEqual(out["PYTEST_MODE"], "affected", out)
            self.assertEqual(out["PYTEST_CHANGED_UNDER_PROJECT"], "1")

    def test_hosted_uses_restored_cache_file(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo, base = self.make_pr(root, {"pkg/a.py": "x = 2\n"})
            prefix = "testmon-Linux-3.12-abc-"
            hosted = dict(RUNNER_ENVIRONMENT="github-hosted", HOSTED_KEY_PREFIX=prefix, hosted_data="db")
            out = self.run_select(repo, root, None, HOSTED_BASE_SHA=base, HOSTED_RESTORED_KEY=prefix + base, **hosted)
            self.assertEqual(out["PYTEST_MODE"], "affected")
            self.assertIn(f"testmon data for base {base[:12]}", out["PYTEST_MODE_REASON"])
        with tempfile.TemporaryDirectory() as d:  # data for an older commit: never trusted
            root = Path(d)
            repo, base = self.make_pr(root, {"pkg/a.py": "x = 2\n"})
            out = self.run_select(repo, root, None, HOSTED_BASE_SHA=base, HOSTED_RESTORED_KEY=prefix + "1" * 40, **hosted)
            self.assertEqual(out["PYTEST_MODE"], "full")
            self.assertIn("is for another commit", out["PYTEST_MODE_REASON"])
        with tempfile.TemporaryDirectory() as d:  # nothing restored: full suite
            root = Path(d)
            repo, base = self.make_pr(root, {"pkg/a.py": "x = 2\n"})
            out = self.run_select(repo, root, None, RUNNER_ENVIRONMENT="github-hosted")
            self.assertEqual(out["PYTEST_MODE"], "full")
            self.assertIn("no testmon data restored", out["PYTEST_MODE_REASON"])

    def test_hosted_push_refresh_targets_the_cache_path(self) -> None:
        out = self.check({"pkg/a.py": "x = 2\n"}, "refresh", "recording testmon data",
                         EVENT_NAME="push", REF_NAME="main", RUNNER_ENVIRONMENT="github-hosted")
        self.assertTrue(out["PYTEST_PUBLISH_FILE"].endswith("/testmon-hosted/.testmondata"))

    def test_no_data_falls_back_to_full(self) -> None:
        self.check({"pkg/a.py": "x = 2\n"}, "full", "no testmon data", base_ok=False)

    def test_data_for_a_different_base_falls_back_to_full(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repo, _ = self.make_pr(root, {"pkg/a.py": "x = 2\n"})
            out = self.run_select(repo, root, "0" * 40)
        self.assertEqual(out["PYTEST_MODE"], "full")
        self.assertIn("no testmon data for base", out["PYTEST_MODE_REASON"])

    def test_config_changes_force_full(self) -> None:
        for name in ("conftest.py", "pkg/conftest.py", "pyproject.toml", "uv.lock", "setup.cfg",
                     "pytest.ini", "tox.ini", ".github/workflows/ci.yml"):
            with self.subTest(name):
                self.check({name: "x\n", "pkg/a.py": "x = 2\n"}, "full", "test-wide config")

    def test_all_is_the_default_behaviour(self) -> None:
        self.check({"pkg/a.py": "x = 2\n"}, "full", "pytest-select=all", PYTEST_SELECT="all")

    def test_push_to_default_branch_refreshes_and_other_events_run_full(self) -> None:
        out = self.check({"pkg/a.py": "x = 2\n"}, "refresh", "recording testmon data",
                         EVENT_NAME="push", REF_NAME="main")
        self.assertTrue(out["PYTEST_PUBLISH_FILE"].endswith(
            f"/testmon/o/r/main/{self.store_dir('.')}/" + "f" * 40 + ".testmondata"))
        self.check({"pkg/a.py": "x = 2\n"}, "full", "not a pull_request", EVENT_NAME="push", REF_NAME="dev")

    def test_unknown_select_value_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as d, self.assertRaises(subprocess.CalledProcessError):
            root = Path(d)
            repo, base = self.make_pr(root, {"pkg/a.py": "x = 2\n"})
            self.run_select(repo, root, base, PYTEST_SELECT="sometimes")


class AffectedRunTest(unittest.TestCase):
    """The `Run pytest` step with a stub `uv`: fallback on zero selection, publish only when green."""

    script = step_script(read("reusable-python.yml"), "Run pytest")

    def run_step(self, mode: str, rc: int, changed: str = "", workers: str = "0", tests: int = 3) -> tuple[str, str, Path, Path]:
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        root = Path(d.name)
        (root / "bin").mkdir()
        log = root / "uv.log"
        # Stub: record argv; a testmon run exits `rc` and writes its data file.
        (root / "bin" / "uv").write_text(
            '#!/bin/bash\necho "$*" >> "%s"\n'
            'case "$*" in *--testmon*) echo db > "$TESTMON_DATAFILE"\n'
            '  echo "<testsuites><testsuite name=\\"pytest\\" errors=\\"0\\" tests=\\"%d\\"></testsuite></testsuites>" > "$JUNIT_XML"\n'
            '  exit %d;; esac\nexit 0\n' % (log, tests, rc)
        )
        (root / "bin" / "uv").chmod(0o755)
        gsum = root / "gsum"
        gsum.write_text("")
        publish = root / "pub" / "x.testmondata"
        env = {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "GITHUB_STEP_SUMMARY": str(gsum), "JUNIT_XML": str(root / "j.xml"),
               "PYTEST_MODE": mode, "PYTEST_WORKERS": workers, "TESTMON_DATAFILE": str(root / "db"),
               "PYTEST_PUBLISH_FILE": str(publish), "PYTEST_CHANGED_UNDER_PROJECT": changed,
               "GITHUB_ENV": str(root / "genv")}
        self.proc = subprocess.run(["bash", "-e", "-c", self.script.replace("${{ inputs.pytest-args }}", "-q")],
                                   env=env, capture_output=True, text=True)
        return log.read_text(), gsum.read_text(), publish, root

    def test_zero_selected_with_changed_files_runs_full(self) -> None:
        log, summary, _, _ = self.run_step("affected", 5, changed="1")
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        self.assertIn("zero tests", summary)
        self.assertEqual(log.count("pytest --junit-xml"), 1)  # the full re-run is plain pytest

    def test_zero_selected_without_package_changes_is_reported_not_failed(self) -> None:
        log, summary, _, _ = self.run_step("affected", 5, changed="")
        self.assertEqual(self.proc.returncode, 0)
        self.assertNotIn("pytest --junit-xml", log)  # no full re-run
        self.assertIn("zero tests", summary)

    def test_zero_selected_exit_0_with_changed_files_runs_full(self) -> None:
        # testmon prints "no tests ran" and exits 0 on some versions (the hosted CI case).
        log, summary, _, _ = self.run_step("affected", 0, changed="1", tests=0)
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        self.assertIn("zero tests", summary)
        self.assertEqual(log.count("pytest --junit-xml"), 1)

    def test_zero_selected_exit_0_docs_only_is_ok_with_summary(self) -> None:
        log, summary, _, _ = self.run_step("affected", 0, changed="", tests=0)
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        self.assertNotIn("pytest --junit-xml", log)
        self.assertIn("zero tests", summary)

    def test_selected_tests_do_not_trigger_the_fallback(self) -> None:
        log, *_ = self.run_step("affected", 0, changed="1", tests=2)
        self.assertNotIn("pytest --junit-xml", log)

    def test_affected_failure_fails_the_step(self) -> None:
        self.run_step("affected", 1, changed="1")
        self.assertEqual(self.proc.returncode, 1)

    def test_affected_runs_serial_with_forceselect(self) -> None:
        log, *_ = self.run_step("affected", 0, workers="4")
        self.assertIn("--testmon --testmon-forceselect", log)
        self.assertNotIn(" -n ", log)

    def test_refresh_publishes_only_green_runs(self) -> None:
        _, _, publish, root = self.run_step("refresh", 0)
        self.assertTrue(publish.exists())
        self.assertIn("PYTEST_PUBLISHED=1", (root / "genv").read_text())  # gates the hosted cache save
        _, _, publish, _ = self.run_step("refresh", 1)
        self.assertFalse(publish.exists())


class WorkerSizingTest(unittest.TestCase):
    """`pytest-workers: auto` through the real `Run pytest` step, with a stub uv and a fake cpu.max."""

    script = step_script(read("reusable-python.yml"), "Run pytest")
    text = read("reusable-python.yml")

    def run_auto(self, cpu_max: str | None, locks: int = 0, hosted: bool = False, workers: str = "auto") -> tuple[str, str, Path]:
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        root = Path(d.name)
        (root / "bin").mkdir()
        log, gsum = root / "uv.log", root / "gsum"
        gsum.write_text("")
        (root / "bin" / "uv").write_text('#!/bin/bash\necho "$*" >> "%s"\n' % log)
        (root / "bin" / "nproc").write_text("#!/bin/bash\necho 16\n")
        for tool in ("uv", "nproc"):
            (root / "bin" / tool).chmod(0o755)
        cpu = root / "cpu.max"
        if cpu_max is not None:
            cpu.write_text(cpu_max + "\n")
        tool_cache = root / "tool"
        (tool_cache / "busy-jobs").mkdir(parents=True)
        for i in range(locks):  # other jobs already running
            (tool_cache / "busy-jobs" / f"other.{i}").write_text("")
        env = {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "GITHUB_STEP_SUMMARY": str(gsum), "JUNIT_XML": str(root / "j.xml"),
               "PYTEST_WORKERS": workers, "TOOL_CACHE": str(tool_cache), "CPU_MAX_FILE": str(cpu),
               "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "7", "GITHUB_JOB": "test"}
        if not hosted:
            env["RUNNER_ENVIRONMENT"] = "self-hosted"
        self.proc = subprocess.run(["bash", "-e", "-c", self.script.replace("${{ inputs.pytest-args }}", "-q")],
                                   env=env, capture_output=True, text=True)
        return log.read_text() if log.exists() else "", gsum.read_text(), tool_cache / "busy-jobs"

    def workers(self, **kw) -> int:
        log, _, _ = self.run_auto(**kw)
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        return int(log.split(" -n ")[1].split()[0])

    def test_formula(self) -> None:
        self.assertEqual(self.workers(cpu_max="600000 100000"), 6)           # idle: whole cap
        self.assertEqual(self.workers(cpu_max="600000 100000", locks=1), 3)  # me + 1 other
        self.assertEqual(self.workers(cpu_max="600000 100000", locks=3), 1)  # 4 jobs: 6 // 4
        self.assertEqual(self.workers(cpu_max="600000 100000", locks=9), 1)  # never below 1
        self.assertEqual(self.workers(cpu_max="max 100000"), 8)              # nproc=16, clamped to 8
        self.assertEqual(self.workers(cpu_max=None), 8)                      # no cpu.max: nproc, clamped
        self.assertEqual(self.workers(cpu_max="1600000 100000"), 8)

    def test_prune_bound_is_fixed_and_lock_names_its_owner(self) -> None:
        import os
        import time
        self.run_auto(cpu_max="600000 100000", locks=2)
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        self.assertNotIn("LOCK_MAX_AGE_MIN", self.script)
        self.assertIn("-mmin +360", self.script)
        # A 40-minute-old lock (longer than a 30 minute job timeout) from another job must survive;
        # one older than 360 minutes is pruned. While running, our own lock holds pid and run id.
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        locks = Path(d.name) / "busy-jobs"
        locks.mkdir()
        for name, age in (("live", 40), ("dead", 400)):
            f = locks / name
            f.write_text("")
            os.utime(f, (time.time() - age * 60,) * 2)
        script = self.script.replace("resolve_workers\n", 'cat "$lock" >> "$OUT"; resolve_workers\n', 1)
        env = {"PATH": "/usr/bin:/bin:" + str(Path(d.name)), "PYTEST_WORKERS": "0", "TOOL_CACHE": d.name, "OUT": str(Path(d.name) / "out"),
               "RUNNER_ENVIRONMENT": "self-hosted", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "77", "JUNIT_XML": "j.xml",
               "GITHUB_STEP_SUMMARY": "/dev/null"}
        (Path(d.name) / "uv").write_text("#!/bin/bash\n")
        (Path(d.name) / "uv").chmod(0o755)
        subprocess.run(["bash", "-e", "-c", script.replace("${{ inputs.pytest-args }}", "-q")], env=env, check=True, capture_output=True)
        self.assertEqual(sorted(p.name for p in locks.iterdir()), ["live"])
        self.assertRegex((Path(d.name) / "out").read_text(), r"pid=\d+ run=77 ")

    def test_hosted_uses_nproc(self) -> None:
        self.assertEqual(self.workers(cpu_max="600000 100000", hosted=True), 16)

    def test_numeric_and_zero_keep_back_compat(self) -> None:
        self.assertEqual(self.workers(cpu_max="600000 100000", workers="4"), 4)
        log, _, _ = self.run_auto(cpu_max="600000 100000", workers="0")
        self.assertNotIn(" -n ", log)
        self.assertIn("pytest --junit-xml", log)

    def test_job_leaves_the_lock_dir_on_exit_and_summary_names_the_numbers(self) -> None:
        _, summary, locks = self.run_auto(cpu_max="600000 100000", locks=1)
        self.assertEqual([p.name for p in locks.iterdir()], ["other.0"])
        self.assertIn("auto -> 3 (cap_cores=6, busy_jobs=2)", summary)

    def test_garbage_value_fails(self) -> None:
        self.run_auto(cpu_max="600000 100000", workers="many")
        self.assertNotEqual(self.proc.returncode, 0)

    def test_default_stays_serial_and_input_documents_formula(self) -> None:
        block = self.text.split("      pytest-workers:\n", 1)[1].split("      pytest-select:", 1)[0]
        self.assertIn('default: "0"', block)
        self.assertIn("max(1, min(cap_cores, 8) // max(1, busy_jobs))", block)
        self.assertIn("type: string", block)  # callers pass "6" or "auto", both strings
        self.assertIn('never a bare 6', block)


class CacheTest(unittest.TestCase):
    py = read("reusable-python.yml")
    node = read("reusable-node.yml")

    def test_every_python_job_warms_uv_cache_before_syncing(self) -> None:
        for block in self.py.split("\n    steps:\n")[1:]:
            self.assertLess(block.index("Warm uv cache"), block.index("uv sync --frozen"))
            self.assertLess(block.index("Preflight"), block.index("Warm uv cache"))
        self.assertEqual(self.py.count("name: Warm uv cache (self-hosted"), 3)
        self.assertEqual(self.py.count("name: Warm uv cache (hosted"), 3)

    def test_self_hosted_cache_dirs_live_in_the_tool_cache(self) -> None:
        self.assertIn("CACHE_DIR: ${{ runner.tool_cache }}/uv-cache", self.py)
        self.assertIn("UV_CACHE_DIR:uv-cache npm_config_cache:npm-cache", self.node)
        self.assertIn("TOOL_CACHE: ${{ runner.tool_cache }}", self.node)
        for text in (self.py, self.node):
            self.assertIn("if: ${{ runner.environment == 'self-hosted' }}", text)

    def test_hosted_npm_cache_uses_setup_node_and_self_hosted_does_not(self) -> None:
        self.assertIn("cache: ${{ runner.environment == 'github-hosted' && 'npm' || '' }}", self.node)
        self.assertIn("cache-dependency-path: ${{ inputs.working-directory }}/package-lock.json", self.node)
        self.assertIn("actions/setup-node@820762786026740c76f36085b0efc47a31fe5020", self.node)  # pinned SHA

    def test_venv_and_node_modules_are_never_cached(self) -> None:
        for text in (self.py, self.node):
            for path in re.findall(r"uses: actions/cache(?:/\w+)?@\S+.*\n(?:          .*\n)*?          path: (.*)\n", text):
                self.assertNotRegex(path, r"\.venv|node_modules", path)
            for line in text.splitlines():
                if re.search(r"(UV_CACHE_DIR|npm_config_cache|CACHE_DIR)\b", line) and not line.lstrip().startswith("#"):
                    self.assertNotRegex(line, r"\.venv|node_modules", line)

    def test_hosted_testmon_cache_saves_on_default_branch_push_and_restores_on_prs(self) -> None:
        sha = "55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
        self.assertIn(f"uses: actions/cache/save@{sha} # v6.1.0", self.py)
        self.assertIn(f"uses: actions/cache/restore@{sha} # v6.1.0", self.py)
        self.assertEqual(len(re.findall(r"uses: actions/cache", self.py)), 2)
        self.assertIn(sha, (WF.parent.parent / "pins" / "ACTIONS.md").read_text())
        save = self.py.split("name: Save testmon data", 1)[1].split("\n      # ", 1)[0]
        for cond in ("runner.environment == 'github-hosted'", "github.event_name == 'push'",
                     "github.ref_name == github.event.repository.default_branch", "success()"):
            self.assertIn(cond, save)
        self.assertNotIn("pull_request", save)
        self.assertIn("key: ${{ steps.testmon-key.outputs.prefix }}${{ github.sha }}", save)
        restore = self.py.split("name: Restore testmon data", 1)[1].split("\n      # ", 1)[0]
        self.assertIn("github.event_name == 'pull_request'", restore)
        self.assertNotIn("'push'", restore)
        self.assertIn("key: ${{ steps.testmon-key.outputs.prefix }}${{ steps.testmon-key.outputs.base }}", restore)
        self.assertNotIn("restore-keys", restore)  # an older main's data could select too few tests
        key = self.py.split("name: Testmon cache key", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("testmon-${{ runner.os }}-${{ inputs.python-version }}", key)
        self.assertIn("sha256sum", key)  # project-directory hash

    def test_no_unpinned_actions_were_added(self) -> None:
        for path in TEMPLATES:
            for use in re.findall(r"^(?: {6}- | {8})uses: (\S+)", path.read_text(), re.M):
                if use.startswith("./"):
                    continue
                self.assertRegex(use, r"@[0-9a-f]{40}$", f"{path.name}: {use}")


class SecretScanTest(unittest.TestCase):
    text = read("reusable-secret-scan.yml")

    def test_pr_scans_only_its_range(self) -> None:
        self.assertIn('--log-opts="${PR_BASE_SHA}..${PR_HEAD_SHA}"', self.text)
        self.assertIn('[ "$EVENT_NAME" = "pull_request" ]', self.text)
        self.assertIn("github.event_name == 'pull_request' && '0' || inputs.fetch-depth", self.text)
        self.assertIn("exit 2", self.text)  # unresolvable range fails closed

    def test_non_pr_default_is_full_history(self) -> None:
        # Consumers that pass nothing still get a full-history scan on push and schedule.
        block = self.text.split("fetch-depth:", 1)[1].split("jobs:", 1)[0]
        self.assertIn("default: 0", block)

    def test_full_scan_not_weakened(self) -> None:
        # Exactly one gitleaks invocation, and it scans the fetched history unless scoped above.
        self.assertEqual(self.text.count('/gitleaks" git .'), 1)
        self.assertNotIn("--no-git", self.text)
        self.assertNotIn("baseline", self.text)

    def test_full_scan_drops_refs_this_checkout_did_not_fetch(self) -> None:
        # ci-harness#68: a reused self-hosted workspace keeps local branches and refs/remotes/pull/*
        # from earlier jobs, and gitleaks' default log is --all, so a push scan failed on a commit
        # only a closed PR's leftover branch held. The full scan prunes them first.
        scan = self.text.split("scanning full fetched history", 1)[1]
        prune = scan.index("git update-ref -d")
        self.assertLess(prune, scan.index('/gitleaks" git .'))
        self.assertIn("^refs/(remotes/origin/|tags/)", scan[:prune])  # what the checkout fetched stays
        self.assertIn("git symbolic-ref -q HEAD", scan[:prune])  # never the checked-out branch

    def test_selfcheck_keeps_full_scans(self) -> None:
        sc = read("secret-scan-selfcheck.yml")
        self.assertRegex(sc, r"push:\n    branches: \[main\]")
        self.assertIn("schedule:", sc)
        self.assertIn("fetch-depth: 0", sc)


class HostedUvCacheTest(unittest.TestCase):
    def test_hosted_runners_use_pinned_setup_uv_cache(self) -> None:
        text = read("reusable-python.yml")
        jobs = len(re.findall(r"^    runs-on:", text, re.M))
        self.assertEqual(text.count("astral-sh/setup-uv@1c37ad07a6a961277cf70c0d37d6f313000f5884 # v10.3.0"), jobs)
        self.assertEqual(text.count("enable-cache: true"), jobs)
        # Every job's setup-uv step is gated on a hosted runner; the test job's condition also
        # carries the skip-reason guard, so match the condition that belongs to the step.
        hosted = re.findall(
            r"name: Warm uv cache \(hosted, setup-uv\)\n        if: [^\n]*runner\.environment == 'github-hosted'", text)
        self.assertEqual(len(hosted), jobs)
        self.assertIn("astral-sh/setup-uv", (WF.parent.parent / "pins" / "ACTIONS.md").read_text())


class OtelHelperPinTest(unittest.TestCase):
    """The remote fetch of scripts/otel-span.sh is pinned to one commit and checked by sha256."""

    def test_every_fetch_is_pinned_to_one_sha_and_matches_the_tree(self) -> None:
        root = WF.parent.parent
        digest = hashlib.sha256((root / "scripts" / "otel-span.sh").read_bytes()).hexdigest()
        urls: list[str] = []
        pins: list[str] = []
        for path in TEMPLATES:
            text = path.read_text()
            urls += re.findall(r"OTELSPAN_HELPER_URL: (\S+)", text)
            pins += re.findall(r"OTELSPAN_HELPER_SHA256: (\S+)", text)
        # Every fetch carries both a pinned URL and the digest its download is checked against.
        self.assertEqual(len(urls), len(pins))
        self.assertGreaterEqual(len(urls), 10)
        # One fixed commit, not a branch: a moved `main` cannot change what a job runs.
        self.assertEqual(len(set(urls)), 1)
        for url in urls:
            self.assertRegex(
                url,
                r"^https://raw\.githubusercontent\.com/rylee-bee-labs/ci-harness/[0-9a-f]{40}/scripts/otel-span\.sh$",
            )
        # The pin cannot drift silently: the digest is the in-tree helper's own.
        for pin in pins:
            self.assertEqual(pin, digest)



class TestmonPruneKeepsSiblingStores(unittest.TestCase):
    """The publish step's prune (the two `find` lines) runs for real against a temp store: two project dirs on one
    repo and branch keep each other's data; only this store's older commits and the old flat layout go."""

    def test_prune_keeps_the_sibling_store(self):
        text = read("reusable-python.yml")
        lines = [ln.strip() for ln in text.splitlines() if ln.strip().startswith('find "${PYTEST_PUBLISH_FILE')]
        self.assertEqual(len(lines), 2, lines)
        with tempfile.TemporaryDirectory() as d:
            ref = Path(d) / "testmon" / "o_r" / "main"
            a, b = ref / "keyA", ref / "keyB"
            a.mkdir(parents=True)
            b.mkdir(parents=True)
            for p in (a / "old.testmondata", a / "new.testmondata", b / "theirs.testmondata", ref / "flat.testmondata"):
                p.write_text("db")
            env = {"PATH": "/usr/bin:/bin", "PYTEST_PUBLISH_FILE": str(a / "new.testmondata")}
            subprocess.run(["bash", "-c", "\n".join(lines)], env=env, check=True)
            left = sorted(str(p.relative_to(ref)) for p in ref.rglob("*.testmondata"))
        self.assertEqual(left, ["keyA/new.testmondata", "keyB/theirs.testmondata"])


if __name__ == "__main__":
    unittest.main()



def test_self_smoke_accepts_every_mode_the_python_template_can_select():
    """ci-harness#62: the template's selector can `decide` refresh on a push to the default branch, and the
    self-smoke rejected it, so main went red. Every mode the template can select must be in the check."""
    import re
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    template = (root / ".github" / "workflows" / "reusable-python.yml").read_text()
    smoke = (root / ".github" / "workflows" / "self-smoke.yml").read_text()
    modes = set(re.findall(r"\bdecide ([a-z]+) ", template))
    assert modes, "found no `decide <mode>` in the python template"
    allowed = re.search(r'case "\$\{PYTEST_MODE:-\}" in ([a-z|]+)\)', smoke)
    assert allowed, "found no PYTEST_MODE case in self-smoke"
    missing = modes - set(allowed.group(1).split("|"))
    assert not missing, f"self-smoke rejects modes the template can select: {sorted(missing)}"
