-- Self-test for prova-operator-standards. `require("operator-standards")` resolves to THIS plugin —
-- prova.toml declares it as a path plugin at "." — so the suite proves the plugin the way a consumer
-- uses it.
--
-- Everything here is HERMETIC: no docker, no cluster, no helm. That is deliberate, and it is where
-- the plugin's real risk lives. The `standards.*` suites are thin wrappers over http.get; the parts
-- that can be silently, subtly wrong are the naming oracle (a wrong metric prefix makes every O4
-- proof assert the wrong family name) and the chart probe parser (a regex matching the wrong block
-- makes O6 pass a broken chart). Those are proven against fixture text here.
--
-- The live path is proven by the consumer suites in each operator repo, which have a real image to
-- build. Proving it here would mean shipping an operator in this repo.

local ops = require("operator-standards")

--------------------------------------------------------------------------------------------------
-- The scaffold's API is gone; the standards surface is present
--------------------------------------------------------------------------------------------------

prova.test("exports the standards surface a consumer requires", function(t)
  t:expect(ops.greet, "the skeleton greet() is not part of the contract"):is_nil()
  t:expect(type(ops.identity)):equals("function")
  t:expect(type(ops.sut)):equals("function")
  t:expect(type(ops.contract)):equals("table")
  for _, name in ipairs{
    "management",
    "health",
    "readiness_drops_on_shutdown",
    "metrics",
    "logging",
    "traces",
    "chart",
    "hygiene",
  } do
    t:expect(type(ops.standards[name]), "standards." .. name):equals("function")
  end
end)

--------------------------------------------------------------------------------------------------
-- The naming oracle
--------------------------------------------------------------------------------------------------

prova.test("identity derives the metric prefix every adopting operator registers", function(t)
  local id = ops.identity{ name = "platform-cluster-operator" }
  t:expect(id.name):equals("platform-cluster-operator")
  t:expect(id.snake_name):equals("platform_cluster_operator")
  -- This is the value the operators pass to OperatorState::new, so the oracle must match reality.
  t:expect(id.metric_prefix):equals("platform_cluster_operator")
end)

prova.test_each("identity normalizes ${input}", {
  { input = "platform-cluster-operator", snake = "platform_cluster_operator" },
  { input = "platform_cluster_operator", snake = "platform_cluster_operator" },
  { input = "Platform Cluster Operator", snake = "platform_cluster_operator" },
  { input = "github-operator", snake = "github_operator" },
}, function(t, case)
  local id = ops.identity{ name = case.input }
  t:expect(id.snake_name):equals(case.snake)
  t:expect(id.name):equals((case.snake:gsub("_", "-")))
end)

prova.test("metric_prefix is overridable, because a registered prefix may differ", function(t)
  local id = ops.identity{ name = "installation-operator", metric_prefix = "installation" }
  t:expect(id.metric_prefix):equals("installation")
  t:expect(id:metric_families()):contains("installation_reconcile_runs_total")
end)

