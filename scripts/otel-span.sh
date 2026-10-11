#!/usr/bin/env bash
# ci-harness — the estate OpenTelemetry span emitter, bash + curl, nothing else.
#
# Contract: homelab docs/observability/TELEMETRY-CONTRACT.md §1-3 (homelab #229);
# ci-harness #19. This is
# the bash counterpart of agent-platform's bin/estate_otel.py (PR agent-platform#74):
# standard library only, one OTLP/HTTP JSON POST per span with curl, a 2-second
# timeout, no retries in the hot path, every error swallowed. A span that cannot be
# sent is dropped. **Telemetry failure must never fail a CI job** — this script
# exits 0 on any send failure, and the templates also mark every telemetry step
# continue-on-error.
#
# "OpenTelemetry observes the estate. It never becomes the estate." Nothing reads
# these spans to decide whether work passed, approved, or is allowed to land. The
# GitHub check is still the gate; a span is an explanation, never an authority.
#
# On only when OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT is
# set and OTEL_SDK_DISABLED is not "true" (§1: "Unset endpoint means off", and a
# producer with no endpoint emits nothing and does nothing else differently).
# The endpoint arrives through the *standard* environment variables — no
# estate-specific discovery, no new package, no new action.
#
# Circuit breaker: one failed send writes a marker under $RUNNER_TEMP, so an
# unreachable Collector costs one 2-second timeout per job, not one per span.
#
# §4 — what never goes out: secrets, bearer tokens, cookies, prompts, completions,
# private notes, conversation text, URL query strings, request/response bodies, IP
# addresses, host names, home-directory paths. Attributes here are ids, standard
# CI/CD and VCS convention names, and coarse enums. The Collector scrubs a second
# time; that is a safety net, not the plan.

set -uo pipefail

OTEL_TIMEOUT_S="${OTEL_TIMEOUT_S:-2}"
SERVICE_NAMESPACE="estate"
SCOPE_NAME="otel-span"
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

# --------------------------------------------------------------------------------------- primitives

trim() { local s="${1-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

lower() { printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'; }

die() { printf 'otel-span: %s\n' "${1-}" >&2; exit 2; }

# W3C forbids all-zero ids; the contract's fallback turns the last hex digit into 1.
nonzero() { local h="${1-}"; case "$h" in *[!0]*) printf '%s' "$h" ;; *) printf '%s1' "${h%?}" ;; esac; }

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${1-}" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "${1-}" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

random_hex() {
  local n="${1:-16}" out
  out=$(od -An -tx1 -N"$n" /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ "${#out}" -lt $((n * 2)) ]; then
    out=$(head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  printf '%s' "$out"
}

now_ns() {
  local n
  n=$(date +%s%N 2>/dev/null) || n=""
  case "$n" in "" | *N*) n=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null) ;; esac
  printf '%s' "${n:-0}"
}

work_dir() {
  local d="${RUNNER_TEMP:-}"
  if [ -z "$d" ]; then d="${TMPDIR:-/tmp}"; fi
  printf '%s' "$d"
}

breaker_file() {
  if [ -n "${OTEL_BREAKER_FILE:-}" ]; then printf '%s' "$OTEL_BREAKER_FILE"; return 0; fi
  printf '%s/otel-span.breaker' "$(work_dir)"
}

# --------------------------------------------------------------------------------------- trace context

# Contract §2: trace id = first 32 hex of sha256("estate-task|<mission>|<task>"),
# root span id = first 16 hex of sha256("estate-task-root|<mission>|<task>"). Every
# hop that knows the two ids computes the same trace with no shared state.
task_ids() {
  local t r
  t=$(sha256_hex "estate-task|${1-}|${2-}"); t="${t:0:32}"
  r=$(sha256_hex "estate-task-root|${1-}|${2-}"); r="${r:0:16}"
  printf '%s %s' "$(nonzero "$t")" "$(nonzero "$r")"
}

PT_TRACE=""
PT_SPAN=""
parse_traceparent() {
  PT_TRACE=""
  PT_SPAN=""
  local v="${1-}" a="" b="" c="" d="" e=""
  IFS='-' read -r a b c d e <<<"$v"
  [ -z "${e:-}" ] || return 1           # exactly four fields, never five
  [ "${#a}" -eq 2 ] && [ "${#b}" -eq 32 ] && [ "${#c}" -eq 16 ] && [ "${#d}" -eq 2 ] || return 1
  for part in "$a" "$b" "$c" "$d"; do
    case "$part" in *[!0-9a-fA-F]*) return 1 ;; esac
  done
  [ "$(lower "$a")" = "ff" ] && return 1
  [ "$b" = "00000000000000000000000000000000" ] && return 1
  [ "$c" = "0000000000000000" ] && return 1
  PT_TRACE=$(lower "$b")
  PT_SPAN=$(lower "$c")
  return 0
}

# The Estate-Task trailer (contract §2) rides on the commits of a PR a mission lands.
# The grammar lives here, once, because both readers below go through it: a value
# found over the API has exactly as much right to become a trace id as one found
# in the local object store, so the two must not be able to drift apart.
trailer_from_message() {
  local line
  line=$(printf '%s\n' "${1-}" | tr -d '\r' \
    | grep -E '^[[:space:]]*Estate-Task:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._-]+[[:space:]]*$' | head -n1) || return 0
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%s' "${line#Estate-Task:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

task_from_git() {
  local ref="${1:-HEAD}" msg
  msg=$(git log -1 --format=%B "$ref" 2>/dev/null) || return 0
  trailer_from_message "$msg"
}

# The same trailer, for a job that has no checkout to read it out of. The Project
# Home reporter is exactly that job, and the finding is real: without this it can
# never see an Estate-Task trailer, so its `/api/ci` calls go out uncorrelated
# and the reporter — the one job whose entire reason for existing on this trace is
# the correlation — is the one job that never gets it.
#
# This is a *read of one commit message through the job token*, not a checkout:
# a reporter must stay cheap, and cloning the caller to read one trailer would
# put telemetry ahead of the work it observes. Nothing else about the request
# changes.
#
# Guarded four ways, and each guard is a decision rather than paranoia:
#   - a `.git` this could read is used first, so the API is never asked a
#     question git has already answered (an untrailered run costs no API call);
#   - the sha must be hex before it becomes part of a URL path;
#   - `gh` and a token must both exist, so this is a no-op on a runner without
#     either — never an error, because telemetry must not fail a job;
#   - the token arrives in the environment (GH_TOKEN), never in argv, where any
#     process of the same user on a self-hosted runner could read it.
task_from_api() {
  local repo="${GITHUB_REPOSITORY:-}" sha="${1:-${OTELSPAN_HEAD_REVISION:-}}" msg token
  [ -n "$repo" ] && [ -n "$sha" ] || return 0
  [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$token" ] || return 0
  msg=$(GH_TOKEN="$token" gh api "repos/${repo}/commits/${sha}" --jq .commit.message 2>/dev/null) || return 0
  trailer_from_message "$msg"
}

# Is there a local object store this job could have read the trailer from? A
# reusable workflow's checkout happens in the *caller's* tree, so for a template
# with no checkout of its own the answer is no, and the API is the only road in.
has_git_repo() {
  local d="${GITHUB_WORKSPACE:-$PWD}"
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1
}

# estate.host.class (contract §3). Coarse by design: a runner *label*, never a
# hostname. The labels are chosen by this estate, so they can carry the meaning.
#
# Precedence, and it runs this way on purpose: **the runner label wins**. The
# label is what the platform actually put on the machine; ESTATE_HOST_CLASS is a
# repository variable somebody can edit, and one edit must never be enough to
# turn a GitHub-hosted runner into a "self-hosted" one that dials a LAN Collector
# it cannot reach. So a label that is already conclusive — `github-hosted` —
# ends the argument, and the environment is only consulted to *refine* a label
# that has not decided the question (an unrecognised label that would otherwise
# degrade to `unknown`). Somebody will try to reverse this to give a repo finer
# control; the answer is that the safe direction is the one that sends less.
detect_host_class() {
  local label v="${ESTATE_HOST_CLASS:-}" from_label=""
  label=$(lower "${1-}")
  case "$label" in
    ubuntu | ubuntu-* | windows | windows-* | macos | macos-*) printf 'github-hosted'; return 0 ;;
    *bazzite*) from_label="bazzite" ;;
    *dockerhost*) from_label="dockerhost" ;;
    *stack*) from_label="stack-vm" ;;
    *dev*) from_label="dev-vm" ;;
    *) from_label="unknown" ;;
  esac
  case "$v" in
    dev-vm | bazzite | dockerhost | stack-vm | github-hosted | unknown) printf '%s' "$v"; return 0 ;;
  esac
  printf '%s' "$from_label"
}

# --------------------------------------------------------------------------------------- OTLP/HTTP JSON

# Endpoint resolution is the standard discovery of §1 and nothing else.
otel_endpoint() {
  [ "$(lower "${OTEL_SDK_DISABLED:-}")" = "true" ] && return 1
  local traces base
  traces=$(trim "${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}")
  if [ -n "$traces" ]; then printf '%s' "$traces"; return 0; fi
  base=$(trim "${OTEL_EXPORTER_OTLP_ENDPOINT:-}")
  [ -n "$base" ] || return 1
  printf '%s/v1/traces' "${base%/}"
}

trip_breaker() { mkdir -p "$(work_dir)" 2>/dev/null; : >"$(breaker_file)" 2>/dev/null || true; }

