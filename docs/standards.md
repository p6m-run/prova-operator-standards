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
implements all of O1–O5 and adopting it is the obvious way to pass — but the proofs never assert that
an operator depends on it. An operator that satisfies the contract another way is compliant.

**This document is the bar, not a status board.** It says nothing about which operators currently
comply, because prose about compliance goes stale by construction. For status, run the suite.

## The standard

An operator is not a service, and the differences drive the whole shape of this bar. It exposes no
CRUD API, so there is no equivalent of the services' S2. It is a **control loop**, so what is
observable is: is it alive, is it ready, how is reconciliation going, and can I correlate one
reconcile with what it did downstream. Its "request" is a watch event it gave itself.

The management surface below is the operator's **only** required port. Anything else it serves —
a validating webhook on TLS, an admission endpoint — is out of scope here and unconstrained.

### O1 — One management port, plaintext, always

A plain **HTTP** listener on `OPERATOR_METRICS_HOST` : `OPERATOR_METRICS_PORT`, defaulting to
`0.0.0.0:9090`, carrying every endpoint in O2–O4. Plaintext is a requirement, not an accident: a
kubelet HTTP probe and a Prometheus scrape both land here, and TLS on this port means neither can. An
operator that also serves a webhook does so on a **different** port.

Those env var names are the contract, honored as given — they are what `p6m-kube-metrics` reads and
what the charts inject.

Proof: boot with an **overridden** port and observe the operator actually listening there. Asserting
the default would pass an operator that parses the variable and discards it, which is a defect that
looks identical to correct configuration from the outside.

### O2 — Liveness

`GET /healthz` → **200**, unconditionally, for as long as the process is running and its event loop
is not wedged. Liveness answers "should the kubelet kill this pod", and the answer must not depend on
the Kubernetes API server being reachable: an API outage that made every operator fail liveness would
convert a control-plane blip into a fleet-wide crash-loop. **Readiness is where dependency truth
belongs; liveness is not.**

### O3 — Readiness

`GET /readyz` → **200** when the operator is ready to reconcile, **503** when it is not. Unlike
liveness this must reflect real state, and two transitions are required:

- **Not ready before the controllers are running.** A fresh process that has not yet established its
  watches answers 503.
- **Not ready during graceful shutdown.** On SIGTERM the operator answers 503 *before* the process
  exits, so it leaves the Service's endpoints and stops receiving traffic instead of being torn out
  from under an in-flight reconcile.

The second is the one that is easy to miss and expensive to lack.

### O4 — Metrics

`GET /metrics` → **200**, Prometheus/OpenMetrics text format (`application/openmetrics-text` or
`text/plain; version=0.0.4`), carrying at minimum the reconcile family, prefixed by the operator's
snake_case name:

| Metric | Type | Notes |
|---|---|---|
| `{prefix}_reconcile_runs_total` | counter | |
| `{prefix}_reconcile_failures_total` | counter | labels: `instance`, `error` |
| `{prefix}_reconcile_duration_seconds` | histogram | trace exemplars where OTel is on |

Asserted via each family's `# TYPE` **declaration**, not by looking for a sample line. A labelled
family legitimately has no series until it has a child — `reconcile_failures` does not appear until
the first failure is recorded — and demanding a sample would mean pre-registering a fake
`instance`/`error` pair, putting a bogus series in every production dashboard. The declaration is the
property that matters: it is what makes the family discoverable and what an alert rule binds to.

The `error` label must be a **bounded classification** (a variant name), never a formatted error
message. Unbounded label values are a cardinality bomb in Prometheus, and this is the one metrics
property whose violation degrades the monitoring system itself rather than just the signal.

### O5 — Structured logging

With the structured format selected (`OPERATOR_TRACING_FORMAT=json`): stdout is JSON-lines, every
record parses, and each carries at least `timestamp`, `level`, and `message` (however the ecosystem
spells them), plus service identity. With it unset or `standard`: human-readable.