prova.test("metric_families substitutes the prefix into every contract family", function(t)
  local id = ops.identity{ name = "platform-edge-operator" }
  local fams = id:metric_families()
  t:expect(fams):has_length(#ops.contract.metrics.families)
  t:expect(fams):contains("platform_edge_operator_reconcile_runs_total")
  t:expect(fams):contains("platform_edge_operator_reconcile_failures_total")
  t:expect(fams):contains("platform_edge_operator_reconcile_duration_seconds")
  -- A missed substitution would make O4 assert on the literal "{prefix}_..." and fail confusingly
  -- rather than clearly.
  for _, f in ipairs(fams) do
    t:expect(f):never():contains("{prefix}")
  end
end)

prova.test("identity requires a name rather than inventing one", function(t)
  local ok, err = pcall(ops.identity, {})
  t:expect(ok):is_falsy()
  t:expect(tostring(err)):contains("name")
end)

--------------------------------------------------------------------------------------------------
-- The contract is the single source of truth
--------------------------------------------------------------------------------------------------

prova.test("the contract states the paths and ports the standards reference", function(t)
  local c = ops.contract
  t:expect(c.liveness.path):equals("/healthz")
  t:expect(c.readiness.path):equals("/readyz")
  t:expect(c.metrics.path):equals("/metrics")
  t:expect(c.management.default_port):equals(9090)
  t:expect(c.management.port_env):equals("OPERATOR_METRICS_PORT")
  t:expect(c.readiness.not_ready):equals(503)
end)

--------------------------------------------------------------------------------------------------
-- The chart probe parser (O6) — where a silent false pass would hide
--------------------------------------------------------------------------------------------------

-- The shape `helm template` actually emits for these operators, trimmed to what O6 reads.
local COMPLIANT_CHART = [[
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: operator
          image: repo/platform-cluster-operator:1.0
          ports:
            - name: https
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: metrics
            initialDelaySeconds: 5
          readinessProbe:
            httpGet:
              path: /readyz
              port: metrics
            initialDelaySeconds: 5
          resources:
            requests:
              cpu: 100m
]]

prova.test("parses named ports so a probe's `port: metrics` resolves to a number", function(t)
  local facts = ops.chart_probe_facts(COMPLIANT_CHART)
  t:expect(facts.ports.metrics):equals(9090)
  t:expect(facts.ports.https):equals(8080)
end)

prova.test("parses both probes without bleeding one into the other", function(t)
  local facts = ops.chart_probe_facts(COMPLIANT_CHART)
  -- The bug this guards: a greedy match letting livenessProbe's block swallow readinessProbe's would
  -- report "/healthz" for both, and O6 would pass a chart whose readiness path was wrong.
  t:expect(facts.livenessProbe.path):equals("/healthz")
  t:expect(facts.readinessProbe.path):equals("/readyz")
  t:expect(facts.livenessProbe.port):equals("metrics")
  t:expect(facts.readinessProbe.port):equals("metrics")
end)

prova.test("reports a missing probe as absent rather than guessing", function(t)
  local no_probes = COMPLIANT_CHART:gsub("livenessProbe:.*", "")
  local facts = ops.chart_probe_facts(no_probes)
  t:expect(facts.livenessProbe):is_nil()
  t:expect(facts.readinessProbe):is_nil()
end)

prova.test("catches the production defect: a probe port the container never declares", function(t)
  -- The real drift found on 2026-07-28 — probes pointing at `metrics` with no such port declared.
  local broken = COMPLIANT_CHART:gsub(
    "            %- name: metrics\n              containerPort: 9090\n              protocol: TCP\n",
    ""
  )
  local facts = ops.chart_probe_facts(broken)
  t:expect(facts.ports.metrics, "the `metrics` port is genuinely absent from the fixture"):is_nil()
  -- O6 resolves a probe's port through facts.ports; an unresolvable ref is what it must report.
  local ref = facts.livenessProbe.port
  t:expect(tonumber(ref) or facts.ports[ref]):is_nil()
end)

prova.test("reads a numeric probe port as well as a named one", function(t)
  local numeric = COMPLIANT_CHART:gsub("port: metrics", "port: 9090")
  local facts = ops.chart_probe_facts(numeric)
  t:expect(tonumber(facts.livenessProbe.port)):equals(9090)
end)

prova.test("reads the probe scheme when the chart states one", function(t)
  local https = COMPLIANT_CHART:gsub(
    "              path: /healthz\n",
    "              path: /healthz\n              scheme: HTTPS\n"
  )
  local facts = ops.chart_probe_facts(https)
  -- O6 must be able to SEE a TLS probe in order to reject it: the management port is plaintext.
  t:expect(facts.livenessProbe.scheme):equals("HTTPS")
  t:expect(facts.livenessProbe.scheme):never():equals(ops.contract.chart.probe_scheme)
end)

prova.test("handles containerPort listed before its name", function(t)
  local flipped = [[
          ports:
            - containerPort: 9090
              name: metrics
          livenessProbe:
            httpGet:
              path: /healthz
              port: metrics
          resources: {}
]]
  t:expect(ops.chart_probe_facts(flipped).ports.metrics):equals(9090)
end)

--------------------------------------------------------------------------------------------------
-- sut() argument contract — fail loudly, not deep inside docker
--------------------------------------------------------------------------------------------------

prova.test_each("sut requires ${missing}", {
  { missing = "ctx", args = { id = {}, cluster = {} } },
  { missing = "id", args = { ctx = {}, cluster = {} } },
  { missing = "cluster", args = { ctx = {}, id = {} } },
}, function(t, case)
  local ok, err = pcall(ops.sut, case.args)
  t:expect(ok):is_falsy()
  t:expect(tostring(err)):contains(case.missing)
end)

--------------------------------------------------------------------------------------------------
-- Artifactory credential plumbing — the gate, not the credential
--------------------------------------------------------------------------------------------------

prova.test("artifactory_secrets presents the identity token as a Bearer credential", function(t)
  local secrets = ops.artifactory_secrets{ "p6m-run", "p6m-dev" }
  for _, id in ipairs{ "p6m-run", "p6m-dev" } do
    t:expect(secrets[id], id .. " gets a secret"):never():is_nil()
    -- Artifactory rejects a bare identity token on these endpoints; the Bearer prefix is the contract.
    t:expect(secrets[id].value, id .. " is a Bearer credential"):matches("^Bearer ")
    -- It must be a literal value, not an env reference: the var a developer maintains is
    -- ARTIFACTORY_IDENTITY_TOKEN, not a per-registry CARGO_REGISTRIES_<NAME>_TOKEN.
    t:expect(secrets[id].env, id .. " is not an env passthrough"):is_nil()
  end
end)

prova.test("ACTIONS_RUNTIME_TOKEN is satisfied by any value, since sccache's GHA cache is off", function(t)
  local secrets = ops.artifactory_secrets{ "ACTIONS_RUNTIME_TOKEN" }
  t:expect(secrets.ACTIONS_RUNTIME_TOKEN.value):never():is_nil()
  -- Not a Bearer credential — it is not an Artifactory token at all.
  t:expect(secrets.ACTIONS_RUNTIME_TOKEN.value):never():matches("^Bearer ")
end)

prova.test("has_artifactory answers the capability predicate as a boolean", function(t)
  -- Deliberately does NOT assert which way: this machine's state is not the contract. What matters is
  -- that the gate returns a usable boolean — prova parses a returned STRING as a version, so a reason
  -- string here would be a load error, not a skip.
  t:expect(type(ops.has_artifactory())):equals("boolean")
end)

-- The gate VALIDATES rather than detects. A presence-only check is what let the dead token go
-- unnoticed: `p6m workstation check core` reports it green, and the first version of this gate did
-- too — the suite spent 30s standing a cluster up before dying on an opaque 401. All four branches are
-- proven with an injected probe, so no network is touched.
prova.test_each("artifactory_status classifies ${case}", {
  {
    case = "a missing credential",
    resolve = function() return nil end,
    probe = function() error("must not be probed without a token") end,
    status = "missing",
    reason = "ARTIFACTORY_IDENTITY_TOKEN",
  },
  {
    case = "an empty credential",
    resolve = function() return "" end,
    probe = function() error("must not be probed with an empty token") end,
    status = "missing",
    reason = "ARTIFACTORY_IDENTITY_TOKEN",
  },
  {
    case = "an accepted credential",
    resolve = function() return "good" end,
    probe = function() return { status = 200 } end,
    status = "ok",
    reason = "accepted",
  },
  {
    case = "a rejected credential",
    resolve = function() return "stale" end,
    probe = function() return { status = 401 } end,
    status = "rejected",
    -- The reason must be actionable: a 401 here means regenerate, and it should say where.
    reason = "p6m.jfrog.io",
  },
  {
    case = "an unreachable registry",
    resolve = function() return "good" end,
    probe = function() error("connection refused") end,
    status = "unreachable",
    reason = "could not reach",
  },
}, function(t, c)
  local status, reason = ops.artifactory_status(c.probe, c.resolve)
  t:expect(status):equals(c.status)
  t:expect(reason):contains(c.reason)
end)

prova.test("a rejected credential is distinguished from a missing one", function(t)
  -- The whole point of validating: these two must not collapse into one answer, because the fix
  -- differs (set a variable vs regenerate a token).
  local missing = ops.artifactory_status(function() return { status = 200 } end, function() return nil end)
  local rejected = ops.artifactory_status(function() return { status = 401 } end, function() return "stale" end)
  t:expect(missing):never():equals(rejected)
  t:expect(missing):equals("missing")
  t:expect(rejected):equals("rejected")
end)

prova.test("a token is never echoed into the reason", function(t)
  -- The reason is printed to stdout and lands in CI logs.
  local _, reason = ops.artifactory_status(function() return { status = 401 } end, function() return "super-secret-token" end)
  t:expect(reason):never():contains("super-secret-token")
end)

-- Which statuses GATE, and which merely warn. This is the one behavioural decision in the credential
-- layer, and it is easy to get backwards: "unreachable" must not block, because the probe runs in the
-- prova process while the build runs in the Docker daemon — different network paths — and because a
-- flaky probe that blocks turns a working environment into random skips, which read as green.
prova.test_each("has_artifactory ${verdict} on ${case}", {
  { case = "ok", verdict = "proceeds", probe = function() return { status = 200 } end,
    token = "good", expect_pass = true },
  { case = "an unreachable registry", verdict = "proceeds", probe = function() error("no route") end,
    token = "good", expect_pass = true },
  { case = "a rejected credential", verdict = "blocks", probe = function() return { status = 401 } end,
    token = "stale", expect_pass = false },
  { case = "a missing credential", verdict = "blocks", probe = function() return { status = 200 } end,
    token = nil, expect_pass = false },
}, function(t, c)
  -- has_artifactory() reads the real environment, so the decision table is asserted through the
  -- classifier it wraps plus the documented mapping. Keeps the proof hermetic and total.
  local status = ops.artifactory_status(c.probe, function() return c.token end)
  local gates = (status == "missing" or status == "rejected")
  t:expect(not gates, c.case .. " → " .. c.verdict):equals(c.expect_pass)
end)
