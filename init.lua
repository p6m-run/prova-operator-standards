-- prova-operator-standards — p6m operator standards as executable proofs.
--
-- One parameterized suite every p6m Rust Kubernetes operator must pass, so operators are
-- indistinguishable from each other at the observability boundary and dashboards, alerts, and
-- runbooks are written once. The bar itself is docs/standards.md (O1–O8); this file is the machine
-- that holds it.
--
--   local ops = require("operator-standards")
--
--   local id  = ops.identity{ name = "platform-cluster-operator" }
--   local sut = ops.sut{ ctx = ctx, id = id, cluster = cluster }
--
--   ops.standards.management(t, sut, id)   -- O1
--   ops.standards.health(t, sut, id)       -- O2, O3
--   ops.standards.metrics(t, sut, id)      -- O4
--   ops.standards.logging(t, sut, id, sib) -- O5
--   ops.standards.chart(t, id, sut)        -- O6
--   ops.standards.traces(t, sut, id)       -- O7
--   ops.standards.hygiene(t, id)           -- O8
--
-- ASSERTS THE WIRE CONTRACT, NOT THE DEPENDENCY (DECIDED 2026-07-28). `p6m-kube-metrics` implements
-- all of O1–O5 and adopting it is the obvious way to pass, but nothing here asserts that an operator
-- depends on it. Inherited from prova-p6m-standards: idiomatic inside, identical at the boundary.

local ops = {}

------------------------------------------------------------------------------------------
-- The contract, as data
------------------------------------------------------------------------------------------

--- The wire contract every operator must honor, in one table so the suite — and anything that
--- generates operator scaffolding later — read the same source rather than restating it.
ops.contract = {
  -- O1 — the management port.
  management = {
    host_env = "OPERATOR_METRICS_HOST",
    port_env = "OPERATOR_METRICS_PORT",
    default_host = "0.0.0.0",
    default_port = 9090,
  },
  -- O2 / O3 — probes. Liveness is unconditional; readiness reflects real state.
  liveness = { path = "/healthz", status = 200 },
  readiness = { path = "/readyz", ready = 200, not_ready = 503 },
  -- O4 — metrics.
  metrics = {
    path = "/metrics",
    status = 200,
    -- Either is acceptable: OpenMetrics is what prometheus-client emits, text/plain is what most
    -- other exporters emit. Both are scrapeable.
    content_types = { "application/openmetrics-text", "text/plain" },
    families = {
      "{prefix}_reconcile_runs_total",
      "{prefix}_reconcile_failures_total",
      "{prefix}_reconcile_duration_seconds",
    },
    failure_labels = { "instance", "error" },
  },
  -- O5 — structured logging.
  logging = {
    format_env = "OPERATOR_TRACING_FORMAT",
    structured = "json",
    human = "standard",
    required_keys = { "timestamp", "level", "message" },
  },
  -- O7 — traces, fail-open.
  traces = { endpoint_env = "OTEL_EXPORTER_OTLP_ENDPOINT" },
  -- O6 — the chart.
  chart = { dir = "helm", probe_scheme = "HTTP" },
  -- The private cargo registry the production image build must reach. Used only to VALIDATE the
  -- credential before a build starts; the build itself resolves registries from each repo's
  -- `.cargo/config*`.
  registry = {
    probe_url = "https://p6m.jfrog.io/artifactory/api/cargo/p6m-run-cargo-local/index/config.json",
  },
}

------------------------------------------------------------------------------------------
-- ops.identity — the naming oracle
------------------------------------------------------------------------------------------

local function kebab(s)
  return (tostring(s)
    :gsub("[_%s]+", "-")
    :gsub("%-+", "-")
    :gsub("^%-", "")
    :gsub("%-$", "")
    :lower())
end

local function snake(s)
  return (kebab(s):gsub("%-", "_"))
end