Proven **from both directions**, adopting the ratchet `prova-p6m-standards` S4 had to add after the
one-sided version shipped: the primary SUT (format `json`) must emit JSON lines, and a sibling boot of
the same image with format `standard` must emit at least one **non**-JSON line.

Both directions are required because the two failure modes are opposite and each hides from a
one-sided assertion. An operator that always logs JSON and merely accepts the variable passes a
JSON-only check; an operator that ignores the variable and always logs human-readable passes a
human-only check. Only the pair catches config that is threaded through the chart and the config
struct and then discarded at the point of use.

### O6 — The chart agrees with the binary

Every probe a chart declares must name a path and port the binary actually answers. Asserted
**across** artifacts, never within one:

- the operator **ships a Helm chart** at `helm/` — this is the first assertion in the axis, so an
  operator packaged some other way is a caught defect rather than a special case
- `livenessProbe.httpGet.path` and `readinessProbe.httpGet.path` are `/healthz` and `/readyz`
- the probe's port resolves — through the container's named ports — to the management port of O1
- `containerPort` for the management port is declared, so the port has a name to reference
- the scheme is HTTP, not HTTPS (O1)
- both paths **answer on the running SUT** — the cross-artifact half: a chart consistent with a
  binary that 404s is still broken

The defect class this exists for is a chart wiring `livenessProbe: /healthz` on port `metrics` while
the binary serves neither, which is indistinguishable from correctness until the probe fires. The
converse also fails: an operator whose chart declares no probes, because an unprobed liveness
endpoint is indistinguishable from an absent one at 3am. (That is the gap `prova-p6m-standards` S5
notes for services — "liveness is implemented and never probed" — closed here rather than inherited.)

**Known limit.** This axis proves the chart, not the deployed artifact. Where an operator is deployed
from something other than its chart, a green O6 does not imply the running pod is probed.

### O7 — Traces, fail-open

OTel wired **fail-open**: exporting iff `OTEL_EXPORTER_OTLP_ENDPOINT` is set, and booting normally
when it is not. An unreachable or absent collector may never prevent the operator from starting or
reconciling — telemetry is not a dependency of the control loop.

Two properties, in order of how much they are worth:

- **Fail-open is a proof.** Boot with `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at an address nothing
  listens on; the operator must still become ready and still serve O2–O4. Cheap, and it catches the
  regression that takes a fleet down.
- **Spans actually arrive** is the phase-2 proof: an OTLP sink on the cluster receives ≥1 span from a
  reconcile. Held as an **open spec** until a sink double exists, because asserting it today would
  mean asserting nothing.

Where a tracer is named, the name must be the operator's own. A copied tracer name mislabels every
span the operator emits, and is invisible until someone queries by service.

### O8 — Suite hygiene

`prova.toml` uses `[run] proofs = [...]`; plugins pinned to **released tags**, never `@main`;
`.last-failed.json` gitignored and untracked; the proofs workflow on `prova-rs/run-action@v1` with an
explicit `version:` (its default release goes stale as prova moves). The suite requires **docker,
kind, and kubectl** and no Rust toolchain on the host: what is proven is the image CI publishes, under
the env contract the chart injects.

**The `dev` exception.** One moving ref is sanctioned: `branch = "dev"`, the org's integration branch,
which `prova-p6m-standards` and every archetype repo carry alongside `main`. Pinning it is how a
standards plugin is iterated on before it has earned a release; holding consumers to a tag that does
not exist yet would block the work the bar exists to enable.

It is allowed **by name, not by silence**: the proof matches `dev` explicitly and prints a reminder
that the pin must graduate. `main` stays forbidden — it is the release branch, so pinning it buys
whatever shipped last with none of a tag's reproducibility.

#### The reverse spec — a phase tracker that cannot rot

A pin to `dev` has an expiry, and the suite carries it as a **reverse spec**: a spec whose body
asserts the **end state** rather than absent behavior.

```lua
prova.test("every plugin is pinned to a released tag",
  { spec = "operator-standards incubates on `dev` until it cuts its first release" },
  function(t) ops.standards.released_pins(t) end)
