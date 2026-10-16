# ci-harness

**What this repo is:** Shared GitHub Actions pipeline machinery for the estate's repositories —
`workflow_call` reusable workflows plus the single source of truth for action SHA pins
(`pins/ACTIONS.md`). GitHub remote is `rylee-bee-labs/ci-harness`; the estate moved out
of the old `Rylee-Bee` owner into the `rylee-bee-labs` org on 2026-10-09, and anything
still naming the old owner is stale. Visibility was **PUBLIC** under the old owner; the
move into the private org means do not assume it today — check with
`gh api repos/rylee-bee-labs/ci-harness --jq .private` before relying on the
"Visibility requirement" rule below.

**Principle — adopt the mechanics, own the semantics.** This repo owns checkout/setup/
pinning/artifact plumbing. Each consuming repo keeps a thin contract workflow declaring
*which* checks run and *what they mean*. Repo-owned gates (public-safety tests, determinism
censuses, contrast audits) never move here; if no template fits, the check stays inline in
the consumer.

Estate rules: `~/.agents/AGENTS.md` and `play-nice-contracts/contracts/everyone/FLOOR.md`.

## Map

| Path | Kind | Purpose | Open it? |
|---|---|---|---|
| `.github/workflows/reusable-*.yml` | source | the eight templates consumers call via `uses:` (python, node, container-smoke, contract-freshness, uat, secret-scan, project-home, claims-policy) | yes, when changing a template |
| `.github/workflows/self-smoke.yml` | source | **real execution** of every template against `fixtures/` | yes, with any template change |
| `.github/workflows/actionlint-selfcheck.yml` | source | static lint of all workflows with checksum-pinned actionlint | rarely |
| `.github/workflows/secret-scan-selfcheck.yml` | source | runs `reusable-secret-scan.yml` on this repo: PR commits only on `pull_request`, full history on push to main and weekly | rarely |
| `pins/ACTIONS.md` | docs/contract | every pinned action SHA, binary sha256, toolchain default, and the bump protocol | yes, before touching any `uses:` SHA or version default |
| `README.md` | docs | the human-first front door: what it is, "Is it running?" (one state line + `gh run list -R rylee-bee-labs/ci-harness`), "How to use it", "Where to read more". Hard cap: under 400 words | rarely; it points at this file, not the reverse |
| `policy/claims.rego`, `policy/claims_test.rego`, `scripts/verify-claim.sh`, `tests/test_claim_policy_drift.py` | source | **canonical** honest-claims policy: the conftest policy, its bash mirror for commit-time hooks, and the drift test that proves the two agree. `reusable-claims-policy.yml` serves these to consumers at their pinned revision; homelab predates the template and keeps its own copies, checked by the same drift test |
| `fixtures/*-demo/` | fixtures | minimal projects self-smoke drives (py, node, container, uat, contract) | when the matching template changes |
| `fixtures/contract-demo/current-adoption.yaml` | fixture | CURRENT pin; moved by the Play-Nice pin robot (`chore(play-nice): pin …` PRs) | don't hand-edit |
| `fixtures/contract-demo/stale-adoption.yaml` | fixture | permanently stale pin; MUST stay red | never "fix" it |

Lockfiles (`fixtures/*/uv.lock`, `package-lock.json`) are committed on purpose so
`uv sync --frozen` / `npm ci` have something real to install.

## Commands

There is no local build, test runner, or lint wrapper, and `actionlint` is not installed on
the workstation. **CI is the gate**, on every push to `main` and every PR:

- `actionlint-selfcheck` — `./actionlint -color` over `.github/workflows/*.yml`, then `tests/test_workflow_contracts.py` (preflight first in every job, a `timeout-minutes` on every runner job, junit summary, PR-scoped secret scan with full scans kept)
- `self-smoke` — calls each template through its real `uses:` contract
- `secret-scan-selfcheck` — gitleaks: PR commits only on a PR; full history on push to main and on the weekly schedule

Local, no tools needed: `python3 -m unittest tests.test_workflow_contracts`.

Optional local sanity for a fixture (same invocations the templates run):

- `cd fixtures/py-demo && uv sync --frozen --extra test && uv run pytest --timeout=30 -q`
- `cd fixtures/node-demo && npm ci && npm run build && npm run lint`

Read CI results with `gh run list -R rylee-bee-labs/ci-harness` or `gh pr checks <n>`.

## Templates

