"""Static contracts for the reusable templates (stdlib only, text-level).

actionlint proves the workflows parse; these prove the CI-friction fixes stay in place:
the preflight is every job's first step, every runner job in every workflow is bounded,
reusable-python reports failures, and the secret scan stays narrow on PRs but full
everywhere else.
"""
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
            self.assertTrue(jobs, path.name)
            for name, body in jobs.items():
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


class PythonTemplateTest(unittest.TestCase):
    text = read("reusable-python.yml")

    def test_every_job_has_timeout(self) -> None:
        jobs = len(re.findall(r"^    runs-on:", self.text, re.M))
        self.assertEqual(jobs, 3)
        self.assertEqual(self.text.count("    timeout-minutes: ${{ inputs.timeout-minutes }}\n"), jobs)
        self.assertRegex(self.text, r"timeout-minutes:\n(?:        .*\n)+?        default: 30\n")

    def test_junit_summary_and_artifact(self) -> None:
        self.assertEqual(self.text.count('--junit-xml="$JUNIT_XML"'), 2)  # serial and xdist
        self.assertIn(">> \"$GITHUB_STEP_SUMMARY\"", self.text)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", self.text)
        for step in ("Pytest failures to job summary", "Upload pytest junit-xml"):
            self.assertRegex(self.text, rf"name: {step}\n        if: \$\{{\{{ always\(\) \}}\}}")


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

    def test_selfcheck_keeps_full_scans(self) -> None:
        sc = read("secret-scan-selfcheck.yml")
        self.assertRegex(sc, r"push:\n    branches: \[main\]")
        self.assertIn("schedule:", sc)
        self.assertIn("fetch-depth: 0", sc)


if __name__ == "__main__":
    unittest.main()