```

prova's spec semantics supply the whole mechanic, in both directions:

| State | Body | prova reports | Effect |
|---|---|---|---|
| Pinned to `dev` | red | **open spec** — CI green, listed by `prova specs` | the reminder is executable |
| Pinned to a tag | green | **FAILURE**: *"spec honored — convert the flag or remove it"* | migration + cleanup land in one commit |

That inversion is what makes it durable. A TODO comment rots because nothing checks it; this reminder
is checked on every run, stays out of the way while it is still true, and becomes loud the instant it
stops being true. `git grep TODO` lies; `prova specs` cannot.

Across a fleet it is a **phase tracker**: `prova specs` in each repo enumerates who is still on the
incubation pin, and the surface empties itself as repos migrate. The last repo to graduate is the one
still listing it.

Generalizes past this plugin — any migration with a known end state can be tracked this way: a
deprecated API still in use, a version floor not yet raised, a flag not yet flipped.

## The plugin: `prova-operator-standards` (require name `operator-standards`)

Everything is parameterized by the operator's identity, so expectations are a pure function of one
answer key and no proof restates the contract:

```lua
local ops = require("operator-standards")

local id = ops.identity{ name = "platform-cluster-operator" }
-- id.project_name  == "platform-cluster-operator"
-- id.metric_prefix == "platform_cluster_operator"   → {prefix}_reconcile_runs_total

local sut = ops.sut{ ctx = ctx, id = id, cluster = cluster }
-- docker.build the production image → kind load → apply Deployment → wait ready → port_forward

ops.standards.management(t, sut, id)        -- O1: the port contract, honored as injected
ops.standards.health(t, sut, id)            -- O2, O3: liveness unconditional, readiness transitions
ops.standards.metrics(t, sut, id)           -- O4: format, families, bounded label cardinality
ops.standards.logging(t, sut, id, sibling)  -- O5: both directions
ops.standards.chart(t, id, sut)             -- O6: cross-artifact, chart ↔ SUT
ops.standards.traces(t, sut, id)            -- O7: fail-open now, delivery as a spec
ops.standards.hygiene(t, id)                -- O8: no cluster needed
```

- `ops.identity(spec)` — the naming oracle: the single source of truth for the metric prefix, chart
  name, and image tag derived from an operator's repo name.
- `ops.contract` — the wire contract as data (paths, statuses, content types, env var names), so the
  suite and any future generator read the same table.
- `ops.sut{}` — the containerized-operator fixture: build the production image, load it into the kind
  cluster, apply a minimal Deployment with the env contract, wait on readiness, port-forward the
  management port. One per variant; teardown rides the scope.
- `ops.standards.*` — the shared suites each operator's thin proof file invokes.

Consumption, in each operator repo:

```toml
[plugins]
operator-standards = { git = "https://github.com/p6m-run/prova-operator-standards", tag = "v1" }
kind = { git = "https://github.com/prova-rs/prova-kind", tag = "v1" }
```

**Substrate.** A real control plane, via `prova-kind` — taken over and implemented for this work (it
was an unreleased skeleton). A mocked API server was considered and rejected: a Kubernetes client does
discovery then opens long-lived watches with `resourceVersion` bookkeeping, and faking that faithfully
costs more than running the real thing while making the result weaker evidence. One cluster is shared
per file (~30s to create), and every operator's suite skips cleanly where kind, kubectl, or docker are
absent.

## Adding a standard

The bar is meant to ratchet. To add or tighten one:

1. State it here, in terms a black-box caller can observe.
2. Implement it in `init.lua` as an `ops.standards.*` suite, parameterized by `ops.identity` — never
   hardcode an operator's name, paths, or ports.
3. Put any new wire facts in `ops.contract`, so nothing restates them.
4. If it cannot pass yet everywhere, land it as a **spec** naming the reason. CI stays green and
   `prova specs` tracks the burndown.

A tightened assertion is a change in one repo that every operator's suite enforces on its next run.
That is the point: the fleet cannot drift back, and the cost of raising the bar does not scale with
the number of operators.