The full table of what a caller gets. It lives here, not in the README, because the README
caps at four sections and under 400 words.

| Workflow | Shape |
|---|---|
| `reusable-python.yml` | uv + `uv sync --frozen` + repo-given pytest args (junit-xml artifact, failing tests + short tracebacks in the job summary, `timeout-minutes` input default 30 on every job), optional repo gates after pytest, optional ruff/bandit jobs |
| `reusable-node.yml` | setup-node + `npm ci` + optional build/lint/test + dist artifact upload; optional Python/uv bootstrap for polyglot e2e (Playwright on a uvicorn app) |
| `reusable-container-smoke.yml` | docker build + detached run + configurable healthz curl retry loop, with container logs on failure |
| `reusable-contract-freshness.yml` | shallow-clone the Play-Nice contract source over https, run `contractctl freshness --manifest <caller manifest> --json`; exit 0 only on CURRENT (fail closed) |
| `reusable-uat.yml` | pinned checkout + setup-node (npm cache, conditional `npm ci`) + a caller-supplied real-browser UAT command under a `UAT_READONLY=1` read-only posture with optional `uat-token` passthrough; UAT output uploaded as an artifact (14-day retention) |
| `reusable-secret-scan.yml` | pinned checkout + the gitleaks CLI (pinned version and sha256; the action needs a paid key for org repos); a repo-local `.gitleaks.toml` allowlists documented false positives instead of suppressing at the harness level. on `pull_request` it scans only the commits the PR adds (`--log-opts base..head`, full fetch forced, fail closed if the range cannot be resolved); on any other event it scans what `fetch-depth` fetched (default 0 = full history) |
| `reusable-claims-policy.yml` | fetch the canonical honest-claims policy from this repo **at the revision the caller pinned** (`github.workflow_ref`), install conftest, run a canary that proves the policy fires, then gate the PR body or commit message. `mirror-path` additionally proves a repo's vendored bash mirror agrees with the policy. Fail closed on an unreadable body |
| `reusable-project-home.yml` | narrow Project Home CI reporter: exact task claim/heartbeat/finish plus deduplicated BOOP notice; callers pass the private base URL and a dedicated `ci`-scope token only as secrets |

### Secret scan scope (decided 2026-10-15)

PRs fail only on **new** findings: `reusable-secret-scan.yml` scans `base..head` when the
caller's event is `pull_request`, so an old finding on main cannot block an unrelated PR.
The full scan is never weakened: `fetch-depth` defaults to 0 (full history) for every
non-PR event, and callers must keep `push` to main and a `schedule` trigger, as
`secret-scan-selfcheck.yml` does. No baseline file is used;
a documented false positive belongs in the repo's `.gitleaks.toml` allowlist, which is
reviewed like any other diff. Dropping the push/schedule triggers from a caller leaves
old history unscanned: do not.

Adoption is a ~15-line contract replacing hundreds of lines of copy-pasted plumbing,
keeping the repo's real check arguments. The SHA is obtained with
`git ls-remote https://github.com/rylee-bee-labs/ci-harness refs/heads/main`:

```yaml
name: validate
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  test:
    uses: rylee-bee-labs/ci-harness/.github/workflows/reusable-python.yml@<sha>  # pinned SHA
    with:
      sync-args: "--extra test --extra crypto"
      pytest-args: "--timeout=30"
```

Repo-owned gates (public-safety tests, determinism censuses, contrast audits) never move
here: if no template fits a check, it stays a small inline job in the consumer's own
workflow rather than contorting a template.

**Cost discipline.** Private-repo CI should preserve proof while folding duplicate billing.
Before adding or expanding a workflow, read
[docs/ACTIONS-COST-DISCIPLINE.md](docs/ACTIONS-COST-DISCIPLINE.md).

## Permissions

Caller token permissions flow down and can only be **kept or downgraded** by a called
workflow, never elevated (GitHub validates this before the run starts). So the templates
take their grants from the caller: `reusable-node` and `reusable-uat` declare no top-level
`permissions:` at all because they upload artifacts — jobs that enable `upload-dist` (node)
or `upload-artifacts: true` (uat) must grant `actions: write` at the calling job (or
workflow) level; with those upload inputs false, plain `contents: read` is enough. The
python and container templates declare only `contents: read`.

## Visibility requirement

