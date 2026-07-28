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
