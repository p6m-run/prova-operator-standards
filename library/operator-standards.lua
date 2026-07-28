---@meta operator-standards
--- prova-operator-standards — p6m operator standards as executable proofs.
---
--- Editor-only type stub for `require("operator-standards")`: it gives consumers completion and
--- signatures and ships nothing at runtime. Keep it in sync with init.lua's public API.

---@class ops.Identity
---@field name string           # kebab: "platform-cluster-operator"
---@field project_name string   # same as `name`
---@field snake_name string     # "platform_cluster_operator"
---@field metric_prefix string  # the {prefix} in {prefix}_reconcile_runs_total
---@field image string          # the tag the SUT builds
local Identity = {}

--- The expected metric family names for this operator (O4).
---@return string[]
function Identity:metric_families() end

---@class ops.Sut
---@field id ops.Identity
---@field cluster prova.KindCluster
---@field image string
---@field port integer          # the management port
---@field env table<string,string>  # what the operator was booted with
---@field name string           # the in-cluster workload name
---@field target string         # "deploy/<name>"
---@field available boolean     # whether the Deployment became Available
---@field url string|nil        # base URL of the management port (nil if it never started)
local Sut = {}

--- The operator's stdout — the subject of O5.
---@return string
function Sut:logs() end

--- Whether the Deployment became Available. Never raises.
---@param timeout string?
---@return boolean
function Sut:became_available(timeout) end

local ops = {}

--- The wire contract every operator must honor, as data (paths, statuses, content types, env names).
---@type table
ops.contract = {}

--- The naming oracle: derive every name the standards reference from an operator's repo name.
---@param spec { name: string, metric_prefix: string? }
---@return ops.Identity
function ops.identity(spec) end

--- Build the operator's production image, load it into the cluster, run it, and return a handle
--- whose `url` is its management port.
---@param spec { ctx: any, id: ops.Identity, cluster: prova.KindCluster, dir: string?, env: table?, format: string?, secrets: table?, buildargs: table?, dockerfile: string?, timeout: string?, tag_suffix: string? }
---@return ops.Sut
function ops.sut(spec) end

--- Parse the probe facts out of a rendered Deployment (used by `standards.chart`; exposed so it can
--- be proven hermetically against fixture YAML).
---@param yaml_text string
---@return table
function ops.chart_probe_facts(yaml_text) end

ops.standards = {}

--- O1 — one management port, plaintext, honored as injected.
---@param t any
---@param sut ops.Sut
---@param id ops.Identity
function ops.standards.management(t, sut, id) end

--- O2 / O3 — liveness unconditional, readiness reflecting real state.
---@param t any
---@param sut ops.Sut
---@param id ops.Identity
function ops.standards.health(t, sut, id) end

--- O3's shutdown half — readiness answers 503 before the process exits. DESTROYS the SUT; run last.
---@param t any
---@param sut ops.Sut
---@param id ops.Identity
function ops.standards.readiness_drops_on_shutdown(t, sut, id) end

--- O4 — metrics: format, the reconcile families, bounded label cardinality.
---@param t any
---@param sut ops.Sut
---@param id ops.Identity
function ops.standards.metrics(t, sut, id) end

--- O5 — structured logging, from both directions. `sibling` is the same image booted with the human
--- format; without it the proof is one-sided and an always-JSON operator passes.
---@param t any
---@param sut ops.Sut
---@param id ops.Identity
---@param sibling ops.Sut?
function ops.standards.logging(t, sut, id, sibling) end

--- O7 — traces, fail-open. `sut` must be booted with the OTLP endpoint pointed at a black hole.
---@param t any
---@param sut ops.Sut
---@param id ops.Identity
function ops.standards.traces(t, sut, id) end

--- O6 — the chart's probes name paths and ports the SUT actually answers. Needs `helm`.
---@param t any
---@param id ops.Identity
---@param sut ops.Sut|nil
---@param chart_dir string?
function ops.standards.chart(t, id, sut, chart_dir) end

--- O8 — suite hygiene: the manifest's keys, plugin pins, and .last-failed.json. No cluster needed.
---@param t any
---@param id ops.Identity?
function ops.standards.hygiene(t, id) end

return ops