# The OTLP/HTTP JSON body for one span, on stdout. JSON is built by the standard
# library rather than by string-splicing in the shell: an attribute value must
# never be able to break out of its own object.
# $1 name $2 trace $3 span $4 parent(or -) $5 start_ns $6 end_ns $7 attrs-file
# $8 error(or empty) $9 kind $10 resource-extra-file $11 service $12 host-class $13 scope
build_body() {
  python3 - "$@" <<'BODY_PY'
import json
import sys

(
    name, trace, span, parent, start, end,
    attrs_file, err, kind, res_file, service, host_class, scope,
) = sys.argv[1:14]


def load(path):
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                key, _, value = line.partition("=")
                out.append({"key": key, "value": {"stringValue": value}})
    except OSError:
        pass
    return out


span_obj = {
    "traceId": trace,
    "spanId": span,
    "name": name,
    "kind": int(kind or 1),
    "startTimeUnixNano": str(int(start)),
    "endTimeUnixNano": str(max(int(end), int(start))),
    "attributes": load(attrs_file),
}
if parent and parent != "-":
    span_obj["parentSpanId"] = parent
if err:
    span_obj["status"] = {"code": 2, "message": err[:200]}

resource = [
    {"key": "service.name", "value": {"stringValue": service}},
    {"key": "service.namespace", "value": {"stringValue": "estate"}},
    {"key": "estate.host.class", "value": {"stringValue": host_class}},
] + load(res_file)

print(json.dumps({
    "resourceSpans": [{
        "resource": {"attributes": resource},
        "scopeSpans": [{"scope": {"name": scope}, "spans": [span_obj]}],
    }],
}, separators=(",", ":")))
BODY_PY
}

# Fire and forget. Always returns 0: a failed export is dropped, never raised
# into the caller, and one failure trips the breaker for the rest of the job.
post_span() {
  local url
  if [ -f "$(breaker_file)" ]; then return 0; fi
  url=$(otel_endpoint) || return 0

  local body_file rc code
  body_file=$(mktemp "${TMPDIR:-/tmp}/otel-span.XXXXXX.json") || return 0

  if ! build_body "$@" >"$body_file" 2>/dev/null; then
    rm -f "$body_file"
    return 0
  fi

  code=$(curl --silent --show-error --request POST \
    --header "Content-Type: application/json" \
    --data-binary "@$body_file" \
    --output /dev/null --write-out '%{http_code}' \
    --max-time "$OTEL_TIMEOUT_S" --connect-timeout "$OTEL_TIMEOUT_S" \
    "$url" 2>&1)
  rc=$?
  rm -f "$body_file"

  if [ "$rc" -ne 0 ]; then
    printf 'otel-span: dropped span %q (transport: %s) — telemetry failure is not a CI failure\n' "$1" "$code"
    trip_breaker
    return 0
  fi
  case "$code" in
    2??) printf 'otel-span: sent span %q (%s)\n' "$1" "$code" ;;
    *)
      printf 'otel-span: dropped span %q (collector answered %s)\n' "$1" "$code"
      trip_breaker
      ;;
  esac
  return 0
}

# --------------------------------------------------------------------------------------- emit

# One span, generically. This is the only thing that talks to the network.
cmd_emit() {
  local name="" trace="" span="" parent="-" start="" end="" err="" kind="1"
  local attrs_file res_file service="" host_class="" scope="$SCOPE_NAME"
  local dir; dir=$(mktemp -d "${TMPDIR:-/tmp}/otel-attrs.XXXXXX") || return 0
  attrs_file="$dir/span"; res_file="$dir/res"
  : >"$attrs_file"; : >"$res_file"

  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2-}"; shift 2 ;;
      --trace-id) trace="${2-}"; shift 2 ;;
      --span-id) span="${2-}"; shift 2 ;;
      --parent-span-id) parent="${2-}"; shift 2 ;;
      --start-ns) start="${2-}"; shift 2 ;;
      --end-ns) end="${2-}"; shift 2 ;;
      --error) err="${2-}"; shift 2 ;;
      --kind) kind="${2-}"; shift 2 ;;
      --service) service="${2-}"; shift 2 ;;
      --host-class) host_class="${2-}"; shift 2 ;;
      --scope) scope="${2-}"; shift 2 ;;
      --resource-attrs-file) res_file="${2-}"; shift 2 ;;
      --attrs-file) cat "$2" >>"$attrs_file" 2>/dev/null || true; shift 2 ;;
      --attr)
        add_attr "$attrs_file" "${2-}" || true
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$trace" ] || trace=$(random_hex 16)
  [ -n "$span" ] || span=$(random_hex 8)
  [ -n "$start" ] || start=1
  [ -n "$end" ] || end="$start"
  [ -n "$service" ] || service="ci-harness"
  [ -n "$host_class" ] || host_class="unknown"

  post_span "${name:-span}" "$trace" "$span" "$parent" "$start" "$end" \
    "$attrs_file" "$err" "$kind" "$res_file" "$service" "$host_class" "$scope"
  rm -rf "$dir"
  return 0
}

# A key=value attribute line, or nothing: a key that is not a dotted token, or a
# value carrying a control character or a home path, is refused rather than sent.
add_attr() {
  local file="${1-}" pair="${2-}" key value
  key="${pair%%=*}"
  value="${pair#*=}"
  [ "$key" != "$pair" ] || return 1
  [ -n "$value" ] || return 1
  case "$key" in
    '' | *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  case "$value" in
    *$'\n'* | *$'\r'* | *$'\t'*) return 1 ;;
  esac
  case "$value" in
    *"://"*) return 1 ;;      # no URLs: no endpoints, no query strings, no private hosts
    "~" | "~/"* | /home/* | /root/* | /Users/* | /var/home/*) return 1 ;;   # no home paths
    *".."*) return 1 ;;       # no path traversal
  esac
  printf '%s=%s\n' "$key" "${value:0:256}" >>"$file"
  return 0
}

# --------------------------------------------------------------------------------------- context

ctx_put() { printf "%s='%s'\n" "$1" "${2//\'/\'\\\'\'}" >>"$ctx_out"; }

# Compute everything the CI templates need once per job, and leave it in an
# env-file the close step sources. Nothing here sends anything.
cmd_context() {
  local out="" task="" job_key="${OTELSPAN_JOB_KEY:-unknown}"
  local pipeline_name="${OTELSPAN_PIPELINE_NAME:-workflow}"
  local run_id="${OTELSPAN_RUN_ID:-0}" attempt="${OTELSPAN_RUN_ATTEMPT:-1}"
  local repository="${OTELSPAN_REPOSITORY:-}" ref_head="${OTELSPAN_REF_HEAD:-}"
  local revision="${OTELSPAN_HEAD_REVISION:-}" change_id="${OTELSPAN_CHANGE_ID:-}"
  local runner_label="${OTELSPAN_RUNNER_LABEL:-}" service="${OTEL_SERVICE_NAME:-ci-harness}"
  local ctx_out; ctx_out=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) out="${2-}"; shift 2 ;;
      --task) task="${2-}"; shift 2 ;;
      --job-key) job_key="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -n "$out" ] || out="${OTELSPAN_ENV_FILE:-}"
  [ -n "$out" ] || { printf 'otel-span: context needs --env-file\n' >&2; return 2; }
  ctx_out="$out"
  : >"$ctx_out" || return 2

  # A PR a mission lands carries Estate-Task: <mission_id>/<task_id> on its HEAD
  # commit. Without one this run gets its own trace, linked by vcs.change.id.
  #
  # Two readers, in one order: the local object store when this job has one, and
  # the API when it does not. A job with no checkout has no HEAD commit message
  # to read, and asking the API only in that case keeps the common path free —
  # an untrailered run in a checked-out template never spends an API call, because
  # git already gave the definitive answer.
  [ -n "$task" ] || task=$(trim "${OTELSPAN_TASK:-}")
  if [ -z "$task" ]; then
    if [ "${OTELSPAN_READ_GIT:-1}" != "0" ]; then
      task=$(task_from_git "${OTELSPAN_GIT_REF:-HEAD}")
    fi
    if [ -z "$task" ] && ! has_git_repo; then
      task=$(task_from_api)
    fi
  fi

  local mission="" tid="" trace parent pipeline_span task_run span_id
  if [[ "$task" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    mission="${task%%/*}"
    tid="${task#*/}"
    read -r trace parent <<<"$(task_ids "$mission" "$tid")"
    ctx_put otel_parent_span_id "$parent"
  else
    [ -n "$task" ] && printf 'otel-span: ignoring unparseable Estate-Task trailer %q\n' "$task"
    trace=$(nonzero "$(random_hex 16)")
    ctx_put otel_parent_span_id ""
  fi

  # One trace per job; the task run id is derived, never a random collision.
  #
  # WHAT THE PIPELINE-ROLE SPAN'S INTERVAL MEANS — read this before trusting a
  # duration off it. Every job of a run emits its own pipeline-role span, and
  # its timestamps are this job's: `otel_start_ns` is the context step, which is
  # the first thing the job does, and the closing `ci-emit` runs at the job's
  # end. So that span's interval is THE JOB'S, not the pipeline's, and a run
  # with five jobs produces five of them.
  #
  # The *identity* on it is not approximate: cicd.pipeline.name, .run.id and
  # .result are the run's own, correct and identical across its jobs. Only the
  # extent is this job's slice. That is stated rather than hidden, and the
  # self-test asserts it (check: "the pipeline-role span's interval is the job's
  # interval, not the pipeline's"), so this paragraph cannot quietly go stale.
  #
  # It cannot be made otherwise from in here: no job can observe when the
  # pipeline started or when its last job ended, so there is no honest way to
  # widen the span, and widening it to a guess would be worse than naming what it
  # is. The obvious alternative was to rename the span away from
  # `ci.pipeline.run` to something that says "job" — but that invents an
  # estate-specific name for a thing the CI/CD conventions already name, which
  # ci-harness #19 rules out ahead of the alternative. So: standard name,
  # documented extent.
  pipeline_span=$(nonzero "$(sha256_hex "cicd-pipeline|${run_id}|${attempt}|${job_key}")")
  pipeline_span="${pipeline_span:0:16}"
  task_run=$(sha256_hex "cicd-task-run|${run_id}|${attempt}|${job_key}")
  task_run="${task_run:0:32}"
  span_id=$(nonzero "$(random_hex 8)")

  ctx_put otel_trace_id "$trace"
  ctx_put otel_span_id "$span_id"
  ctx_put otel_pipeline_span_id "$pipeline_span"
  ctx_put otel_task_run_id "$task_run"
  ctx_put otel_job_key "$job_key"
  ctx_put otel_mission_id "$mission"
  ctx_put otel_task_id "$tid"
  ctx_put otel_pipeline_name "$pipeline_name"
  ctx_put otel_pipeline_run_id "$run_id"
  ctx_put otel_repository "${repository#*/}"
  ctx_put otel_ref_head "$ref_head"
  ctx_put otel_head_revision "$revision"
  ctx_put otel_change_id "$change_id"
  ctx_put otel_runner_label "$runner_label"
  ctx_put otel_host_class "$(detect_host_class "$runner_label")"
  ctx_put otel_service_name "$service"
  ctx_put otel_actor_kind "ci"
  ctx_put otel_start_ns "$(now_ns)"
  # What this job hands to a child process or an HTTP call (W3C trace context).
  ctx_put otel_traceparent "00-${trace}-${span_id}-01"

  if [ -n "$out" ]; then
    printf 'otel-span: trace %s (task %s) host-class %s\n' "${trace:0:12}" "${task:-<none>}" "$(detect_host_class "$runner_label")"
  fi
  return 0
}

