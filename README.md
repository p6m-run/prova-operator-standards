# prova-operator-standards

The p6m **operator** observability standards, as executable proofs — one parameterized suite every
p6m Rust Kubernetes operator must pass.

Sibling to [`prova-p6m-standards`](https://github.com/p6m-archetypes/prova-p6m-standards), which
does the same job for services (S1–S10). The bar here is **O1–O8**, and it lives in
[`docs/standards.md`](docs/standards.md) — read that first; this README is just how to use it.

The goal: operators that are **indistinguishable from each other at the observability boundary**, so
dashboards, alerts, and runbooks are written once and apply to all of them.

## The bar, in one screen

| | Standard |
|---|---|
| **O1** | One management port, **plaintext**, honored as injected (`OPERATOR_METRICS_PORT`, default 9090) |
| **O2** | `GET /healthz` → 200, unconditionally — liveness must not depend on the API server |
| **O3** | `GET /readyz` → 200/503, reflecting real state, **including 503 during graceful shutdown** |
| **O4** | `GET /metrics` → Prometheus/OpenMetrics text with the reconcile families, `error` label **bounded** |
| **O5** | Structured logging, proven **from both directions** |
| **O6** | The **chart's probes name paths and ports the binary actually answers** |
| **O7** | Traces wired **fail-open** — an unreachable collector never stops the operator |
| **O8** | Suite and CI hygiene: `proofs` key, released-tag pins, pinned `run-action` version |

### It asserts the wire contract, not the dependency

`p6m-kube-metrics` already implements all of O1–O5, and adopting it is the obvious way to pass — but
nothing here asserts that an operator depends on it. Inherited from `prova-p6m-standards`:
**idiomatic inside, identical at the boundary.** An operator that satisfies the contract another way
is compliant.

## Use it

```toml
[plugins]
operator-standards = { git = "https://github.com/p6m-run/prova-operator-standards", tag = "v1" }
kind = { git = "https://github.com/prova-rs/prova-kind", tag = "v1" }
```

Each operator's proof file is deliberately thin — its name, and the secrets its own production
Dockerfile mounts:

```lua
local ops = require("operator-standards")
local kind = require("kind")

local id = ops.identity{ name = "platform-cluster-operator" }

local cluster = prova.fixture("cluster", Scope.File, function(ctx) return kind.cluster(ctx) end)

local sut = prova.fixture("sut", Scope.File, function(ctx)
  return ops.sut{
    ctx = ctx, id = id, cluster = ctx:use(cluster),
    secrets = { ["p6m-run"] = { env = "CARGO_REGISTRIES_P6M_RUN_TOKEN" } },
    env = { [ops.contract.traces.endpoint_env] = "http://127.0.0.1:4317" }, -- O7: a black hole
  }
end)

prova.group("operator standards", { requires = { "docker", "kind", "kubectl" } }, function(g)
  g:test("O1", function(t) ops.standards.management(t, t:use(sut), id) end)
  g:test("O2/O3", function(t) ops.standards.health(t, t:use(sut), id) end)
  g:test("O4", function(t) ops.standards.metrics(t, t:use(sut), id) end)
  g:test("O7", function(t) ops.standards.traces(t, t:use(sut), id) end)
end)
```

## API

| | |
|---|---|
| `ops.contract` | the wire contract as data — paths, statuses, content types, env names |
| `ops.identity{ name }` | the naming oracle: metric prefix, image tag, snake/kebab forms |
| `ops.sut{ ctx, id, cluster, … }` | builds the **production** image, loads it into the cluster, runs it, port-forwards the management port |
| `ops.standards.{management,health,metrics,logging,traces,chart,hygiene}` | the shared suites |
| `ops.standards.readiness_drops_on_shutdown` | O3's shutdown half — **destroys the SUT**, run last |
| `ops.chart_probe_facts(yaml)` | the O6 probe parser, exposed so it can be proven hermetically |

Two arguments carry more weight than they look like they do:

- **`ops.standards.logging`'s 4th argument** is a *sibling* SUT booted with the human log format.
  Without it the proof is one-sided and an always-JSON operator that merely *accepts* the format
  variable passes. `prova-p6m-standards` S4 had to add this ratchet after shipping the one-sided
  version; it is built in here from the start.
- **`ops.standards.chart`'s `sut`** is what makes O6 cross-artifact. A chart that is internally
  consistent but probes a path the binary 404s is still broken — and that was the live defect this
  standard was written for.

## Substrate: a real cluster

The SUT runs in a real control plane via [`prova-kind`](https://github.com/prova-rs/prova-kind). A
mocked API server was considered and rejected: a Kubernetes client does discovery then opens
long-lived watches with `resourceVersion` bookkeeping, and faking that faithfully costs more than
running the real thing while making the result weaker evidence.

Requires **docker, kind, kubectl** — plus `helm` for O6 only. No Rust toolchain on the host: what is
proven is the image CI publishes, under the env contract the chart injects.

## Develop

```bash
prova                        # the self-test — fully hermetic, no docker or cluster needed
prova plugin lint init.lua
```

The self-test is hermetic on purpose. The `standards.*` suites are thin wrappers over `http.get`;
the parts that can be silently, subtly wrong are the **naming oracle** (a wrong metric prefix makes
every O4 proof assert the wrong family) and the **chart probe parser** (a regex matching the wrong
block makes O6 pass a broken chart). Those are proven against fixture text here. The live path is
proven by the consumer suites, which have a real image to build.

MIT licensed.