GitHub's access matrix for reusable workflows: **a workflow in a public repository can only
call reusable workflows hosted in public repositories**
([official rule](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#access-to-reusable-workflows)).
An inaccessible private host surfaces as `workflow was not found` at parse time, with zero
jobs scheduled. So adoption from a **public** repo requires ci-harness to be public; private
repos can call it either way. Confirm current visibility with
`gh api repos/rylee-bee-labs/ci-harness --jq .private` — the org move is exactly the kind of
change that invalidates the assumption.

## Project Home orchestration

The reporter deliberately carries no approval authority. Project Home remains the task,
approval, lease, and BOOP source of truth; CI gets a dedicated `ci` bearer scope and may
only operate through the narrow `/api/ci/*` surface.

A caller typically claims a Project Home task before its real job and reports the final
outcome afterward. The URL and token stay repository secrets, so this public harness never
records private topology:

```yaml
jobs:
  claim:
    uses: rylee-bee-labs/ci-harness/.github/workflows/reusable-project-home.yml@<sha>  # pinned SHA
    with:
      action: claim
      task-id: "123"
    secrets:
      project-home-url: ${{ secrets.PROJECT_HOME_URL }}
      project-home-token: ${{ secrets.PROJECT_HOME_CI_TOKEN }}

  # ...repo-owned work...

  finish:
    uses: rylee-bee-labs/ci-harness/.github/workflows/reusable-project-home.yml@<sha>  # pinned SHA
    with:
      action: finish
      task-id: "123"
      outcome: succeeded
      note: "tests and smoke checks passed"
    secrets:
      project-home-url: ${{ secrets.PROJECT_HOME_URL }}
      project-home-token: ${{ secrets.PROJECT_HOME_CI_TOKEN }}
```

The default actor is stable for the workflow run (`gha:<repo>:<run_id>`), so separate
claim/finish jobs in the same run share one lease identity. Responses are written to a
temporary file and never echoed; logs expose only the action and HTTP status.

## Contract freshness

Repos that pin a Play-Nice contracts revision (an adoption-v1 manifest with
`source.revision`) call one ~4-line job to detect drift — the one question it answers is
*has the authoritative remote moved past our pin?* — typically on a weekly schedule and
whenever the manifest itself changes:

```yaml
  contract-freshness:
    uses: rylee-bee-labs/ci-harness/.github/workflows/reusable-contract-freshness.yml@<sha>  # pinned SHA
    with:
      manifest-path: .project/contracts/adoption.yaml
```

Mechanics are fail-closed by construction: the job runs `contractctl freshness --json` from
a fresh shallow clone of `rylee-bee-labs/play-nice-contracts` and propagates its exit
code — 0 **only** when the verdict is CURRENT; BEHIND/DIVERGED exit 1;
UNREACHABLE/UNKNOWN (missing or malformed manifest included) exit 2. The tool's JSON verdict
is printed, and `exit-code` / `status` are exposed as job outputs so a caller can assert on
the verdict without parsing logs. The default `expect: current` input means red on ANY
drift; `expect: warn` (for pull requests in a repo whose pin moves by robot,
`tools/pin-sync` in play-nice-contracts) passes with a visible warning and keeps the real
verdict in `status`; `expect: noncurrent` is the harness's own self-smoke inversion (see
below) and is not a soft-fail knob.

**Detection is automated; pin movement is manual.** A red freshness job means: read what
changed upstream (verify commit + VERSION/CHANGELOG + lock diff, re-read, re-attest), then
re-pin `source.revision` in the consumer repo as a human-reviewed commit — or accept the lag
knowingly. There is deliberately no sync job here, and there never will be.

self-smoke proves both verdicts as POSITIVE assertions on every run: the committed
current-pin fixture must pass through the real `uses:` call; a permanently stale fixture must
exit nonzero — proven by an inversion job (`expect: noncurrent`, green exactly when the gate
correctly goes red, because GitHub forbids `continue-on-error` on `uses:` jobs) plus an
assertion job on the probe's propagated outputs; and a manifest generated live from
`git ls-remote` at run time must read CURRENT, so the green-path witness never rots when the
library moves. The committed current-pin fixture declares `update: automatic`, so a
docs-only upstream move leaves it CURRENT (the tool's equivalence rule, provable because the
template's clone is blobless with full history); when upstream contracts or schema change,
it goes red on purpose until a human re-pins it.

## Telemetry

Every template emits a **pipeline span and a job span** per job through
`scripts/otel-span.sh` (ci-harness #19; the contract it follows is homelab's
`docs/observability/TELEMETRY-CONTRACT.md`, homelab #229). **OpenTelemetry observes the
estate; it never becomes the estate.** The GitHub check is still the gate — no step, script
or backend reads these spans to decide whether work passed, approved, or may land, and a span
cannot fail a job.

**What the pipeline span's interval means.** Its *name* and its *attributes*
(`cicd.pipeline.name`, `cicd.pipeline.run.id`, `cicd.pipeline.result`) are the run's own
and are correct and identical across every job of a run. Its *timestamps are not the
pipeline's*: they are this job's, from the telemetry context step to the closing step, so a
run with five jobs produces five pipeline-role spans and each one's duration is one job's
duration. Read a duration off it as a job's slice, not a run's. This is stated rather than
worked around because no job can observe when the pipeline started or when its last job
ended — widening the span would mean guessing — and because renaming it away from
`ci.pipeline.run` would invent an estate-specific name for something the CI/CD conventions
already name, which #19 rules out first. The job span under it carries the run's
`cicd.pipeline.*` identity plus this job's `cicd.pipeline.task.*`.

What a run emits, using OpenTelemetry's own conventions rather than estate-specific names:

| Attribute | On |
|---|---|
| `cicd.pipeline.name`, `cicd.pipeline.run.id`, `cicd.pipeline.result`, `cicd.worker.name` | every span |
| `cicd.pipeline.task.name`, `cicd.pipeline.task.run.id`, `cicd.pipeline.task.run.result` | job span |
| `vcs.repository.name`, `vcs.ref.head.name`, `vcs.ref.head.revision`, `vcs.change.id` | every span |
| `estate.host.class`, `estate.actor.kind`, `estate.mission.id`, `estate.task.id` | every span |
| `service.name`, `service.namespace=estate` (resource), `http.*`, `url.path` | resource / the Project Home call |

Turning it on is one repository variable, read by every template:

| Variable | Meaning |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | base URL of the Collector; `/v1/traces` is appended |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | per-signal override, wins over the base URL |
| `OTEL_SERVICE_NAME` | defaults to `ci-harness` |
| `ESTATE_HOST_CLASS` | refines the label-derived host class — it never overrides a runner label that says `github-hosted`, because one repository-variable edit must not be able to point a hosted runner at a LAN Collector it cannot reach |

These are the **standard** OTEL environment variables, not an estate-specific discovery
mechanism. There is deliberately **no `workflow_call` input** for the endpoint: a new input
costs a self-smoke job per template for one string, and this repo's own cost discipline says
fold jobs that prove the same thing. The trade-off is that a consumer cannot point one call at
a different Collector — which matches the estate, where there is one Collector, and keeps
rollback to a single unset.

**Unset endpoint means off**, and the helper then does nothing differently: one POST per
span, a 2-second timeout, no retries, every error swallowed, and a circuit breaker so an
unreachable Collector costs one timeout per job rather than one per span. Both telemetry
steps are `continue-on-error: true`, and the closing step is `if: always()`, so a failed or
skipped job is still recorded honestly. A `github-hosted` runner cannot reach the LAN
Collector, so it emits nothing at all and says so in the step summary rather than posting a
span that cannot arrive.

**Joining a mission's trace.** A PR a mission lands carries `Estate-Task:
<mission_id>/<task_id>` on its commits; the context step reads it off HEAD and derives the
trace from the ids alone (`sha256("estate-task|<mission>|<task>")`, first 32 hex) with no
shared state. A PR without the trailer gets its own trace, linked back by `vcs.change.id`.

`reusable-project-home.yml` has **no checkout** — a reporter must stay cheap, and cloning
the caller to read one commit trailer would put telemetry ahead of the work it observes. It
reads the same trailer the other way: one API read of the head commit's message, `gh api
repos/<owner>/<repo>/commits/<sha>`, with the job token passed in the environment and never
in argv. The API is consulted only when the job has no local object store to read it from, so
a checked-out template spends no API call; and without `gh`, a token, or a hex sha the read
is simply not attempted. It is a read of one commit message, not a checkout, and it can only
ever *add* the correlation — it never invents ids, so an untrailered reporter still sends no
header, exactly as before. The Project Home reporter sends the resulting `traceparent` on its
`/api/ci` call, which is how Project Home's own spans land in the same trace — and the claim,
heartbeat and finish calls carry the two ids as an `Estate-Task` request header, read from
that same context, so Project Home's `ci.task.*` spans are still joinable after the trace is
gone: a mission runs for days and no one trace spans it. That header is the **only**
interface: it is the one Project Home already accepts
(`app/projecthome/telemetry.py`, `ESTATE_TASK_HEADER`), and the reporter deliberately grows
no `mission_id` / `mission_task_id` body pair for existing callers to learn — a CI consumer
that knows nothing about telemetry must see a body it recognises. With no trailer **no header
is sent** — no empty value, no repo-name or run-id stand-in — and a notice, which belongs to
no task, never carries one either.

Two self-smoke jobs prove this without a Collector: `otel-selftest` runs
`scripts/otel-span.sh --self-test` (a throwaway OTLP receiver on 127.0.0.1, asserting the
bodies it captures), and `otel-template-wiring` checks that every template still carries the
pair and runs one template's two steps end to end against a live receiver.

Because a reusable workflow's `github` context is the **caller's** repository,
`scripts/otel-span.sh` is not present after a template's own `checkout`. Each template
prefers the checked-out tree (self-smoke, where ci-harness *is* the caller) and otherwise
fetches it from ci-harness `@main` — the same reference policy the templates themselves are
adopted under. See [pins/ACTIONS.md](pins/ACTIONS.md).

**Name disambiguation:** Play-Nice `harness/` is a behavioral-research ledger; unrelated name
collision. This repo is *CI* machinery only.

## Boundaries

- **Consumers call templates at a pinned SHA.** This was once documented as `@main`; it
  never was, in practice. Measured 2026-10-06 across the 40 repos then under the `Rylee-Bee`
  owner (now `rylee-bee-labs`): **28**
  workflow files reference these templates at **5 distinct commit SHAs** (12 distinct
  `workflow@revision` pins), spanning 2026-09-29 → 2026-10-05. The only `@main` reference
  in the estate is this repo's own `self-smoke.yml`, which is a legitimate self-test.
  **A merge to `main` is therefore not a deployment event for anyone** — consumers keep
  running the revision they pinned until they re-pin. Before a breaking change, find every
  pinned consumer:
  `gh search code "rylee-bee-labs/ci-harness/.github/workflows" --owner rylee-bee-labs`
  and expect to move pins deliberately, not automatically.
- Template inputs/outputs/secrets are a public interface: add inputs with safe defaults;
  renaming or removing one is breaking — record the consumer companion edits, don't make
  them (sibling repos need explicit authorization).
- Permissions flow caller → template and can only be downgraded. `reusable-node` and
  `reusable-uat` declare no top-level `permissions:`; see "Permissions" above before
  adding any grant.
- Contract freshness clones `play-nice-contracts` at tip, **deliberately unpinned**; the
  verdict comes from `contractctl` there. There is no sync job here and never will be.
- Name collision: Play-Nice `harness/` is an unrelated research ledger.

## Needs Rylee's approval here

- Bumping or changing any pin in `pins/ACTIONS.md` (propagates to every consumer).
- Breaking template interface changes, or loosening a fail-closed gate
  (`expect:` semantics, the stale probe, the actionlint checksum).
- Changing repo visibility (public is required for public consumers — see "Visibility
  requirement" above).
- General gates: see the constitution.

## Working defaults

- **Public repo:** no LAN IPs, hostnames, home paths, tokens, or private-repo internals in
  any file, commit message, or fixture. Secrets reach templates only as `secrets:` inputs.
- Every `uses:` of an external action is a 40-char SHA with a `# vX.Y.Z` comment, matching
  `pins/ACTIONS.md`. Bump = table + every workflow occurrence in **one commit**, SHA resolved
  with `git ls-remote … refs/tags/<tag>^{}` (never copied from another repo).
- A new or changed template input gets a self-smoke job exercising it — static lint alone
  proves nothing for `workflow_call`. Prove red paths as positive assertions (GitHub forbids
  `continue-on-error` on `uses:` jobs; follow the `expect: noncurrent` pattern).
- Extend an existing template before adding a new one; update the template table above in
  the same change.
- Other worktrees of this repo may exist; check `git worktree list`.

## Done means

A PR whose `actionlint-selfcheck`, `self-smoke`, and `secret-scan-selfcheck` runs are green
(cite `gh pr checks`), README / `pins/ACTIONS.md` updated where the change touches them, and,
for interface changes, the consumer companion edits listed. Merged to `main` is live for
consumers; there is no separate deploy.

## Handoff

No repo-local handoff directory. Session state goes to Project Home (estate `AGENTS.md` §4).