# --------------------------------------------------------------------------------------- ci-emit

# One CI span, assembled from the standard semantic conventions (contract §3).
# Nothing here is estate-specific where a standard name carries the meaning.
cmd_ci_emit() {
  local ctx="" role="job" result="success" end="" err=""
  local name="" span_override="" parent_override="" start="" child=0
  local dir; dir=$(mktemp -d "${TMPDIR:-/tmp}/otel-ci.XXXXXX") || return 0
  local attrs="$dir/attrs"; : >"$attrs"
  local extra=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) ctx="${2-}"; shift 2 ;;
      --role) role="${2-}"; shift 2 ;;
      --result) result="${2-}"; shift 2 ;;
      --end-ns) end="${2-}"; shift 2 ;;
      --error) err="${2-}"; shift 2 ;;
      --name) name="${2-}"; shift 2 ;;
      --span-id) span_override="${2-}"; shift 2 ;;
      # A span describing one call inside the job gets its own id; without this
      # it would reuse the job's span id and end up parented to itself.
      --child) child=1; shift ;;
      --parent-span-id) parent_override="${2-}"; shift 2 ;;
      --start-ns) start="${2-}"; shift 2 ;;
      --attr) extra+=(--attr "${2-}"); shift 2 ;;
      *) shift ;;
    esac
  done

  [ -n "$ctx" ] || { printf 'otel-span: ci-emit needs --env-file\n' >&2; rm -rf "$dir"; return 2; }
  # shellcheck disable=SC1090
  . "$ctx" 2>/dev/null || { rm -rf "$dir"; return 0; }

  # A GitHub-hosted runner cannot reach the LAN Collector. Say so in the step
  # summary rather than emitting a span that cannot arrive.
  if [ "${otel_host_class:-unknown}" = "github-hosted" ]; then
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf '### OpenTelemetry\n\nHost class is github-hosted; the LAN Collector is unreachable from this runner, so no span was emitted. Missing telemetry is UNKNOWN, not a failure.\n' >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
    printf 'otel-span: host-class github-hosted — Collector unreachable from this runner, span not emitted\n'
    rm -rf "$dir"
    return 0
  fi

  local res="$dir/res"; : >"$res"
  local pair
  for pair in ${OTEL_RESOURCE_ATTRIBUTES:-}; do
    add_attr "$res" "$pair" || true
  done

  # Standard CI/CD conventions: pipeline identity on every span, task identity on
  # the job span. Coarse runner label only — never a hostname or an IP.
  local result_enum
  case "$(lower "$result")" in
    success) result_enum="success" ;;
    failure) result_enum="failure" ;;
    cancelled | canceled) result_enum="cancellation" ;;
    skipped) result_enum="skipped" ;;
    *) result_enum="error" ;;
  esac

  add_attr "$attrs" "cicd.pipeline.name=${otel_pipeline_name:-}" || true
  add_attr "$attrs" "cicd.pipeline.run.id=${otel_pipeline_run_id:-}" || true
  add_attr "$attrs" "cicd.pipeline.result=$result_enum" || true
  add_attr "$attrs" "cicd.worker.name=${otel_runner_label:-unknown}" || true
  add_attr "$attrs" "estate.actor.kind=${otel_actor_kind:-ci}" || true
  add_attr "$attrs" "estate.host.class=${otel_host_class:-unknown}" || true
  add_attr "$attrs" "vcs.repository.name=${otel_repository:-}" || true
  add_attr "$attrs" "vcs.ref.head.name=${otel_ref_head:-}" || true
  add_attr "$attrs" "vcs.ref.head.revision=${otel_head_revision:-}" || true
  add_attr "$attrs" "vcs.change.id=${otel_change_id:-}" || true
  add_attr "$attrs" "estate.mission.id=${otel_mission_id:-}" || true
  add_attr "$attrs" "estate.task.id=${otel_task_id:-}" || true

  local span_id parent_id span_name
  [ "$child" -eq 1 ] && [ -z "$span_override" ] && span_override="$(nonzero "$(random_hex 8)")"
  # `--role pipeline` is the parent span this job hangs its task span under. Its
  # name, its attributes and its span id are the standard, per-run ones; its
  # start and end are this job's, because that is the only interval a job can
  # see. See the long note where the span id is derived.
  if [ "$role" = "pipeline" ]; then
    span_name="${name:-ci.pipeline.run}"
    span_id="${span_override:-${otel_pipeline_span_id:-}}"
    parent_id="${parent_override:-${otel_parent_span_id:-}}"
  else
    span_name="${name:-ci.job.run}"
    span_id="${span_override:-${otel_span_id:-}}"
    parent_id="${parent_override:-${otel_pipeline_span_id:-}}"
    add_attr "$attrs" "cicd.pipeline.task.name=${otel_job_key:-}" || true
    add_attr "$attrs" "cicd.pipeline.task.run.id=${otel_task_run_id:-}" || true
    add_attr "$attrs" "cicd.pipeline.task.run.result=$result_enum" || true
  fi

  [ -n "$start" ] || start="${otel_start_ns:-1}"
  [ -n "$end" ] || end="$(now_ns)"

  # Extra attributes arrive as a flat key=value list and go through the same
  # validation as the standard set: nothing unvalidated can reach the wire.
  local i=0
  while [ "$i" -lt "${#extra[@]}" ]; do
    add_attr "$attrs" "${extra[$((i + 1))]}" || true
    i=$((i + 2))
  done

  cmd_emit --name "$span_name" --trace-id "${otel_trace_id:-}" --span-id "$span_id" \
    --parent-span-id "$parent_id" --start-ns "$start" --end-ns "$end" \
    --error "$err" --kind 1 --service "${otel_service_name:-ci-harness}" \
    --host-class "${otel_host_class:-unknown}" --resource-attrs-file "$res" \
    --attrs-file "$attrs"
  rm -rf "$dir"
  return 0
}

# --------------------------------------------------------------------------------------- project home header

# The value of the `Estate-Task` request header for the Project Home /api/ci
# call, on stdout — or nothing at all.
#
# One interface, and it is the one Project Home already reads
# (app/projecthome/telemetry.py, ESTATE_TASK_HEADER; correlation() falls back to
# the header whenever the body pair is absent). The reporter therefore does NOT
# grow a `mission_id` / `mission_task_id` body pair: a CI consumer that knows
# nothing about telemetry must see a body it recognises, and a second way to
# say the same thing is a second thing that can disagree with the first.
#
# With an Estate-Task trailer the value is that trailer, read from the same
# context env-file the trace was derived from — so the ids on the wire cannot
# disagree with the ids this run's spans are recorded under. §2 is why this
# matters: a mission runs for days, so no single trace spans it, and the ids are
# the only thing that joins its spans. With no trailer the value is empty and the
# caller sends no header: a missing id is honest, an empty value or a
# repo/run-id stand-in would point a backend at a task this run is not working on.
cmd_project_home_header() {
  local ctx=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) ctx="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Read the way every template reads this file: the shell, not the parser.
  # Absent file, absent trailer and unparseable trailer all arrive as empty.
  local mission="" tid=""
  if [ -n "$ctx" ] && [ -s "$ctx" ]; then
    mission=$(sed -n "s/^otel_mission_id='\(.*\)'\$/\1/p" "$ctx" 2>/dev/null || true)
    tid=$(sed -n "s/^otel_task_id='\(.*\)'\$/\1/p" "$ctx" 2>/dev/null || true)
  fi

  PH_ESTATE_MISSION="$mission" PH_ESTATE_TASK="$tid" python3 - <<'HDR_PY'
