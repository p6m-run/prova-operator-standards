# p6m Operator Standards — the executable bar

This document is the spec the `operator-standards` prova plugin turns into proofs. Every p6m Rust
Kubernetes operator must pass the same parameterized suite. The goal: **operators that are
indistinguishable from each other at the observability boundary** — same probe paths, same metrics
surface, same log shape, same env contract — so that dashboards, alerts, and runbooks are written
once and apply to all of them.

Sibling to `p6m-archetypes/prova-p6m-standards` (S1–S10, for services). That document's governing
principle is inherited verbatim:

> **Idiomatic inside, identical at the boundary.** Every requirement is stated in terms a black-box
> caller can observe. Compliance is sameness of behavior, not sameness of code.

Which is why these standards assert **the wire contract, not the dependency**. `p6m-kube-metrics`
already implements all of O1–O5 and adopting it is the obvious way to pass — but the proofs never
assert that an operator depends on it. An operator that satisfies the contract another way is
compliant. (DECIDED 2026-07-28.)

## 1. Why this exists — a drift snapshot

> **This table is dated 2026-07-28 and is not maintained.** It records the survey that motivated
> these standards. It is **not** a status board. **For current status, run the suite** — the proofs
> are the live answer, and prose about compliance goes stale by construction.
>
> The survey itself demonstrated the hazard. A first pass concluded "the shared library provides no
> observability at all" — read off a `platform-kubernetes-libraries` working copy sitting on an old
> commit, where `p6m-kube-metrics` did not yet exist. On origin's `main` it did, and had for
> versions. **Verify against the org's `main`, or against a suite run — never a working copy.**

Surveyed across the eight operators, each at origin/`main`:

| Operator | health/metrics surface | probes wired in chart | log format honored | OTel export |
|---|---|---|---|---|
| `github-operator` | ✗ none | ✗ | ✓ | ✗ |
| `installation-operator` | ⚠️ own `/health` on the webhook port | ✗ | ✗ — `_settings` ignored | ✗ — commented out |
| `platform-agent-operator` | ✗ none | ✗ | ✓ | ✗ |
| `platform-application-operator` | ✓ `p6m-kube-metrics` | ✓ | ✓ | ✗ — no `otel` feature |
| `platform-cluster-operator` | ✓ `p6m-kube-metrics` | ✓ | ✗ — `_settings` ignored | ✓ |
| `platform-edge-operator` | ✗ none | ✗ | ✓ | ✗ |
| `platform-organization-operator` | ✗ none (TLS-only webhook server) | ✗ | ✓ | ✗ |
| `platform-resource-operator` | ✓ `p6m-kube-metrics` | ✓ | ✓ | ✗ |

What the survey found, stated as the failure modes these standards exist to catch:

- **Five of eight expose no health, readiness, or metrics endpoint at all.** Their `routes.rs` is a
  copy-pasted axum `Router` with a single `/` handler returning the operator's display name as a
  string literal. Nothing probes them; nothing scrapes them.
- **A chart can probe a path the binary does not serve.** This is the defect class O6 exists for,
  and it is the reason the bar does not stop at the container.
- **Dead config reads as configured.** `installation-operator` and `platform-cluster-operator` both
  have `setup_tracing(_settings)` — the parameter is discarded, so `OPERATOR_TRACING_FORMAT` is
  inert in both while looking wired in the chart and the config struct alike.
- **Pinned dependencies are not wiring.** `installation-operator` depends on `opentelemetry`,
  `opentelemetry-otlp`, and `tracing-opentelemetry`, and exports no spans: its `OpenTelemetryLayer`
  registration is commented out, leaving `create_otlp_tracer_provider()` as unreachable code. Its
  tracer name is also hardcoded to `"platform-cluster-operator"` — a copy-paste that would have
  mislabeled every span had the layer ever been enabled.
- **`platform-organization-operator` has no plaintext port at all.** Its only HTTP server is
  TLS-only (OpenSSL) on the webhook port, so there is nowhere for a kubelet HTTP probe or a
  Prometheus scrape to land.

## 2. The standard

An operator is not a service, and the differences drive the whole shape of this bar. It exposes no
CRUD API, so there is no equivalent of the services' S2. It is a **control loop**, so what is
observable is: is it alive, is it ready, how is reconciliation going, and can I correlate one
reconcile with what it did downstream. Its "request" is a watch event it gave itself.

The management surface below is the operator's **only** required port. Anything else it serves —
a validating webhook on TLS, an admission endpoint — is out of scope here and unconstrained.

### O1 — One management port, plaintext, always
A plain **HTTP** listener on `MANAGEMENT_HOST` : `MANAGEMENT_PORT`, defaulting to `0.0.0.0:9090`,
carrying every endpoint in O2–O4. Plaintext is a requirement, not an accident: a kubelet HTTP probe
and a Prometheus scrape both land here, and TLS on this port means neither can. An operator that
also serves a webhook does so on a **different** port.