--- Derive every name the standards reference from an operator's repo name. The single source of
--- truth: nothing else in the suite may compute a metric prefix or an image tag.
---
--- The metric prefix is the snake_case name, which is what every adopting operator already passes to
--- `OperatorState::new` — so the expectation matches reality rather than inventing a rule.
--- @param spec { name: string, metric_prefix: string? }
--- @return table
function ops.identity(spec)
  spec = spec or {}
  local name = spec.name or error("ops.identity: `name` (the operator's repo name) is required")

  local id = {
    name = kebab(name),
    project_name = kebab(name),
    snake_name = snake(name),
    -- Overridable: an operator whose registered prefix legitimately differs says so once, here,
    -- rather than the suite guessing.
    metric_prefix = spec.metric_prefix or snake(name),
    image = kebab(name) .. ":prova-standards",
  }

  --- The expected metric family names for this operator.
  --- @return string[]
  function id:metric_families()
    local out = {}
    for _, f in ipairs(ops.contract.metrics.families) do
      out[#out + 1] = (f:gsub("{prefix}", self.metric_prefix))
    end
    return out
  end

  return id
end

------------------------------------------------------------------------------------------
-- Artifactory credentials for the image build
------------------------------------------------------------------------------------------

-- The private cargo registry token, as Artifactory wants it presented.
--
-- Sourced from ARTIFACTORY_IDENTITY_TOKEN — the single variable the p6m workstation docs already
-- have developers set — rather than a per-registry CARGO_REGISTRIES_<NAME>_TOKEN, so adding a
-- registry costs nothing and a developer maintains one secret instead of three.
--
-- Falls back to ~/.cargo/credentials.toml so a machine set up with `cargo login` also works. Note
-- that host-side `cargo login` is NOT a requirement here: the build happens in a container and the
-- token is handed to it as a BuildKit secret, so the host needs no cargo registry configuration at
-- all. (Which matters, because these operators define their registries per-repo in `.cargo/config*`
-- — so `cargo login --registry p6m-run` only resolves from inside one of them.)
local function identity_token()
  local tok = os.getenv("ARTIFACTORY_IDENTITY_TOKEN")
  if tok and tok ~= "" then
    return tok
  end

  local home = os.getenv("HOME")
  local path = home and (home .. "/.cargo/credentials.toml")
  if path and fs.exists(path) then
    -- Only the token line is needed; a full TOML parse would be more machinery than this warrants.
    local found = fs.read(path):match('token%s*=%s*"([^"]+)"')
    if found then
      return (found:gsub("^Bearer%s+", ""))
    end
  end
  return nil
end

--- Classify the Artifactory credential: "ok" | "missing" | "rejected" | "unreachable", plus a
--- human reason.
---
--- VALIDATES, rather than merely detecting. A presence-only check is what let this go unnoticed for
--- weeks: `p6m workstation check core` reports "🟢 Artifactory Tokens Found" for a token Artifactory
--- rejects, and the first version of this gate had the identical flaw — the live suite ran, spent 30s
--- creating a cluster, and died on an opaque 401 deep inside a cargo fetch. A token that exists and a
--- token that works are different facts, and only the second one gates anything usefully.
---
--- `probe` and `resolve` are injectable so every branch is provable without a network (the plugin's
--- own suite is hermetic); production calls pass neither.
---
--- `resolve` is a token *resolver*, not a token: a bare `token` parameter cannot express "there is no
--- credential", because nil is exactly what means "fall back to the real environment" — so the
--- missing-credential branch would be untestable on any machine that has one. A resolver returning
--- nil says it unambiguously.
--- @param probe fun(url: string, opts: table): table|nil
--- @param resolve fun(): string|nil
--- @return string status, string reason
function ops.artifactory_status(probe, resolve)
  local token = (resolve or identity_token)()
  if not token or token == "" then
    return "missing",
      "no ARTIFACTORY_IDENTITY_TOKEN, and no token in ~/.cargo/credentials.toml"
  end

  local url = ops.contract.registry.probe_url
  probe = probe or function(u, opts)
    return http.get(u, opts)
  end

  local ok, res = pcall(probe, url, {
    headers = { Authorization = "Bearer " .. token },
    timeout = "10s",
  })
  if not ok or not res then
    return "unreachable", "could not reach " .. url .. " (offline?)"
  end
  if res.status == 200 then
    return "ok", "credential accepted by " .. url
  end
  return "rejected",
    string.format(
      "%s rejected the credential (HTTP %d) — regenerate at https://p6m.jfrog.io "
        .. "(Edit Profile → Generate an Identity Token)",
      url,
      res.status
    )
end

--- The predicate behind the `artifactory` capability, so a suite SKIPS instead of failing deep inside
--- a docker build with a 401.
---
--- Only "missing" and "rejected" gate. "unreachable" deliberately does NOT, for two reasons:
---
---   * The probe runs in the prova process; the build runs in the Docker daemon. Those have different
---     network paths, so prova failing to reach the registry is not evidence the build will. (Observed
---     directly: `docker pull` and `kind` image pulls succeed on a machine where prova's own
---     `http.get` to an external host fails intermittently — measured 2 of 5 attempts.)
---   * Blocking on a flaky probe converts a working environment into random skips, and a skipped
---     suite reads as a green one. Better to proceed and let the build state the real answer than to
---     silently claim coverage we did not run.
---
--- Must return a BOOLEAN: prova parses a returned string as a *version*, not a reason, so the reason
--- is printed. The skip line itself only names the capability.
--- @return boolean
function ops.has_artifactory()
  local status, reason = ops.artifactory_status()
  if status == "ok" then
    return true
  end
  if status == "unreachable" then
    print(
      "prova: capability `artifactory` could not be validated — "
        .. reason
        .. "; proceeding, since the image build resolves the registry through the Docker daemon, "
        .. "not this process"
    )
    return true
  end
  print("prova: capability `artifactory` unmet (" .. status .. ") — " .. reason)
  return false
end

--- Build the `secrets` table for `ops.sut` from the registry ids an operator's production Dockerfile
--- mounts. Every id gets the same identity token, presented as a Bearer credential.
---
---   secrets = ops.artifactory_secrets{ "p6m-run", "p6m-dev" }
---
--- `ACTIONS_RUNTIME_TOKEN` is handled too: 7 of the 8 prd Dockerfiles mount it for sccache's GitHub
--- cache backend, which is off outside CI, so any non-empty value satisfies the mount.
--- @param ids string[]
--- @return table
function ops.artifactory_secrets(ids)
  local token = identity_token()
  local secrets = {}
  for _, id in ipairs(ids) do
    if id == "ACTIONS_RUNTIME_TOKEN" then
      secrets[id] = { value = os.getenv("ACTIONS_RUNTIME_TOKEN") or "unused" }
    else
      secrets[id] = { value = "Bearer " .. (token or "") }
    end
  end
  return secrets
end

------------------------------------------------------------------------------------------
-- ops.sut — the operator under proof, running in a real cluster
------------------------------------------------------------------------------------------

-- The Deployment the suite runs the operator under.
--
-- Deliberately minimal, and deliberately permissive: this is a disposable kind cluster, and
-- modelling each operator's real RBAC would make the suite a second implementation of eight charts.
-- cluster-admin buys the operator the ability to establish its watches, which is a precondition for
-- readiness — it is not a claim about what it should hold in production.
--
-- It declares NO probes on purpose. Availability must not depend on the operator answering
-- /healthz, or an operator that serves nothing would never become Available and every O2/O3
-- assertion would report as "did not start" instead of "does not serve the contract".
local function manifest(id, image, env, port)
  local env_lines = {}
  for k, v in pairs(env) do
    env_lines[#env_lines + 1] =
      string.format('            - name: %s\n              value: "%s"', k, tostring(v))
  end
  table.sort(env_lines)

  return string.format(
    [[
apiVersion: v1
kind: ServiceAccount
metadata:
  name: %s
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: %s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: %s
    namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  labels: { app: %s }
spec:
  replicas: 1
  selector:
    matchLabels: { app: %s }
  template:
    metadata:
      labels: { app: %s }
    spec:
      serviceAccountName: %s
      terminationGracePeriodSeconds: 30
      containers:
        - name: operator
          image: %s
          imagePullPolicy: Never
          ports:
            - name: metrics
              containerPort: %d
          env:
%s
]],
    id.name,
    id.name,
    id.name,
    id.name,
    id.name,
    id.name,
    id.name,
    id.name,
    image,
    port,
    table.concat(env_lines, "\n")
  )
end

--- Build the operator's production image, load it into the cluster, run it, and return a handle
--- whose `url` is its management port.
---
--- The image is the PRODUCTION Dockerfile's, not a test-only build: what is proven is the artifact
--- CI publishes, under the env contract the chart injects.
---
--- @param spec { ctx: any, id: table, cluster: table, dir: string?, env: table?, format: string?,
---               secrets: table?, buildargs: table?, dockerfile: string?, timeout: string? }
--- @return table
function ops.sut(spec)
  local ctx = spec.ctx or error("ops.sut: `ctx` is required")
  local id = spec.id or error("ops.sut: `id` (from ops.identity) is required")
  local cluster = spec.cluster or error("ops.sut: `cluster` (from kind.cluster) is required")
  local dir = spec.dir or prova.root

  local port = ops.contract.management.default_port
  local env = {
    [ops.contract.logging.format_env] = spec.format or ops.contract.logging.structured,
    [ops.contract.management.port_env] = port,
    RUST_LOG = "info",
  }
  for k, v in pairs(spec.env or {}) do
    env[k] = v
  end

  -- A distinct tag per variant, so a sibling boot (O5's human-format SUT) does not race the primary
  -- on one shared tag.
  local tag = id.image .. (spec.tag_suffix or "")

  local image = docker.build{
    context = dir,
    dockerfile = spec.dockerfile or ".platform/docker/prd/Dockerfile",
    tag = tag,
    -- sccache's GHA backend cannot initialize outside Actions and fails the build; the production
    -- Dockerfile exposes this as an ARG precisely so a proof can build the same image off-CI.
    buildargs = spec.buildargs or { SCCACHE_GHA_ENABLED = "false" },
    secrets = spec.secrets,
  }

  cluster:load_image(image)

  local sut = {
    id = id,
    cluster = cluster,
    image = image,
    port = port,
    env = env,
    name = id.name .. (spec.tag_suffix or ""),
  }
  sut.target = "deploy/" .. sut.name

  local applied_id = { name = sut.name }
  cluster:apply(manifest(applied_id, image, env, port))

  --- The operator's stdout — the subject of O5.
  --- @return string
  function sut:logs()
    return self.cluster:logs(self.target, { tail = 500 })
  end

  --- Whether the Deployment became Available. Never raises: a suite must report "it did not start"
  --- as a failed assertion, not as an error inside a fixture.
  --- @param timeout string?
  --- @return boolean
  function sut:became_available(timeout)
    local res = self.cluster:try_kubectl(
      { "wait", "--for=condition=Available", self.target, "--timeout=" .. (timeout or "180s") },
      { timeout = timeout or "180s" }
    )
    return res:ok()
  end

  sut.available = sut:became_available(spec.timeout or "240s")

  if sut.available then
    sut.url = cluster:port_forward(sut.target, port, { probe = ops.contract.liveness.path })
  end

  return sut
end

------------------------------------------------------------------------------------------
-- ops.standards — the shared suites
------------------------------------------------------------------------------------------

ops.standards = {}

-- Every live suite starts here: if the operator never came up, say exactly that once with its logs,
-- rather than emitting a dozen confusing connection failures.
local function require_running(t, sut)
  if not sut.available then
    t:expect(false, "operator Deployment became Available — logs:\n" .. sut:logs()):is_true()
    return false
  end
  return true
end

--- O1 — one management port, plaintext, honored as injected.
function ops.standards.management(t, sut, _id)
  if not require_running(t, sut) then
    return
  end

  -- The assertion that catches config parsed and then discarded: the port the suite injected is the
  -- port the operator actually listens on. `url` was forwarded to exactly that container port, so an
  -- answer here IS that proof.
  local res = http.get(sut.url .. ops.contract.liveness.path)
  t:expect(res.status, ops.contract.management.port_env .. " honored, plaintext HTTP")
    :equals(ops.contract.liveness.status)
end

--- O2 / O3 — liveness unconditional, readiness reflecting real state.
function ops.standards.health(t, sut, _id)
  if not require_running(t, sut) then
    return
  end
  local c = ops.contract

  t:expect(
    http.get(sut.url .. c.liveness.path).status,
    "GET " .. c.liveness.path .. " — liveness, unconditional"
  ):equals(c.liveness.status)

  local ready = http.get(sut.url .. c.readiness.path)
  t:expect(ready.status, "GET " .. c.readiness.path .. " — readiness answers the contract")
    :is_one_of{ c.readiness.ready, c.readiness.not_ready }

  -- A running operator that has established its watches must actually report ready, or the endpoint
  -- exists and means nothing.
  t:expect(ready.status, "readiness is 200 once the operator is up"):equals(c.readiness.ready)
end

--- O3's shutdown half, split out because it destroys the SUT: readiness must answer 503 BEFORE the
--- process exits, so the pod leaves the Service's endpoints instead of being torn out from under an
--- in-flight reconcile. Run last, or against a SUT of its own.
function ops.standards.readiness_drops_on_shutdown(t, sut, _id)
  if not require_running(t, sut) then
    return
  end
  local c = ops.contract

  t:expect(http.get(sut.url .. c.readiness.path).status, "ready before shutdown")
    :equals(c.readiness.ready)

  -- SIGTERM pid 1 in place rather than deleting the pod, so the grace period is observable.
  sut.cluster:try_kubectl{ "exec", sut.target, "--", "sh", "-c", "kill -TERM 1" }

  -- Poll for the transition rather than sleeping a guessed interval. A process that exits without
  -- ever answering 503 shows up as the connection dying, and is reported as "never observed 503".
  local saw_503 = false
  for _ = 1, 60 do
    local ok, res = pcall(http.get, sut.url .. c.readiness.path, { timeout = "2s" })
    if not ok or not res then
      break -- gone; it never went unready
    end
    if res.status == c.readiness.not_ready then
      saw_503 = true
      break
    end
    prova.sleep(250)
  end

  t:expect(saw_503, "readiness answered 503 during graceful shutdown, before exit"):is_true()
end

--- O4 — metrics: format, the reconcile families, and bounded label cardinality.
function ops.standards.metrics(t, sut, id)
  if not require_running(t, sut) then
    return
  end
  local c = ops.contract.metrics

  local res = http.get(sut.url .. c.path)
  t:expect(res.status, "GET " .. c.path):equals(c.status)

  local ctype = ""
  if res.headers then
    ctype = tostring(res.headers["content-type"] or res.headers["Content-Type"] or "")
  end
  local ok_ctype = false
  for _, want in ipairs(c.content_types) do
    if ctype:find(want, 1, true) then
      ok_ctype = true
    end
  end
  t:expect(ok_ctype, "content-type is a scrapeable exposition format, got: " .. ctype):is_true()

  local body = res.body or ""
  -- A stub string is the failure this catches: real exposition carries TYPE metadata.
  t:expect(body, "body is Prometheus exposition, not a stub"):contains("# TYPE")

  for _, family in ipairs(id:metric_families()) do
    t:expect(body, "exposes " .. family):contains(family)
  end

  -- The one metrics property whose violation degrades the monitoring system rather than the signal:
  -- an unbounded `error` label value is a cardinality bomb. A formatted error message is long and
  -- contains spaces; a variant name is neither.
  for line in body:gmatch("[^\r\n]+") do
    if not line:match("^#") and line:find("_reconcile_failures_total", 1, true) then
      local err = line:match('error="([^"]*)"')
      if err and #err > 0 then
        t:expect(#err, "error label is a bounded classification, not a message: " .. err):lte(64)
        t:expect(err, "error label carries no message punctuation: " .. err):never():contains(" ")
      end
    end
  end
end

-- Classify a log stream into (total non-blank lines, lines that parse as JSON objects).
local function classify_lines(out)
  local total, as_json = 0, 0
  for line in tostring(out):gmatch("[^\r\n]+") do
    if line:match("%S") then
      total = total + 1
      local ok, rec = pcall(json.decode, line)
      if ok and type(rec) == "table" then
        as_json = as_json + 1
      end
    end
  end
  return total, as_json
end

--- O5 — structured logging, proven from BOTH directions.
---
--- `sibling` is a second SUT of the same image booted with the human format. Without it the proof is
--- one-sided, and an always-JSON operator that merely accepts the variable passes — which is exactly
--- the `setup_tracing(_settings)` defect. prova-p6m-standards S4 had to add this ratchet after
--- shipping the one-sided version; it is built in here from the start.
function ops.standards.logging(t, sut, _id, sibling)
  if not require_running(t, sut) then
    return
  end
  local c = ops.contract.logging

  local out = sut:logs()
  local total, as_json = classify_lines(out)

  t:expect(total, "the operator logged something to classify"):gt(0)
  t:expect(as_json, "with " .. c.format_env .. "=" .. c.structured .. ", every line is JSON")
    :equals(total)

  -- One record's shape is enough; the shape is uniform.
  for line in out:gmatch("[^\r\n]+") do
    local ok, rec = pcall(json.decode, line)
    if ok and type(rec) == "table" then
      for _, key in ipairs(c.required_keys) do
        -- However the ecosystem spells them: `timestamp`/`ts`, `level`/`lvl`, `message`/`msg`.
        local present = rec[key] ~= nil or rec[key:sub(1, 3)] ~= nil or rec[key:upper()] ~= nil
        t:expect(present, "log record carries `" .. key .. "`"):is_true()
      end
      break
    end
  end

  if sibling and sibling.available then
    local sib_total, sib_json = classify_lines(sibling:logs())
    t:expect(
      sib_total - sib_json,
      "with " .. c.format_env .. "=" .. c.human .. ", at least one line is NOT JSON — "
        .. "an always-JSON operator that merely accepts the flag must fail here"
    ):gt(0)
  end
end

--- O7 — traces, fail-open. `sut` must have been booted with the OTLP endpoint pointed at a black
--- hole; the proof is that it came up and still serves O2–O4 anyway.
function ops.standards.traces(t, sut, _id)
  if not require_running(t, sut) then
    return
  end
  local c = ops.contract

  t:expect(
    sut.env[c.traces.endpoint_env],
    "this SUT was booted with " .. c.traces.endpoint_env .. " set, else this proves nothing"
  ):never():is_nil()

  t:expect(
    http.get(sut.url .. c.liveness.path).status,
    "liveness answers with an unreachable OTLP collector"
  ):equals(200)
  t:expect(
    http.get(sut.url .. c.readiness.path).status,
    "readiness answers with an unreachable OTLP collector"
  ):equals(200)
  t:expect(
    http.get(sut.url .. c.metrics.path).status,
    "metrics answer with an unreachable OTLP collector"
  ):equals(200)
end

------------------------------------------------------------------------------------------
-- O6 — the chart agrees with the binary
------------------------------------------------------------------------------------------

--- Parse the probe facts out of a rendered Deployment.
---
--- Regex rather than a YAML parse because prova ships `yaml.encode` and no decode. Deliberately
--- narrow: it reads only the few fields O6 names, from YAML `helm template` produced.
--- @param yaml_text string
--- @return table
function ops.chart_probe_facts(yaml_text)
  local facts = { ports = {} }

  -- Named container ports, so a probe's `port: metrics` resolves to a number. Both key orders.
  for name, num in yaml_text:gmatch("name:%s*([%w-]+)%s*\n%s*containerPort:%s*(%d+)") do
    facts.ports[name] = tonumber(num)
  end
  for num, name in yaml_text:gmatch("containerPort:%s*(%d+)%s*\n%s*name:%s*([%w-]+)") do
    facts.ports[name] = tonumber(num)
  end

  for _, kind in ipairs{ "livenessProbe", "readinessProbe" } do
    -- Take the shortest run after the key that still contains the httpGet fields; a probe block ends
    -- at the next sibling key at the same or lower indentation.
    local block = yaml_text:match(kind .. ":(.-)\n%s*%a[%w]*Probe:")
      or yaml_text:match(kind .. ":(.-)\n%s*resources:")
      or yaml_text:match(kind .. ":(.-)\n%s*volumeMounts:")
      or yaml_text:match(kind .. ":(.-)\n%s*securityContext:")
      or yaml_text:match(kind .. ":(.*)$")
    if block then
      facts[kind] = {
        path = block:match("path:%s*([^%s\n]+)"),
        port = block:match("port:%s*([%w-]+)"),
        scheme = block:match("scheme:%s*(%a+)"),
      }
    end
  end

  return facts
end

--- O6 — every probe a chart declares must name a path and port the SUT actually answers. Asserted
--- ACROSS artifacts: a chart consistent with a binary that 404s is still broken, which is why this
--- takes the live `sut` too.
---
--- Needs `helm` to render. Gate the caller on `requires = { "helm" }` so the axis reports as skipped
--- rather than silently passing where helm is absent.
--- @param sut table|nil  when given, each declared probe path is also driven against the SUT
function ops.standards.chart(t, id, sut, chart_dir)
  local dir = chart_dir or (prova.root .. "/" .. ops.contract.chart.dir)
  t:expect(dir, "the operator ships a Helm chart"):is_dir()

  local rendered = shell.run({ "helm", "template", id.name, dir }, { timeout = "120s" })
  t:expect(rendered:ok(), "helm template renders the chart:\n" .. (rendered.stderr or "")):is_true()
  if not rendered:ok() then
    return
  end

  local facts = ops.chart_probe_facts(rendered.stdout or "")
  local c = ops.contract

  -- An unprobed liveness endpoint is indistinguishable from an absent one at 3am.
  t:expect(facts.livenessProbe, "the chart declares a livenessProbe"):never():is_nil()
  t:expect(facts.readinessProbe, "the chart declares a readinessProbe"):never():is_nil()
  if not (facts.livenessProbe and facts.readinessProbe) then
    return
  end

  t:expect(facts.livenessProbe.path, "livenessProbe path"):equals(c.liveness.path)
  t:expect(facts.readinessProbe.path, "readinessProbe path"):equals(c.readiness.path)

  -- O1: plaintext. A probe over HTTPS cannot reach the management port.
  for _, kind in ipairs{ "livenessProbe", "readinessProbe" } do
    if facts[kind].scheme then
      t:expect(facts[kind].scheme, kind .. " scheme is plaintext"):equals(c.chart.probe_scheme)
    end
  end

  -- The probe's port must resolve, through the container's named ports, to the management port.
  for _, kind in ipairs{ "livenessProbe", "readinessProbe" } do
    local ref = facts[kind].port
    local resolved = tonumber(ref) or facts.ports[ref]
    t:expect(
      resolved,
      kind .. " port `" .. tostring(ref) .. "` resolves to a declared containerPort"
    ):never():is_nil()
    if resolved then
      t:expect(resolved, kind .. " targets the management port"):equals(c.management.default_port)
    end
  end

  -- The cross-artifact half — the assertion that catches the defect found in production: a chart
  -- probing paths the binary does not serve.
  if sut and sut.available then
    for _, kind in ipairs{ "livenessProbe", "readinessProbe" } do
      local path = facts[kind].path
      t:expect(
        http.get(sut.url .. path).status,
        kind .. " path " .. path .. " actually answers on the running operator"
      ):is_one_of{ 200, 503 }
    end
  end
end

------------------------------------------------------------------------------------------
-- O8 — suite hygiene
------------------------------------------------------------------------------------------

--- O8 — properties of the repo, not of a running operator, so this needs no cluster and no docker.
function ops.standards.hygiene(t, _id)
  local root = prova.root
  local nook = root .. "/.prova/prova.toml"
  local manifest_path = fs.exists(nook) and nook or root .. "/prova.toml"

  t:expect(manifest_path, "the repo has a prova manifest"):is_file()
  local raw = fs.read(manifest_path)

  -- Assert against the manifest's DIRECTIVES, not its prose. The generated manifests are heavily
  -- commented, and a comment explaining why `@main` is wrong would otherwise fail the very check it
  -- documents — a false positive as bad as a false pass.
  local lines = {}
  for line in raw:gmatch("[^\n]*") do
    local code = line:gsub("#.*$", "")
    if code:match("%S") then
      lines[#lines + 1] = code
    end
  end
  local text = table.concat(lines, "\n")

  t:expect(text, "uses the [run] proofs key (prova >= 0.7)"):matches("proofs%s*=")
  t:expect(text, "declares no `paths` key, which prova does not read")
    :never()
    :matches("\n%s*paths%s*=")

  -- A plugin pinned to a moving ref makes the suite non-reproducible.
  t:expect(text, "no plugin is pinned to @main"):never():contains("@main")
  t:expect(text, 'no plugin is pinned to branch = "main"'):never():matches('branch%s*=%s*"main"')

  -- A local path plugin is fine while incubating but must never be committed: it resolves only on the
  -- machine that wrote it.
  t:expect(text, "no plugin is pinned to an absolute local path")
    :never()
    :matches('path%s*=%s*"/')

  -- A tracked .last-failed.json commits one developer's red run to everyone. Assert the FILE is
  -- absent rather than that .gitignore mentions it: current prova keeps this state in `.prova/var/`
  -- behind a self-ignore, so a gitignore string match passes on a stray comment and proves nothing.
  local stray = fs.glob(root, "**/.last-failed.json")
  t:expect(stray, "no .last-failed.json is tracked anywhere in the repo"):is_empty()

  -- O8's CI half. `run-action@v1` without an explicit `version:` takes the action's default release,
  -- which goes stale as prova moves — so a suite that needs a newer prova breaks in CI while passing
  -- locally. The generated workflow omits it, which is why this is asserted rather than assumed.
  local wf = root .. "/.github/workflows/proofs.yaml"
  if fs.exists(wf) then
    local text_wf = fs.read(wf)
    if text_wf:find("prova%-rs/run%-action") then
      t:expect(text_wf, "run-action pins an explicit prova version"):matches("version:%s*v?%d")
    end
  end
end

return ops