import os
import re

# The same trailer grammar cmd_context accepts, re-checked here: this value goes
# in a header on the wire, so anything that is not the id itself is dropped
# rather than forwarded. Half a pair is no pair.
IDS = re.compile(r"^[A-Za-z0-9._-]+$")

mission = os.environ.get("PH_ESTATE_MISSION", "")
task = os.environ.get("PH_ESTATE_TASK", "")
if not (mission and task and IDS.match(mission) and IDS.match(task)):
    raise SystemExit(0)
print(f"{mission}/{task}")
HDR_PY
}

# --------------------------------------------------------------------------------------- usage

usage() {
  cat <<'EOF'
otel-span.sh — the estate OpenTelemetry span emitter (bash + curl, standard library only)

  --self-test                     start a throwaway receiver and prove the spans, and the
                             Project Home request, that actually go on the wire
  context   --env-file F [--task <mission>/<task>] [--job-key K]
  ci-emit   --env-file F [--role pipeline|job] [--result S] [--end-ns N] [--attr k=v]...
  project-home-header [--env-file F]  the value of the Project Home /api/ci `Estate-Task`
                             request header, on stdout: "<mission>/<task>" when F
                             holds both ids, and nothing at all when it does not.
  emit      --name N --trace-id H32 --span-id H16 [--parent-span-id H16]
            --start-ns N --end-ns N [--attr k=v]... [--error MSG]
  task-traceparent <mission> <task>
  parse-traceparent <traceparent>       prints "<trace-id> <span-id>", exit 1 if malformed
  task-from-git [ref]                   prints the Estate-Task trailer, or nothing
  task-from-api [sha]                   the same trailer, read from the head commit
                             through the API with the job token — for a job with no
                             checkout to read it out of. Nothing without gh, a token
                             and a hex sha.
  detect-host-class <runner-label>      dev-vm | bazzite | dockerhost | stack-vm | github-hosted | unknown

On only when OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT is set
and OTEL_SDK_DISABLED is not "true". Fire and forget: 2s timeout, no retries, never
raises. A failed export is dropped and never fails the caller.
EOF
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    --self-test) self_test; exit $? ;;
    emit) cmd_emit "$@" ;;
    context) cmd_context "$@" ;;
    ci-emit) cmd_ci_emit "$@" ;;
    project-home-header) cmd_project_home_header "$@" ;;
    task-traceparent)
      [ $# -ge 2 ] || die "task-traceparent needs a mission id and a task id"
      read -r t s <<<"$(task_ids "${1-}" "${2-}")"
      printf '00-%s-%s-01\n' "$t" "$s"
      ;;
    parse-traceparent)
      parse_traceparent "${1-}" || exit 1
      printf '%s %s\n' "$PT_TRACE" "$PT_SPAN"
      ;;
    task-from-git) task_from_git "${1:-HEAD}"; printf '\n' ;;
    task-from-api) task_from_api "${1:-}"; printf '\n' ;;
    detect-host-class) detect_host_class "${1-}"; printf '\n' ;;
    -h | --help | help) usage ;;
    "") usage; exit 2 ;;
    *) printf 'otel-span: unknown command %q\n' "$cmd" >&2; usage >&2; exit 2 ;;
  esac
  return 0
}

# --------------------------------------------------------------------------------------- self-test

# A throwaway OTLP/HTTP receiver on 127.0.0.1 — the Collector stands in, nothing
# leaves the machine. CI cannot otherwise prove a single byte of what it emits.
RX_PID=""
RX_DIR=""

