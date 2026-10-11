# Action & tool pins — single source of truth

Every pinned SHA in this repository's reusable workflows **must** appear in
this table. Bumping a pin = one commit here + matching edits in the workflow
files, landed together in `ci-harness`; adopting repos never hand-edit pins.
This table exists because the 2026-09-21 estate recon found real drift:
`checkout@v4.2.2` in one repo vs `@v7.0.1` in others.

Verification method column shows how each SHA was checked against the
upstream tag on the pin date (never copied blindly from an older workflow).

## GitHub Actions

| Action | Version | Commit SHA | Used in | Verified |
|---|---|---|---|---|
| [actions/checkout](https://github.com/actions/checkout) | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` | all workflows | `git ls-remote` 2026-09-21 |
| [actions/setup-python](https://github.com/actions/setup-python) | v7.0.0 | `5fda3b95a4ea91299a34e894583c3862153e4b97` | reusable-python, reusable-node | `git ls-remote` 2026-09-21 |
| [actions/setup-node](https://github.com/actions/setup-node) | v7.0.0 | `820762786026740c76f36085b0efc47a31fe5020` | reusable-node, reusable-uat | `git ls-remote` 2026-09-21 |
| [actions/upload-artifact](https://github.com/actions/upload-artifact) | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` | reusable-node, reusable-uat | `git ls-remote` 2026-09-21 |
| [gitleaks CLI](https://github.com/gitleaks/gitleaks) (replaced gitleaks-action 2026-10-09: it needs a paid key for org repos) | v8.30.1 | sha256 `551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb` (linux_x64 tarball) | reusable-secret-scan | release checksums file, 2026-10-09 |

## Pinned binaries

| Binary | Version | sha256 | Used in | Verified |
|---|---|---|---|---|
| [open-policy-agent/conftest](https://github.com/open-policy-agent/conftest) (linux tarball) | 0.69.0 | (release checksum not separately pinned — see note) | reusable-claims-policy.yml | version matches homelab's `tools/toolbox/versions.json`, which CI already pins; **TODO: pin the tarball sha256** |
| [rhysd/actionlint](https://github.com/rhysd/actionlint) (linux_amd64 tarball) | 1.7.12 | `8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8` | actionlint-selfcheck.yml | official `checksums.txt` + release-API `digest` + independent re-download 2026-09-21 (first selfcheck run FAILED the gate on a transcription error — mechanism proven) |

## Toolchain & base-image pins

| Thing | Pin | Where it lives | Rationale |
|---|---|---|---|
| uv | 0.11.28 | `uv-version` input default in reusable-python.yml / reusable-node.yml | matches the version adopted repos already ran; bumped only via this table |
| CPython default | 3.12 | `python-version` input default | estate-wide test interpreter |
| Node default | 22 | `node-version` input default | matches personal-world e2e |
| nginx (fixture only) | 1.30.1-alpine | fixtures/container-demo/Dockerfile | pinned-tag exemplar: consuming repos pin their own base images |
| play-nice-contracts clone | **deliberately unpinned** — default-branch tip, `git clone --filter=blob:none` over https (full history, so ancestry is provable) | reusable-contract-freshness.yml | the cloned checkout's own revision is one of the pins the freshness check compares against the remote head; pinning the clone anywhere but tip would force a non-CURRENT verdict forever. The revision under test is the consumer's manifest pin. Fixture re-pins (current vs stale probe) stay manual, per this repo's own honesty rule |

Repo-specific pins (pytest in `uv.lock`, Playwright browsers, app base
images) stay in the consuming repo — that's semantics, not plumbing.

## First-party files fetched at run time

| File | Ref | Where it lives | Rationale |
|---|---|---|---|
| `scripts/otel-span.sh` | `main` — `https://raw.githubusercontent.com/rylee-bee-labs/ci-harness/main/scripts/otel-span.sh` | every `reusable-*.yml` "OpenTelemetry context" step | A reusable workflow's `github` context is the **caller's** repository, so a template's own `actions/checkout` never brings this repo's tree with it. Each step prefers `$GITHUB_WORKSPACE/scripts/otel-span.sh` when it is there (self-smoke, where ci-harness is the caller) and falls back to the raw fetch. Same reference policy as the templates themselves: consumers adopt ci-harness at `@main` and the bytes are identical at a SHA, so pinning a file that changes in every commit of the repo would be a checksum maintained against itself. No new action, no new package: the emitter is `bash`, `curl` and `python3`, all already on every runner these templates use. |

## Bump protocol

1. Resolve the new tag's commit: `git ls-remote https://github.com/<org>/<action>.git refs/tags/<tag>^{}`
   (dereference annotated tags; never trust a copied SHA).
2. Update this table **and** every workflow occurrence in one commit.
3. `actionlint-selfcheck` + `self-smoke` on ci-harness must go green before
   any consumer sees the change (consumers call `@main`).