The env var names are the platform's, honored as given —
`OPERATOR_METRICS_HOST` / `OPERATOR_METRICS_PORT` are the current names and remain the contract
(they are what `p6m-kube-metrics` reads and what the charts inject). Proof: boot with an
**overridden** port and observe the operator actually listening there. That is the assertion that
catches config which is parsed but discarded.

### O2 — Liveness
`GET /healthz` → **200**, unconditionally, for as long as the process is running and its event loop
is not wedged. Liveness answers "should the kubelet kill this pod", and the answer must not depend
on the Kubernetes API server being reachable: an API outage that makes every operator fail liveness
converts a control-plane blip into a fleet-wide crash-loop. **Readiness is where dependency truth
belongs; liveness is not.**

### O3 — Readiness
`GET /readyz` → **200** when the operator is ready to reconcile, **503** when it is not. Unlike
liveness this must reflect real state, and two transitions are required:

- **Not ready before the controllers are running.** A fresh process that has not yet established
  its watches answers 503.
- **Not ready during graceful shutdown.** On SIGTERM the operator answers 503 *before* the process
  exits, so it leaves the Service's endpoints and stops receiving traffic instead of being torn out
  from under an in-flight reconcile.

The second is the one that is easy to miss and expensive to lack, and it is asserted directly.

### O4 — Metrics
`GET /metrics` → **200**, Prometheus/OpenMetrics text format
(`application/openmetrics-text` or `text/plain; version=0.0.4`), carrying at minimum the reconcile
family, prefixed by the operator's snake_case name:

| Metric | Type | Notes |
|---|---|---|
| `{prefix}_reconcile_runs_total` | counter | |
| `{prefix}_reconcile_failures_total` | counter | labels: `instance`, `error` |
| `{prefix}_reconcile_duration_seconds` | histogram | trace exemplars where OTel is on |

At least one real family must be present and parseable — a stub string is a failure. The `error`
label must be a **bounded classification** (a variant name), never a formatted error message:
unbounded label values are a cardinality bomb in Prometheus, and this is the one metrics property
whose violation degrades the monitoring system itself rather than just the signal.

### O5 — Structured logging
With the structured format selected (`OPERATOR_TRACING_FORMAT=json`): stdout is JSON-lines, every
record parses, and each carries at least `timestamp`, `level`, and `message` (however the ecosystem
spells them), plus service identity. With it unset or `standard`: human-readable.

Proven **from both directions**, adopting the ratchet `prova-p6m-standards` S4 had to add after the
one-sided version shipped: the primary SUT (format `json`) must emit JSON lines, and a sibling boot
of the same image with format `standard` must emit at least one **non**-JSON line. An operator that
always logs JSON and merely accepts the variable fails — that is exactly the
`setup_tracing(_settings)` defect, and a one-directional assertion cannot see it.

### O6 — The chart agrees with the binary (DECIDED 2026-07-28)
The defect this catches is real and was found in production during the survey: a chart wiring
`livenessProbe: /healthz` and `readinessProbe: /readyz` on port `metrics` while the binary served
neither. Every probe a chart declares must name a path and port the SUT actually answers. Asserted
**across** artifacts, never within one:

- `livenessProbe.httpGet.path` and `readinessProbe.httpGet.path` are `/healthz` and `/readyz`
- the probe's port resolves — through the container's named ports — to the management port of O1
- both paths **answer on the running SUT** (the cross-artifact half: a chart consistent with a
  binary that 404s is still broken)
- `containerPort` for the management port is declared, so the port has a name to reference
- the scheme is HTTP, not HTTPS (O1)

An operator whose chart declares no probes fails this: an unprobed liveness endpoint is
indistinguishable from an absent one at 3am. (This is the gap `prova-p6m-standards` S5 notes for
services — "liveness is implemented and never probed" — closed here rather than inherited.)

### O7 — Traces, fail-open
OTel wired **fail-open**: exporting iff `OTEL_EXPORTER_OTLP_ENDPOINT` is set, and booting normally
when it is not. An unreachable or absent collector may never prevent the operator from starting or
reconciling — telemetry is not a dependency of the control loop.

Two properties, in order of how much they are worth:

- **Fail-open is a proof.** Boot with `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at an address nothing
  listens on; the operator must still become ready and still serve O2–O4. Cheap, and it catches the
  regression that takes a fleet down.
- **Spans actually arrive** is the phase-2 proof: an OTLP sink on the cluster receives ≥1 span from
  a reconcile. Held as an **open spec** until the sink double lands (see §4), because asserting it
  today would mean asserting nothing.

Where a tracer is named, the name must be the operator's own — the `installation-operator`
copy-paste is the failure mode.

### O8 — Suite hygiene
`prova.toml` uses `[run] proofs = [...]`; plugins pinned to **released tags**, never `@main`;
`.last-failed.json` gitignored and untracked; `acceptance.yaml` on `prova-rs/run-action@v1` with an
explicit `version:` (its default release goes stale as prova moves). The suite requires **docker,
kind, and kubectl** and no Rust toolchain on the host: what is proven is the image CI publishes,
under the env contract the chart injects.

## 3. The plugin: `prova-operator-standards` (require name `operator-standards`)

Everything is parameterized by the operator's identity, so expectations are a pure function of one
answer key and no proof restates the contract:

```lua
local ops = require("operator-standards")

local id = ops.identity{ name = "platform-cluster-operator" }
-- id.project_name == "platform-cluster-operator"
-- id.metric_prefix == "platform_cluster_operator"   → {prefix}_reconcile_runs_total

local sut = ops.sut{ dir = prova.root, id = id, cluster = cluster }
-- docker.build the production image → kind load → apply Deployment → wait ready → port_forward

ops.standards.management(t, sut, id)   -- O1: the port contract, honored as injected
ops.standards.health(t, sut, id)       -- O2, O3: liveness unconditional, readiness transitions
ops.standards.metrics(t, sut, id)      -- O4: format, families, bounded label cardinality
ops.standards.logging(t, sut, id)      -- O5: both directions
ops.standards.chart(t, id)             -- O6: cross-artifact, chart ↔ SUT
ops.standards.traces(t, sut, id)       -- O7: fail-open now, delivery as a spec
```

- `ops.identity(spec)` — the naming oracle: the single source of truth for the metric prefix, chart
  name, and image tag derived from an operator's repo name.
- `ops.contract` — the wire contract as data (paths, statuses, content types, env var names), so
  the suite and any future generator read the same table.
- `ops.sut{}` — the containerized-operator fixture: build the production image, load it into the
  kind cluster, apply a minimal Deployment with the env contract, wait on readiness, port-forward
  the management port. One per variant; teardown rides the scope.
- `ops.standards.*` — the shared suites each operator's thin proof file invokes.

Consumption, in each operator repo:

```toml
[plugins]
operator-standards = { git = "https://github.com/p6m-run/prova-operator-standards", tag = "v1" }
kind = { git = "https://github.com/prova-rs/prova-kind", tag = "v1" }
```

**Substrate.** A real control plane, via `prova-kind` — taken over and implemented for this work
(it was an unreleased skeleton). A mocked API server was considered and rejected: a Kubernetes
client does discovery then opens long-lived watches with `resourceVersion` bookkeeping, and faking
that faithfully costs more than running the real thing while making the result weaker evidence. One
cluster is shared per file (~30s to create), and every operator's suite skips cleanly where kind,
kubectl, or docker are absent.

## 4. Retrofit plan (PDD, axis by axis)

- **Phase 0 — decisions.** Wire contract vs. mandated dependency (DECIDED: contract). Bar includes
  chart wiring (DECIDED: yes, O6). Substrate (DECIDED: real cluster via `prova-kind`).
- **Phase 1 — plugin + reference operator.** Implement `identity`, `contract`, `sut`, and the
  standards suites; wire into **`platform-cluster-operator`** first — it is furthest along
  (`p6m-kube-metrics` with all three features, probes wired, spans exporting), so it isolates plugin
  bugs from operator gaps. Its one known gap (`_settings` discarded, O5) should be the first red the
  suite produces, and is the proof the suite works.
- **Phase 2 — sweep by axis, not by repo.** Hygiene first (O8 — mechanical, all repos in one pass).
  Then O1–O4 for the five operators with no management surface at all; that is one shared change
  shape, not five investigations. Then O5 for the two with dead config, then O6 charts, then O7.
- **Phase 3 — close the specs.** An OTLP sink double, so O7's delivery half graduates from spec to
  proof. Candidate: a `prova-otlp` sink plugin, sibling to `prova-kind`, since nothing in the
  ecosystem provides one.
- **Phase 4 — the shared implementation.** Where an axis is satisfied identically by every
  operator, that is a signal it belongs in `p6m-kube-metrics` (O5's format switch is the obvious
  candidate — six operators have the same `match settings.format()` block copy-pasted). The suite
  is what makes that consolidation safe to attempt.

### Non-goals

**No functional change.** These are production operators; this work adds observability wiring and
proofs, and touches no reconciliation logic. Where a standard cannot be met without changing
behavior, the proof is authored as an open **spec** naming the reason, and the decision is escalated
rather than absorbed. `platform-organization-operator` is the live instance: it has no plaintext
listener, so O1 requires adding one alongside its TLS webhook server.