start_receiver() {
  RX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/otel-rx.XXXXXX")
  : >"$RX_DIR/bodies.jsonl"
  python3 - "${1:-200}" "$RX_DIR" >/dev/null 2>&1 <<'PY' &
import http.server
import json
import os
import sys

status = int(sys.argv[1])
outdir = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) or b"{}"
        record = {"path": self.path, "headers": dict(self.headers), "body": json.loads(raw)}
        with open(os.path.join(outdir, "bodies.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(outdir, "port"), "w", encoding="utf-8") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
  RX_PID=$!
  local i=0
  while [ ! -s "$RX_DIR/port" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$RX_DIR/port" ] || return 1
  RX_URL="http://127.0.0.1:$(cat "$RX_DIR/port")"
  return 0
}

stop_receiver() {
  [ -n "$RX_PID" ] && kill "$RX_PID" 2>/dev/null
  wait "$RX_PID" 2>/dev/null
  RX_PID=""
  return 0
}

RX_URL=""
FAILURES=0
CHECKS=0

ok() {
  CHECKS=$((CHECKS + 1))
  printf 'ok %d - %s\n' "$CHECKS" "$1"
}

nope() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'NOT OK %d - %s\n' "$CHECKS" "$1"
  [ $# -gt 1 ] && printf '  %s\n' "$2"
  return 0
}

assert_eq() { # want got label
  if [ "$1" = "$2" ]; then ok "$3"; else nope "$3" "want [$1] got [$2]"; fi
}

bodies() { cat "$RX_DIR/bodies.jsonl" 2>/dev/null; }
body_count() { bodies | grep -c . ; }

# The `Estate-Task` header value for a context env-file, read through the same
# helper the reporter step calls.
ph_header() { bash "$SELF" project-home-header --env-file "$1"; }

# One Project Home request body, built exactly as the reporter builds it: the CI
# fields, and nothing else. Telemetry goes in headers, never in here — a body
# consumer must not have to learn a new field.
ph_body() { # $1 action
  env PH_ACTION="$1" \
    PH_ACTOR="gha:rylee-bee-labs/vefr:7" PH_LEASE_SECONDS=900 \
    PH_OUTCOME="succeeded" PH_NOTE="" \
    PH_RUN_URL="https://github.com/rylee-bee-labs/vefr/actions/runs/7" \
    PH_NOTICE_KEY="self-smoke" PH_NOTICE_CATEGORY="mission" \
    PH_NOTICE_TITLE="ci-harness self-smoke" PH_NOTICE_BODY="request construction only" \
    PH_NOTICE_LINK="" \
    python3 - <<'BODY_PY'
import json
import os

action = os.environ["PH_ACTION"]
if action in {"claim", "heartbeat"}:
    payload = {
        "actor": os.environ["PH_ACTOR"],
        "lease_seconds": int(os.environ["PH_LEASE_SECONDS"]),
    }
elif action == "finish":
    payload = {
        "actor": os.environ["PH_ACTOR"],
        "outcome": os.environ["PH_OUTCOME"],
        "note": os.environ["PH_NOTE"],
        "run_url": os.environ["PH_RUN_URL"],
    }
else:
    payload = {
        "key": os.environ["PH_NOTICE_KEY"],
        "category": os.environ["PH_NOTICE_CATEGORY"],
        "title": os.environ["PH_NOTICE_TITLE"],
        "body": os.environ["PH_NOTICE_BODY"],
        "link": os.environ["PH_NOTICE_LINK"],
    }
print(json.dumps(payload, separators=(",", ":")))
BODY_PY
}

# The reporter's own POST, token aside: both telemetry headers ride the
# `--config -` pipe the template uses, so nothing lands in argv. A notice is a
# task-less call, so it sends neither.
ph_send() { # $1 context env-file, $2 action, $3 body-file
  local tp hdr
  tp=$(sed -n "s/^otel_traceparent='\(.*\)'\$/\1/p" "$1" 2>/dev/null || true)
  hdr=$(ph_header "$1")
  {
    if [ -n "$tp" ]; then
      printf 'header = "traceparent: %s"\n' "$tp"
    fi
    if [ "$2" != "notice" ] && [ -n "$hdr" ]; then
      printf 'header = "Estate-Task: %s"\n' "$hdr"
    fi
    return 0
  } | curl --config - \
    --silent --show-error \
    --output /dev/null --write-out '%{http_code}' \
    --request POST --header "Content-Type: application/json" \
    --data-binary @"$3" "$RX_URL"
}

# What arrived: the header value, or "-" when the header was absent at all, and
# the body's keys in sorted order.
ph_received() {
  bodies | tail -n1 | python3 -c '
import json,sys
r = json.loads(sys.stdin.read())
h = {k.lower(): v for k, v in r["headers"].items()}
print(h.get("traceparent", "-"), h.get("estate-task", "-"), " ".join(sorted(r["body"])))'
}

self_test() {
  # A global, not a local: the EXIT trap runs after self_test's frame is gone.
  SELFTEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/otel-selftest.XXXXXX")
  local tmp="$SELFTEST_TMP"
  export OTEL_BREAKER_FILE="$tmp/breaker"
  trap 'stop_receiver; rm -rf "${SELFTEST_TMP:-}"' EXIT

  # Start from a known-off environment: the self-test must not inherit the
  # machine's own OTEL configuration.
  unset OTEL_SDK_DISABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT \
    OTEL_SERVICE_NAME OTEL_RESOURCE_ATTRIBUTES ESTATE_HOST_CLASS TRACEPARENT OTELSPAN_TASK 2>/dev/null || true

  printf '# otel-span.sh self-test\n\n'

  # --- 1. the contract's trace-id recipe (§2), checked against an independent digest
  local want_t want_r got
  want_t=$(printf 'estate-task|m7|T42' | sha256sum | cut -d' ' -f1); want_t="${want_t:0:32}"
  want_r=$(printf 'estate-task-root|m7|T42' | sha256sum | cut -d' ' -f1); want_r="${want_r:0:16}"
  got=$(bash "$SELF" task-traceparent m7 T42)
  assert_eq "00-${want_t}-${want_r}-01" "$got" "task-traceparent follows sha256(\"estate-task|<m>|<t>\")"
  assert_eq "$(printf '0%.0s' $(seq 31))1" "$(nonzero "$(printf '0%.0s' $(seq 32))")" \
    "an all-zero trace id falls back to last-digit 1 (W3C forbids all-zero)"

  # --- 2. traceparent parsing: strict, and all-zero ids are refused
  assert_eq "$(printf 'a%.0s' $(seq 32)) $(printf 'b%.0s' $(seq 16))" \
    "$(bash "$SELF" parse-traceparent "00-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01")" \
    "parse-traceparent accepts a well-formed W3C header"
  local bad="" one=""
  for bad in "" "garbage" "ff-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01" \
    "00-$(printf '0%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01" \
    "00-$(printf 'a%.0s' $(seq 32))-0000000000000000-01" \
    "00-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-1" \
    "0-$(printf 'a%.0s' $(seq 32))-$(printf 'b%.0s' $(seq 16))-01"; do
    if bash "$SELF" parse-traceparent "$bad" >/dev/null 2>&1; then
      nope "parse-traceparent rejects [$bad]"
    else
      one="$one."
    fi
  done
  assert_eq "......." "$one" "parse-traceparent rejects malformed, ff-version and all-zero ids"

  # --- 3. estate.host.class derivation stays coarse (a label, never a hostname)
  assert_eq "bazzite" "$(bash "$SELF" detect-host-class bazzite)" "runner label bazzite -> bazzite"
  assert_eq "github-hosted" "$(bash "$SELF" detect-host-class ubuntu-latest)" "ubuntu-latest -> github-hosted"
  assert_eq "dev-vm" "$(bash "$SELF" detect-host-class dev-vm)" "dev-vm label -> dev-vm"
  assert_eq "unknown" "$(bash "$SELF" detect-host-class some-weird-box)" "an unknown label degrades to unknown"

  # --- 4. unset endpoint means off (§1): nothing sent, exit 0
  start_receiver 200 || { printf 'self-test: could not start the throwaway receiver\n' >&2; exit 1; }
  bash "$SELF" emit --name off-test --trace-id "$(printf '1%.0s' $(seq 32))" --span-id "$(printf '2%.0s' $(seq 16))" >/dev/null
  assert_eq "0" "$(body_count)" "with no endpoint configured, nothing is sent and the caller still exits 0"
  OTEL_SDK_DISABLED=true OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" \
    bash "$SELF" emit --name off-test --trace-id "$(printf '1%.0s' $(seq 32))" --span-id "$(printf '2%.0s' $(seq 16))" >/dev/null
  assert_eq "0" "$(body_count)" "OTEL_SDK_DISABLED=true wins over a configured endpoint"

  # --- 5. a real span on the wire: OTLP/HTTP JSON to /v1/traces
  export OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL"
  export OTEL_SERVICE_NAME="ci-harness"
  local ctx="$tmp/ctx.env"
  OTELSPAN_JOB_KEY="reusable-python:test" OTELSPAN_PIPELINE_NAME="self-smoke" \
    OTELSPAN_RUN_ID="4242" OTELSPAN_RUN_ATTEMPT="1" OTELSPAN_REPOSITORY="rylee-bee-labs/ci-harness" \
    OTELSPAN_REF_HEAD="otel/ci-19" OTELSPAN_HEAD_REVISION="$(printf 'c%.0s' $(seq 40))" \
    OTELSPAN_CHANGE_ID="314" OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
    bash "$SELF" context --env-file "$ctx" >/dev/null
  # shellcheck disable=SC1090
  . "$ctx"
  assert_eq "$(sha256_hex "cicd-pipeline|4242|1|reusable-python:test" | cut -c1-16)" "${otel_pipeline_span_id}" \
    "the pipeline span id is derived from run id + job key, so every hop agrees"
  bash "$SELF" ci-emit --env-file "$ctx" --role pipeline --result success >/dev/null
  bash "$SELF" ci-emit --env-file "$ctx" --role job --result success >/dev/null

  local blob first second
  blob=$(bodies)
  assert_eq "/v1/traces" "$(printf '%s' "$blob" | head -n1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["path"])')" \
    "spans are POSTed to /v1/traces as the contract requires"
  first=$(printf '%s' "$blob" | sed -n 1p)
  second=$(printf '%s' "$blob" | sed -n 2p)
  local p_attrs j_attrs p_res j_res
  p_attrs=$(printf '%s' "$first" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["traceId"], s["spanId"], s.get("parentSpanId","-"), len(s["attributes"]))')
  j_attrs=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["traceId"], s["spanId"], s.get("parentSpanId","-"), len(s["attributes"]))')
  p_res=$(printf '%s' "$first" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["resource"]["attributes"]
print(" ".join(a["key"]+"="+list(a["value"].values())[0] for a in r))')
  assert_eq "$otel_trace_id ${otel_pipeline_span_id} - 10" "$p_attrs" \
    "the pipeline span carries the standard CI/CD conventions plus vcs and estate attributes"
  assert_eq "$otel_trace_id ${otel_span_id} ${otel_pipeline_span_id} 13" "$j_attrs" \
    "the job span is a child of the pipeline span and adds cicd.pipeline.task.*"

  local want_attrs='cicd.pipeline.name=self-smoke cicd.pipeline.run.id=4242 cicd.pipeline.result=success
cicd.worker.name=bazzite estate.actor.kind=ci estate.host.class=bazzite vcs.repository.name=ci-harness
vcs.ref.head.name=otel/ci-19 vcs.ref.head.revision=cccccccccccccccccccccccccccccccccccccccc
vcs.change.id=314'
  got=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(" ".join(a["key"]+"="+list(a["value"].values())[0] for a in s["attributes"] if not a["key"].startswith("cicd.pipeline.task")))')
  assert_eq "$(printf '%s' "$want_attrs" | tr '\n' ' ' | sed 's/  */ /g;s/ $//')" "$got" \
    "the job span's attributes are exactly the contract's standard names and values"
  assert_eq "service.name=ci-harness service.namespace=estate estate.host.class=bazzite" "$p_res" \
    "the resource carries service.name, service.namespace=estate and estate.host.class"

  got=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(" ".join(a["key"]+"="+list(a["value"].values())[0] for a in s["attributes"] if a["key"].startswith("cicd.pipeline.task")))')
  assert_eq "cicd.pipeline.task.name=reusable-python:test cicd.pipeline.task.run.id=${otel_task_run_id} cicd.pipeline.task.run.result=success" "$got" \
    "the job span carries cicd.pipeline.task.name, task.run.id and task.run.result"

  # The documented extent, checked rather than asserted in prose. The
  # pipeline-role span is named for the pipeline and carries the pipeline's own
  # identity, so a reader will take its duration to mean the pipeline. It does
  # not: it starts when this job's context step runs and ends when this job
  # closes, so its interval is the JOB's. cmd_context says so in as many words;
  # this is what keeps that sentence true if the derivation ever changes.
  got=$(printf '%s' "$first" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["name"], s["startTimeUnixNano"])')
  assert_eq "ci.pipeline.run ${otel_start_ns}" "$got" \
    "the pipeline-role span's interval is the job's interval, not the pipeline's"
  got=$(printf '%s' "$second" | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["name"], s["startTimeUnixNano"])')
  assert_eq "ci.job.run ${otel_start_ns}" "$got" \
    "the job span starts where the job starts — the pipeline span cannot claim otherwise"

  printf '\n--- one real OTLP/HTTP body this self-test captured ---\n'
  printf '%s' "$second" | python3 -c '
import json,sys
print(json.dumps(json.loads(sys.stdin.read())["body"], indent=2))'
  printf -- '--- end body ---\n\n'


  # --- 5b. a span describing one call inside the job (Project Home's /api/ci call)
  bash "$SELF" ci-emit --env-file "$ctx" --role job --result success --child \
    --name project_home.ci_request --parent-span-id "$otel_span_id" \
    --attr "http.request.method=POST" --attr "http.route=/api/ci/tasks/{task_id}/claim" \
    --attr "url.path=/api/ci/tasks/{task_id}/claim" --attr "http.response.status_code=200" >/dev/null
  got=$(bodies | tail -n1 | python3 -c '
import json,sys
s=json.loads(sys.stdin.read())["body"]["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
print(s["traceId"], s["spanId"], s.get("parentSpanId","-"), s["name"], "|",
      " ".join(a["key"]+"="+list(a["value"].values())[0] for a in s["attributes"] if a["key"].startswith("http.")))')
  if [ "${got%% *}" = "$otel_trace_id" ] && [[ "$got" == *" $otel_span_id project_home.ci_request"* ]] \
    && [[ "$got" == *"http.request.method=POST"* ]] && [[ "$got" == *"http.response.status_code=200"* ]]; then
    ok "a call span hangs off the job span, is not its own parent, and carries the standard HTTP attributes"
  else
    nope "a call span hangs off the job span, is not its own parent, and carries the standard HTTP attributes" "got [$got]"
  fi

  unset OTEL_EXPORTER_OTLP_ENDPOINT
  rm -f "$OTEL_BREAKER_FILE"

  # --- 6. a PR a mission lands carries Estate-Task: <mission>/<task> (§2)
  local repo="$tmp/fixture-repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "ci: land the thing

Estate-Task: m9/T7"
  assert_eq "m9/T7" "$(cd "$repo" && bash "$SELF" task-from-git)" \
    "task-from-git reads the Estate-Task trailer off the HEAD commit"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "ci: an ordinary commit with no trailer"
  assert_eq "" "$(cd "$repo" && bash "$SELF" task-from-git)" "a commit with no trailer yields no task"

  # --- 6b. the same trailer for a job with NO checkout. The Project Home
  # reporter has no checkout on purpose, so before this it could never see a
  # trailer: the one job whose whole reason for being on the trace is the
  # correlation was the one job that never got it. It now reads the head
  # commit's message through the API with the job token.
  #
  # `gh` is stood in for by a script on PATH, so this proves the code path and
  # not the network: nothing leaves the machine and the token is a literal.
  local fakebin="$tmp/fakebin" nocheckout="$tmp/no-checkout"
  local wf2
  wf2="$(cd -- "$(dirname -- "$SELF")" && pwd)/../.github/workflows/reusable-project-home.yml"
  mkdir -p "$fakebin" "$nocheckout"
  cat >"$fakebin/gh" <<'FAKE_GH'
#!/bin/sh
# Stand-in for the GitHub CLI. Records how it was called, then answers with one
# commit message. Real gh would read GH_TOKEN from the environment too; the
# recording is what lets a check below prove the token never reached argv.
printf '%s\n' "$*" >"$GH_FAKE_ARGS"
printf '%s\n' "$GH_TOKEN" >"$GH_FAKE_TOKEN"
[ -n "${GH_FAKE_FAIL:-}" ] && exit 1
if [ "${GH_FAKE_TRAILER:-1}" = "1" ]; then
  printf 'ci: land the thing\n\nEstate-Task: m9/T7\n'
else
  printf 'ci: an ordinary commit with no trailer\n'
fi
FAKE_GH
  chmod +x "$fakebin/gh"

  local api_sha api_mission api_task api_header
  api_sha=$(printf 'd%.0s' $(seq 40))
  # The run happens in a directory with no .git in it, and says so: that is the
  # condition the fix exists for, so the test has to hold it rather than assume it.
  assert_eq "1" "$(cd "$nocheckout" && git rev-parse --git-dir >/dev/null 2>&1; [ $? -ne 0 ] && echo 1 || echo 0)" \
    "the API path is exercised from a directory that is not a git repository — no checkout"

  ( cd "$nocheckout" && PATH="$fakebin:$PATH" GITHUB_WORKSPACE="$nocheckout" \
      GITHUB_REPOSITORY="rylee-bee-labs/vefr" GH_TOKEN="ghs_notarealtoken" \
      GH_FAKE_ARGS="$tmp/gh-args" GH_FAKE_TOKEN="$tmp/gh-token" \
      OTELSPAN_HEAD_REVISION="$api_sha" OTELSPAN_JOB_KEY="reusable-project-home:report" \
      OTELSPAN_PIPELINE_NAME="validate" OTELSPAN_RUN_ID="7" OTELSPAN_RUN_ATTEMPT="1" \
      OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
      bash "$SELF" context --env-file "$tmp/ctx-api.env" >/dev/null )
  api_mission=$(grep '^otel_mission_id=' "$tmp/ctx-api.env" | cut -d= -f2- | tr -d "'")
  api_task=$(grep '^otel_task_id=' "$tmp/ctx-api.env" | cut -d= -f2- | tr -d "'")
  assert_eq "m9 T7" "$api_mission $api_task" \
    "with no checkout, the Estate-Task trailer is read through the API and the ids are found"
  assert_eq "$(printf 'estate-task|m9|T7' | sha256sum | cut -d' ' -f1 | cut -c1-32)" \
    "$(grep '^otel_trace_id=' "$tmp/ctx-api.env" | cut -d= -f2- | tr -d "'")" \
    "an API-read trailer joins the same mission trace a git-read one does — the recipe is the ids alone"

  # The finding in one assertion: what the reporter actually puts on the wire.
  api_header=$(ph_header "$tmp/ctx-api.env")
  assert_eq "m9/T7" "$api_header" \
    "so the reporter sends Estate-Task: <mission>/<task> with no checkout to read it from"

  # The API call is exactly one commit message, and the token is not in argv.
  assert_eq "api repos/rylee-bee-labs/vefr/commits/${api_sha} --jq .commit.message" \
    "$(cat "$tmp/gh-args" 2>/dev/null)" \
    "the API read is one head commit message, and nothing else"
  assert_eq "ghs_notarealtoken" "$(cat "$tmp/gh-token" 2>/dev/null)" \
    "the job token reaches gh through the environment"
  if grep -q "ghs_notarealtoken" "$tmp/gh-args" 2>/dev/null; then
    nope "the job token never reaches argv" "argv [$(cat "$tmp/gh-args")]"
  else
    ok "the job token never reaches argv, where a self-hosted runner's other processes could read it"
  fi

  # The negative cases, because a fallback that guesses would be worse than none.
  ( cd "$nocheckout" && PATH="$fakebin:$PATH" GITHUB_WORKSPACE="$nocheckout" \
      GITHUB_REPOSITORY="rylee-bee-labs/vefr" GH_TOKEN="ghs_notarealtoken" \
      GH_FAKE_ARGS="$tmp/gh-args2" GH_FAKE_TOKEN="$tmp/gh-token2" GH_FAKE_TRAILER=0 \
      OTELSPAN_HEAD_REVISION="$api_sha" OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
      bash "$SELF" context --env-file "$tmp/ctx-api-bare.env" >/dev/null )
  assert_eq "2" "$(grep -cE "^otel_(mission|task)_id=''$" "$tmp/ctx-api-bare.env")" \
    "an untrailered commit over the API yields no mission and no task id — no invented pair"
  assert_eq "" "$(ph_header "$tmp/ctx-api-bare.env")" \
    "an untrailered API read sends no Estate-Task header at all"

  ( cd "$nocheckout" && PATH="$fakebin:$PATH" GITHUB_WORKSPACE="$nocheckout" \
      GITHUB_REPOSITORY="rylee-bee-labs/vefr" \
      GH_FAKE_ARGS="$tmp/gh-args3" GH_FAKE_TOKEN="$tmp/gh-token3" \
      OTELSPAN_HEAD_REVISION="$api_sha" OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
      bash "$SELF" context --env-file "$tmp/ctx-api-notoken.env" >/dev/null )
  if [ -f "$tmp/gh-args3" ]; then
    nope "with no token the API is not called at all"
  else
    ok "with no token the API is not called at all — the fallback cannot fail the job"
  fi

  ( cd "$nocheckout" && PATH="$fakebin:$PATH" GITHUB_WORKSPACE="$nocheckout" \
      GITHUB_REPOSITORY="rylee-bee-labs/vefr" GH_TOKEN="ghs_notarealtoken" \
      GH_FAKE_ARGS="$tmp/gh-args4" GH_FAKE_TOKEN="$tmp/gh-token4" GH_FAKE_FAIL=1 \
      OTELSPAN_HEAD_REVISION="$api_sha" OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
      bash "$SELF" context --env-file "$tmp/ctx-api-fail.env" >/dev/null )
  assert_eq "0" "$?" "a failing API read leaves the context command at exit 0 — telemetry never fails CI"

  # A sha is interpolated into a URL path, so only hex is ever allowed there.
  ( cd "$nocheckout" && PATH="$fakebin:$PATH" GITHUB_WORKSPACE="$nocheckout" \
      GITHUB_REPOSITORY="rylee-bee-labs/vefr" GH_TOKEN="ghs_notarealtoken" \
      GH_FAKE_ARGS="$tmp/gh-args5" GH_FAKE_TOKEN="$tmp/gh-token5" \
      OTELSPAN_HEAD_REVISION="main" OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
      bash "$SELF" context --env-file "$tmp/ctx-api-badsha.env" >/dev/null )
  if [ -f "$tmp/gh-args5" ]; then
    nope "a non-hex head sha never reaches the API path"
  else
    ok "a non-hex head sha never reaches the API path — nothing odd is interpolated into a URL"
  fi

  # A checked-out job does not pay for the API. The fixture repo's HEAD carries
  # no trailer, so git has already given the definitive answer — "no trailer" —
  # and the API must not be asked the same question a second time.
  rm -f "$tmp/gh-args6"
  ( cd "$repo" && PATH="$fakebin:$PATH" GITHUB_WORKSPACE="$repo" \
      GITHUB_REPOSITORY="rylee-bee-labs/vefr" GH_TOKEN="ghs_notarealtoken" \
      GH_FAKE_ARGS="$tmp/gh-args6" GH_FAKE_TOKEN="$tmp/gh-token6" \
      OTELSPAN_HEAD_REVISION="$api_sha" OTELSPAN_RUNNER_LABEL="bazzite" \
      bash "$SELF" context --env-file "$tmp/ctx-git-wins.env" >/dev/null )
  if [ -f "$tmp/gh-args6" ]; then
    nope "a job with a checkout spends no API call — git already answered" "argv [$(cat "$tmp/gh-args6")]"
  else
    ok "a job with a checkout spends no API call — git already answered, so the fallback stays off"
  fi

  # And the workflow still has no checkout to read it from — if somebody adds
  # one later, the API path is no longer what runs, and this says so.
  assert_eq "0" "$(grep -c 'actions/checkout' "$wf2" 2>/dev/null || true)" \
    "reusable-project-home.yml still has no checkout: the API read is what makes the trailer available"
  assert_eq "1" "$(grep -c 'GH_TOKEN: ${{ github.token }}' "$wf2" 2>/dev/null || true)" \
    "the reporter passes the job token to the context step, for that one API read"

  OTELSPAN_JOB_KEY="reusable-node:build" OTELSPAN_PIPELINE_NAME="validate" OTELSPAN_RUN_ID="7" \
    OTELSPAN_RUN_ATTEMPT="1" OTELSPAN_REPOSITORY="rylee-bee-labs/vefr" OTELSPAN_REF_HEAD="314/merge" \
    OTELSPAN_CHANGE_ID="314" OTELSPAN_RUNNER_LABEL="ubuntu-latest" \
    bash "$SELF" context --env-file "$tmp/ctx-git.env" --task "m9/T7" >/dev/null
  local g; g=$(grep '^otel_trace_id=' "$tmp/ctx-git.env" | cut -d= -f2- | tr -d "'")
  assert_eq "$(printf 'estate-task|m9|T7' | sha256sum | cut -d' ' -f1 | cut -c1-32)" "$g" \
    "a mission PR joins the task's trace, computed from the ids alone"

  # --- 7. a PR with no trailer gets its own trace, linked by vcs.change.id.
  # Run inside the fixture repo at its untrailered HEAD, not in whatever
  # checkout the self-test happens to be running from: this repo's own HEAD may
  # well carry a mission trailer, and reading that would make "no trailer" a
  # claim about the environment instead of about the code.
  unset OTELSPAN_TASK
  ( cd "$repo" && OTELSPAN_JOB_KEY="reusable-node:build" OTELSPAN_PIPELINE_NAME="validate" \
      OTELSPAN_RUN_ID="7" OTELSPAN_RUN_ATTEMPT="1" OTELSPAN_REPOSITORY="rylee-bee-labs/vefr" \
      OTELSPAN_CHANGE_ID="314" OTELSPAN_RUNNER_LABEL="ubuntu-latest" \
      bash "$SELF" context --env-file "$tmp/ctx-untrailered.env" >/dev/null )
  assert_eq "2" "$(grep -cE "^otel_(mission|task)_id=''$" "$tmp/ctx-untrailered.env")" \
    "an untrailered run computes no mission and no task id"
  g=$(grep '^otel_trace_id=' "$tmp/ctx-untrailered.env" | cut -d= -f2- | tr -d "'")
  if [ "${#g}" -eq 32 ] && [ "$g" != "$(printf 'estate-task||' | sha256sum | cut -d' ' -f1 | cut -c1-32)" ]; then
    ok "a PR with no Estate-Task trailer gets its own 32-hex trace id"
  else
    nope "a PR with no Estate-Task trailer gets its own 32-hex trace id" "got [$g]"
  fi
  assert_eq "otel_change_id='314'" "$(grep '^otel_change_id=' "$tmp/ctx-untrailered.env")" \
    "an untrailered run is still linked back by vcs.change.id"

  # --- 8. the correlation ids ride the Estate-Task request header, and only the
  # header. A span in the right trace with no ids is a span a backend cannot
  # join to anything once the trace is gone, and a mission runs for days, so no
  # single trace spans it. The ids are the header Project Home already reads;
  # they are NOT a new body field, because a body consumer that knows nothing
  # about telemetry must still see a body it recognises.
  local ph_traceparent ph_span
  ph_traceparent=$(sed -n "s/^otel_traceparent='\(.*\)'\$/\1/p" "$tmp/ctx-git.env")
  ph_span=$(sed -n "s/^otel_span_id='\(.*\)'\$/\1/p" "$tmp/ctx-git.env")
  assert_eq "00-$(printf 'estate-task|m9|T7' | sha256sum | cut -d' ' -f1 | cut -c1-32)-${ph_span}-01" "$ph_traceparent" \
    "the traceparent still rides the mission task's trace, unchanged by this"

  assert_eq "m9/T7" "$(ph_header "$tmp/ctx-git.env")" \
    "the helper reads the Estate-Task header value off the context, from the trailer"
  assert_eq "" "$(ph_header "$tmp/ctx-untrailered.env")" \
    "with no trailer the header value is empty — no invented ids, no empty pair"
  assert_eq "" "$(ph_header "$tmp/no-such-context.env")" \
    "no context at all is an empty header value, not an invented one"
  # Half a pair is no pair: one id alone never becomes a header that points a
  # backend at a task this run is not working on.
  printf 'otel_mission_id=%s\notel_task_id=%s\n' "'m9'" "''" >"$tmp/ctx-half.env"
  assert_eq "" "$(ph_header "$tmp/ctx-half.env")" "half a pair is no pair: no Estate-Task header goes out"

  : >"$RX_DIR/bodies.jsonl"
  local ph_action ph_want ph_un_traceparent
  ph_un_traceparent=$(sed -n "s/^otel_traceparent='\(.*\)'\$/\1/p" "$tmp/ctx-untrailered.env")
  for ph_action in claim heartbeat finish; do
    case "$ph_action" in
      claim | heartbeat) ph_want="actor lease_seconds" ;;
      finish) ph_want="actor note outcome run_url" ;;
    esac
    ph_body "$ph_action" >"$tmp/ph-$ph_action.json"

    assert_eq "200" "$(ph_send "$tmp/ctx-git.env" "$ph_action" "$tmp/ph-$ph_action.json")" \
      "a $ph_action request with the trailer still reaches Project Home"
    got=$(ph_received)
    assert_eq "m9/T7" "$(printf '%s' "$got" | cut -d' ' -f2)" \
      "with the trailer, the $ph_action request carries Estate-Task: <mission>/<task> matching it"
    assert_eq "$ph_want" "$(printf '%s' "$got" | cut -d' ' -f3-)" \
      "the $ph_action body is the CI body and nothing else — no mission_id, no mission_task_id"

    assert_eq "200" "$(ph_send "$tmp/ctx-untrailered.env" "$ph_action" "$tmp/ph-$ph_action.json")" \
      "a $ph_action request with no trailer still reaches Project Home"
    got=$(ph_received)
    assert_eq "-" "$(printf '%s' "$got" | cut -d' ' -f2)" \
      "with no trailer, the $ph_action request carries no Estate-Task header at all"
    assert_eq "$ph_want" "$(printf '%s' "$got" | cut -d' ' -f3-)" \
      "the untrailered $ph_action body is the same CI body — a missing id, not an empty one"
    assert_eq "$ph_un_traceparent" "$(printf '%s' "$got" | cut -d' ' -f1)" \
      "the untrailered $ph_action still sends its own traceparent — the header is optional, not the trace"
  done

  ph_body notice >"$tmp/ph-notice.json"
  assert_eq "200" "$(ph_send "$tmp/ctx-git.env" notice "$tmp/ph-notice.json")" \
    "a notice still reaches Project Home on a mission's HEAD commit"
  got=$(ph_received)
  assert_eq "-" "$(printf '%s' "$got" | cut -d' ' -f2)" \
    "a notice carries no Estate-Task header: it belongs to no task"
  assert_eq "body category key link title" "$(printf '%s' "$got" | cut -d' ' -f3-)" \
    "the notice body is the notice body, with no task identity in it"
  assert_eq "self-smoke" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["key"])' "$tmp/ph-notice.json")" \
    "the notice body is otherwise unchanged by the header going out on the other three"

  # traceparent and Estate-Task are two different things and both are wanted:
  # one is where this hop sits in the trace, the other is which mission task it
  # is working on. Neither is derived from the other, and neither replaces it.
  got=$(ph_send "$tmp/ctx-git.env" claim "$tmp/ph-claim.json" >/dev/null; ph_received)
  assert_eq "${ph_traceparent} m9/T7" "$(printf '%s' "$got" | cut -d' ' -f1-2)" \
    "traceparent and Estate-Task both go out, each unchanged by the other"

  # The whole request as it goes on the wire: the ids in the header, and a body
  # that is still the body CI knows.
  printf '\n--- one real Project Home request this self-test captured ---\n'
  printf 'POST /api/ci/tasks/42/claim\n'
  printf 'traceparent: %s\n' "$ph_traceparent"
  printf 'Estate-Task: %s\n' "$(ph_header "$tmp/ctx-git.env")"
  printf '\n'
  cat "$tmp/ph-claim.json"
  printf '\n'
  printf -- '--- end request ---\n\n'

  # --- 8b. the reporter step does the same thing, and nothing more. A workflow
  # file is otherwise unproven until a runner on the far side of the LAN runs it.
  local wf2 step_body req_body hdr_line guard_line2 curl_line body_line
  wf2="$(cd -- "$(dirname -- "$SELF")" && pwd)/../.github/workflows/reusable-project-home.yml"
  step_body=$(sed -n '/- name: Build and send bounded Project Home request/,$p' "$wf2" 2>/dev/null)
  req_body=$(printf '%s\n' "$step_body" \
    | sed -n '/python3 - <<.PY. > "\$RUNNER_TEMP\/project-home-request.json"/,/^ *PY$/p')
  hdr_line=$(printf '%s\n' "$step_body" | grep -n 'header = "Estate-Task' | head -n1 | cut -d: -f1)
  guard_line2=$(printf '%s\n' "$step_body" | grep -n 'if \[ -n "\$ph_estate_task" \]' | head -n1 | cut -d: -f1)
  curl_line=$(printf '%s\n' "$step_body" | grep -n '| curl --config -' | head -n1 | cut -d: -f1)
  if [ -n "$hdr_line" ] && [ -n "$guard_line2" ] && [ -n "$curl_line" ] \
    && [ "$guard_line2" -lt "$hdr_line" ] && [ "$hdr_line" -lt "$curl_line" ] \
    && printf '%s' "$step_body" | grep -q 'project-home-header --env-file'; then
    ok "the reporter step derives Estate-Task from the helper and sends it as a request header, off argv"
  else
    nope "the reporter step derives Estate-Task from the helper and sends it as a request header, off argv" \
      "helper [$(printf '%s' "$step_body" | grep -c 'project-home-header')] guard [$guard_line2] header [$hdr_line] curl [$curl_line]"
  fi
  body_line=$(printf '%s\n' "$req_body" | grep -n 'mission' | head -n1 | cut -d: -f1)
  if [ -n "$req_body" ] && [ -z "$body_line" ]; then
    ok "the reporter step's request body builder mentions no mission id — one interface, not two"
  else
    nope "the reporter step's request body builder mentions no mission id — one interface, not two" \
      "body block [$req_body] mission line [$body_line]"
  fi
  # A notice is a task-less call even on a mission's HEAD: the header is computed
  # for the three task calls only, which is the decision this greps for.
  notice_line=$(printf '%s\n' "$step_body" | grep -n '\[ "\$PH_ACTION" != "notice" \]' | head -n1 | cut -d: -f1)
  helper_call=$(printf '%s\n' "$step_body" | grep -n 'project-home-header --env-file' | head -n1 | cut -d: -f1)
  if [ -n "$notice_line" ] && [ -n "$helper_call" ] && [ "$notice_line" -lt "$helper_call" ]; then
    ok "the reporter step withholds Estate-Task from a notice, which belongs to no task"
  else
    nope "the reporter step withholds Estate-Task from a notice, which belongs to no task" \
      "notice guard [$notice_line] helper call [$helper_call]"
  fi

  # traceparent is a different thing from Estate-Task, and both are wanted: the
  # first says where this hop sits in the trace, the second which mission task it
  # is working on. Adding the second must never have cost the first.
  tp_line=$(printf '%s\n' "$step_body" | grep -n 'header = "traceparent' | head -n1 | cut -d: -f1)
  if [ -n "$tp_line" ] && [ "$tp_line" -lt "$curl_line" ] && printf '%s' "$step_body" | grep -q 'header = "Authorization: Bearer'; then
    ok "the reporter step still sends the traceparent, and still off argv, beside the Estate-Task ids"
  else
    nope "the reporter step still sends the traceparent, and still off argv, beside the Estate-Task ids" \
      "traceparent line [$tp_line] curl [$curl_line]"
  fi

  # --- 9. a GitHub-hosted runner never emits a span that cannot arrive (§1)
  : >"$RX_DIR/bodies.jsonl"
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" GITHUB_STEP_SUMMARY="$tmp/summary.md" \
    bash "$SELF" ci-emit --env-file "$tmp/ctx-untrailered.env" --role job --result success >/dev/null
  assert_eq "0" "$(body_count)" "host-class github-hosted sends nothing at all"
  if grep -q "github-hosted" "$tmp/summary.md" 2>/dev/null; then
    ok "host-class github-hosted says so in the step summary instead of failing silently"
  else
    nope "host-class github-hosted says so in the step summary instead of failing silently"
  fi

  # --- 9b. the reporter workflow's own emitter step carries the same guard, in
  # the same form, ahead of the call it guards. Checked here because a workflow
  # file is otherwise unproven until a runner on the far side of the LAN runs it.
  local wf otel_body otel_start otel_end guard_line call_line helper_line
  wf="$(cd -- "$(dirname -- "$SELF")" && pwd)/../.github/workflows/reusable-project-home.yml"
  otel_start=$(grep -n '^ *otel() {' "$wf" 2>/dev/null | head -n1 | cut -d: -f1)
  otel_end=$(awk -v s="${otel_start:-0}" 'NR>s && /^ *\}$/ {print NR; exit}' "$wf" 2>/dev/null)
  otel_body=$(sed -n "${otel_start:-0},${otel_end:-0}p" "$wf" 2>/dev/null)
  guard_line=$(printf '%s\n' "$otel_body" | grep -n 'github-hosted' | head -n1 | cut -d: -f1)
  call_line=$(printf '%s\n' "$otel_body" | grep -n 'ci-emit --env-file' | head -n1 | cut -d: -f1)
  if [ -n "$guard_line" ] && [ -n "$call_line" ] && [ "$guard_line" -lt "$call_line" ] \
    && printf '%s' "$otel_body" | grep -q 'otel_host_class' \
    && printf '%s' "$otel_body" | grep -q 'GITHUB_STEP_SUMMARY'; then
    ok "the Project Home reporter step guards on github-hosted — and says so in the step summary — before it emits"
  else
    nope "the Project Home reporter step guards on github-hosted — and says so in the step summary — before it emits" \
      "otel() body [${otel_body}] guard line [$guard_line] ci-emit line [$call_line]"
  fi
  # Same wording on both sides, so the two guards cannot drift apart: one of them
  # explaining something the other would not is how a step starts looking exempt.
  # The sentence carries no markdown backticks: a backtick inside the single-quoted
  # `run:` body reads as command substitution to shellcheck (SC2016), which fails
  # the actionlint gate. The locator matches the bare sentence; the equality below
  # is unchanged and still byte-for-byte.
  guard_line=$(grep -m1 "Host class is github-hosted" "$SELF" | sed "s/^[[:space:]]*printf '//")
  helper_line=$(grep -m1 "Host class is github-hosted" "$wf" | sed "s/^[[:space:]]*printf '//")
  if [ -n "$guard_line" ] && [ "$guard_line" = "$helper_line" ]; then
    ok "the reporter step's hosted-runner note is the helper's own sentence, verbatim"
  else
    nope "the reporter step's hosted-runner note is the helper's own sentence, verbatim" \
      "helper [$guard_line] workflow [$helper_line]"
  fi

  # --- 9c. the runner label outranks the environment (§3). A repository variable
  # is one edit away; the runner label is what the platform put on the machine.
  : >"$RX_DIR/bodies.jsonl"
  rm -f "$OTEL_BREAKER_FILE"
  assert_eq "github-hosted" "$(ESTATE_HOST_CLASS=bazzite bash "$SELF" detect-host-class ubuntu-latest)" \
    "a hosted runner label outranks ESTATE_HOST_CLASS, whatever the environment claims"
  OTELSPAN_RUNNER_LABEL="ubuntu-latest" ESTATE_HOST_CLASS="bazzite" OTELSPAN_READ_GIT=0 \
    bash "$SELF" context --env-file "$tmp/ctx-hosted.env" >/dev/null
  assert_eq "github-hosted" "$(grep '^otel_host_class=' "$tmp/ctx-hosted.env" | cut -d= -f2- | tr -d "'")" \
    "the context reports host class github-hosted for a hosted label, not the self-hosted-looking value"
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" GITHUB_STEP_SUMMARY="$tmp/summary-hosted.md" \
    bash "$SELF" ci-emit --env-file "$tmp/ctx-hosted.env" --role job --result success >/dev/null
  assert_eq "0" "$(body_count)" "a hosted runner cannot be talked into sending: nothing goes on the wire"

  # --- 9d. the same precedence must not silence a runner that can send
  : >"$RX_DIR/bodies.jsonl"
  OTELSPAN_RUNNER_LABEL="bazzite" OTELSPAN_READ_GIT=0 \
    bash "$SELF" context --env-file "$tmp/ctx-self.env" >/dev/null
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" \
    bash "$SELF" ci-emit --env-file "$tmp/ctx-self.env" --role job --result success >/dev/null
  ESTATE_HOST_CLASS=bazzite OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" \
    bash "$SELF" ci-emit --env-file "$tmp/ctx-self.env" --role job --result success >/dev/null
  assert_eq "2" "$(body_count)" "a self-hosted label still sends — with ESTATE_HOST_CLASS unset, and with it agreeing"

  # --- 10. an unreachable Collector costs one timeout, then nothing, and never fails
  unset OTEL_EXPORTER_OTLP_ENDPOINT
  local t0 t1 rc
  t0=$(date +%s%N)
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:9" bash "$SELF" ci-emit --env-file "$ctx" --role job --result failure >/dev/null
  rc=$?
  t1=$(date +%s%N)
  assert_eq "0" "$rc" "an unreachable Collector leaves the exit code at 0 — telemetry never fails CI"
  if [ -f "$OTEL_BREAKER_FILE" ]; then ok "one failed send trips the circuit breaker for the rest of the job"; else nope "one failed send trips the circuit breaker for the rest of the job"; fi
  t0=$(date +%s%N)
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:9" bash "$SELF" ci-emit --env-file "$ctx" --role pipeline --result failure >/dev/null
  t1=$(date +%s%N)
  if [ $(( (t1 - t0) / 1000000 )) -lt 500 ]; then
    ok "after the breaker trips, a second span costs no further dial"
  else
    nope "after the breaker trips, a second span costs no further dial" "$(( (t1 - t0) / 1000000 )) ms"
  fi
  rm -f "$OTEL_BREAKER_FILE"

  # --- 11. a Collector answering 500 trips the breaker after one send
  stop_receiver
  start_receiver 500 || { printf 'self-test: could not start the failing receiver\n' >&2; exit 1; }
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" bash "$SELF" ci-emit --env-file "$ctx" --role pipeline --result failure >/dev/null
  OTEL_EXPORTER_OTLP_ENDPOINT="$RX_URL" bash "$SELF" ci-emit --env-file "$ctx" --role job --result failure >/dev/null
  assert_eq "1" "$(body_count)" "a Collector answering 500 is sent exactly one request, then the breaker holds"

  printf '%d checks, %d failures\n' "$CHECKS" "$FAILURES"
  [ "$FAILURES" -eq 0 ] || return 1
  printf 'otel-span.sh self-test: OK\n'
  return 0
}

main "$@"