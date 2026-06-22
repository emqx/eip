# EMQX feature gates

## Changelog

* 2026-05-15: @zmstone Initial draft
* 2026-05-15: @zmstone Map feature gates onto the API-key scope check layer
  introduced on release-60
* 2026-05-15: @zmstone Target release-63; compile complete feature list
  from the release-63 `apps/` tree and resolve granularity questions
* 2026-05-15: @zmstone Fold `psk` into basics; merge `ai_completion` and
  `agent_registry` into a single `ai` feature
* 2026-05-15: @zmstone Remove `file_transfer`, `gcp_device`, `exhook`,
  `opentelemetry` from the listable vocabulary (available only when
  `EMQX_FEATURES=FULL`); fold `telemetry` into basics (license-controlled)
* 2026-05-15: @zmstone Drop the HOCON schema field; `EMQX_FEATURES` is
  not mapped into the configuration tree at all -- resolution is done
  once at boot and held in a dedicated module, with no dashboard /
  REST writable surface to defend
* 2026-06-22: @zmstone Reconcile the design with the merged
  implementation ([emqx/emqx#17407]). The implementation diverged from
  this draft on several points decided during review; this EIP is now
  updated to describe what was built and the PR is the source of truth.
  Major changes recorded below: enforcement is done by **not starting**
  the gated applications at boot (not by a REST scope-check layer);
  feature **dependencies are auto-enabled**; `authn` and `authz` are
  merged into a single `auth` feature; the dashboard `sso` / `rbac`
  sub-feature dotted syntax is dropped (both are bundled into
  `dashboard`); the four previously "bundled, not listable" features are
  ordinary, individually-listable features that the `FULL` preset also
  enables; the module is `emqx_machine_features` (in `emqx_machine`); the
  REST path is `GET /api/v5/features`; the `emqx ctl features` commands
  were not implemented.

[emqx/emqx#17407]: https://github.com/emqx/emqx/pull/17407

## Abstract

This proposal introduces a deployment-time feature governance mechanism
controlled by a single environment variable `EMQX_FEATURES`. The installer
of an EMQX deployment chooses which optional features are available; the
running broker and dashboard cannot enable or disable features beyond what
the installer specified.

A small set of basic components is always available: MQTT broker,
configuration, CLI, logging, license, plugins, durable storage, audit
log, live trace, node rebalance, retainer, TLS PSK, outbound telemetry
(the last is license-controlled rather than gate-controlled), and the
connector / bridge framework apps. The optional features include
dashboard, authentication+authorization, data integration, gateways,
cluster linking, multi-tenancy, AI features, metrics, message
transformation, schema validation, schema registry, MQTT extensions, and
a handful of niche features (file transfer, GCP device shim, external
hooks, OpenTelemetry).

When all optional features are disabled, EMQX boots in *essential* mode --
the same shape proposed independently in the boot-mode prototype. The two
designs converge here: essential mode is just `EMQX_FEATURES=ESSENTIAL`.

The mechanism is intentionally simple. Selection happens once at boot
and `EMQX_FEATURES` is not part of the HOCON configuration tree (no
schema entry, nothing in `emqx.conf` or `cluster.hocon`, nothing the
dashboard can write). There is no runtime toggle. Enforcement is by
**not starting the applications** that back a disabled feature: a
disabled feature's apps are filtered out of the boot sequence, so its
supervisors, hooks, and REST API modules never come up. Feature
**dependencies are resolved and auto-enabled** at parse time (e.g.
listing `metrics` also enables `dashboard`), so an operator never has to
hand-assemble a working dependency closure.

## Motivation

Today an EMQX installation ships with every optional feature compiled in
and started. There is no first-class way for the operator of a regulated
deployment to say "this installation must not expose Prometheus metrics"
or "no rule engine is permitted here" beyond reaching into config files
and disabling individual subsystems piecemeal -- a fragile approach
because nothing prevents a dashboard administrator from re-enabling them.

We need a single, auditable, installer-controlled switch that:

* is visible in deployment manifests (k8s `env:` block, `docker run -e`,
  systemd unit, helm `values.yaml`);
* cannot be overridden by the runtime dashboard or REST API;
* maps cleanly to forthcoming license-based feature gating without
  re-shaping the interface;
* converges with the existing essential boot-mode prototype, so the same
  mechanism serves both "minimal footprint" and "regulated deployment"
  use cases.

## Design

### Target release

This proposal targets EMQX release-63. The feature list below is
compiled from the `apps/` tree on `release-63`; features added on later
branches must be added to the list (and classified as core or gated)
when those branches merge.

### Enforcement model: start / don't-start the backing apps

Each EMQX feature is implemented by one or more OTP applications under
`apps/`. The feature gate works at that granularity: the resolved
feature set determines **which applications are started at boot**. If a
feature is disabled, the applications that implement it are removed from
the boot sequence entirely.

The complete set of `apps/*` applications (the "umbrella apps") is
generated into `apps/emqx_machine/priv/umbrella_apps.txt` by the mix task
`mix emqx.gen_umbrella_apps`. A CI/pre-commit static check
(`scripts/check-umbrella-apps.exs`) verifies the file stays in sync with
the actual `apps/` directory, so a newly added umbrella app cannot
silently escape the gating mechanism.

At boot, `emqx_machine_boot:sorted_reboot_apps/0` filters the reboot
list: for every app it asks `emqx_machine_features:is_umbrella_application_enabled/1`.

* Apps that are **not** umbrella apps (third-party deps, kernel apps,
  etc.) are always kept.
* Umbrella apps in the **core** set (see below) are always kept.
* Other umbrella apps are kept only if the resolved feature set allows
  them.

Because a disabled feature's apps never start, its REST handlers
(`minirest_api` modules live inside those apps) are never registered, its
supervisors never spin up, and its hooks are never installed. There is no
separate runtime "deny" layer to defend -- the feature is simply absent.

### Core components (always available)

The following applications are always started regardless of
`EMQX_FEATURES` (`emqx_machine_features:core_apps/0`). They have no
enable/disable control; turning them off would mean the broker cannot
run, cannot be operated, or cannot meet compliance requirements that the
rest of the product assumes.

* `emqx`, `emqx_machine` (the protocol core, listeners, sessions,
  routing, boot machinery)
* Configuration subsystem (`emqx_conf`)
* CLI (`emqx_ctl`)
* Cluster RPC (`emqx_bpapi`)
* License validation (`emqx_license`)
* Plugin loader (`emqx_plugins`; framework only -- individual plugins
  remain opt-in via install)
* Durable storage (`emqx_durable_storage`, `emqx_ds_backends`,
  `emqx_ds_builtin_local`, `emqx_ds_builtin_raft`, `emqx_durable_timer`)
* Audit log (`emqx_audit`)
* Node rebalance / evacuation (`emqx_node_rebalance`,
  `emqx_eviction_agent`)
* Retainer (`emqx_retainer`; enable/disable is per-config via
  `retainer.enable`, not a feature gate)
* TLS PSK (`emqx_psk` -- per-listener config, not a feature gate)
* Outbound telemetry (`emqx_telemetry` -- enable/disable is determined
  by the active license, not by feature gates)
* Connector / bridge framework apps (`emqx_resource`, `emqx_gen_bridge`;
  loaded but idle when `data_integration` is off)
* Shared utilities (`emqx_utils`, `emqx_extsub`)

Live trace (`emqx_trace`) is part of the `emqx` core; its REST surface
lives in `emqx_management`, which is gated by `dashboard`.

### Optional features (gated by `EMQX_FEATURES`)

The following features can be turned off. Names are lowercase,
underscore-separated, and form the alphabet of the explicit-list form
described later. Each feature maps to a set of `apps` plus a set of
feature-level `deps` that are auto-enabled with it
(`emqx_machine_features:known_features/0`).

| Name | Apps covered (representative) | Auto-enabled deps | What it covers |
| --- | --- | --- | --- |
| `dashboard` | `emqx_dashboard`, `emqx_dashboard_rbac`, `emqx_dashboard_sso`, `emqx_management`, `emqx_setopts`, `emqx_ldap` | -- | Dashboard UI **and** REST API, including SSO and RBAC |
| `auth` | `emqx_auth`, `emqx_ldap`, `emqx_mongodb`, `emqx_redis`, `emqx_bridge_http`, and all `emqx_auth_*` backends | -- | Authentication **and** authorization chain machinery and backends |
| `data_integration` | `emqx_connector`, `emqx_connector_jwt`, `emqx_connector_aggregator`, `emqx_bridge`, `emqx_rule_engine`, `emqx_postgresql`, `emqx_mysql`, `emqx_oracle`, `emqx_redis`, `emqx_s3`, `emqx_mongodb`, and all `emqx_bridge_*` | `schema_registry` | Bundle: rule engine + connectors + actions + sources |
| `message_transformation` | `emqx_message_transformation` | `schema_registry` | Per-message transformation hooks |
| `schema_validation` | `emqx_schema_validation` | `schema_registry` | Per-message schema validation |
| `schema_registry` | `emqx_schema_registry`, `emqx_bridge_http` | -- | Managed schema definitions referenced by validation and bridges |
| `gateways` | `emqx_gateway` + all `emqx_gateway_*` protocol gateways | `auth` | Non-MQTT protocol gateways. One toggle for all. |
| `cluster_link` | `emqx_cluster_link` | -- | Federated brokers |
| `multi_tenancy` | `emqx_mt` | -- | Multi-tenancy and namespacing |
| `ai` | `emqx_ai_completion`, `emqx_a2a_registry` | `schema_registry` | AI features: LLM completion hooks and agent-to-agent registry |
| `metrics` | `emqx_prometheus` | `dashboard`, `auth` | Internal metrics collection and Prometheus scrape endpoint |
| `mqtt_extensions` | `emqx_setopts`, `emqx_modules`, `emqx_auto_subscribe`, `emqx_slow_subs`, `emqx_streams`, `emqx_mq` | -- | Non-core message / topic features bundled into one gate (delayed publish, topic rewrite, topic metrics, auto subscribe, slow subs, streams, message queue) |
| `file_transfer` | `emqx_ft`, `emqx_s3` | -- | File Transfer over MQTT (niche transport feature) |
| `gcp_device` | `emqx_gcp_device` | `auth` | Migration-only compatibility shim for Google IoT Core |
| `exhook` | `emqx_exhook` | -- | External gRPC hooks |
| `opentelemetry` | `emqx_opentelemetry` | `dashboard` | OpenTelemetry exporter (needs `emqx_management`) |

`data_integration` is one toggle and covers the rule engine, connectors,
actions, and sources together. Enabling rules without actions is not a
shape we want to support: rules without effects have no purpose, and the
rule engine, connectors, actions, and sources are tightly entangled
internally.

`mqtt_extensions` is similarly a bundle. The included sub-features each
have their own existing per-feature config (so an operator can disable
`topic_rewrite` while keeping `delayed_publish` enabled via config), but
the feature gate is single-grained.

`gateways` is one toggle for all protocols. A future refinement may split
per-protocol; for now governance is "all or none."

The backend / connector / gateway app lists are partly **discovered
dynamically** at boot from the full reboot-app list by name prefix
(`emqx_auth_*` for `auth`, `emqx_bridge_*` for `data_integration`,
`emqx_gateway_*` for `gateways`), so adding a new backend of an existing
kind does not require editing the feature table.

#### Dashboard SSO and RBAC

`emqx_dashboard_sso` (single sign-on) and `emqx_dashboard_rbac`
(role-based access control) are part of the `dashboard` feature -- they
start whenever `dashboard` is enabled. The earlier draft proposed dotted
`dashboard.sso` / `dashboard.rbac` sub-toggles; that syntax was **not**
implemented. There are no sub-features and no dotted names.

#### Niche features and the `FULL` preset

`file_transfer`, `gcp_device`, `exhook`, and `opentelemetry` are niche or
migration-oriented. They are ordinary entries in the known-feature list:
they are enabled by the `FULL` preset and can also be listed individually
in a custom set (e.g. `EMQX_FEATURES=exhook`). The earlier draft proposed
making them non-listable "bundled" features; that restriction was **not**
implemented.

### Feature dependencies (auto-enabled)

Each feature declares `deps` -- other features it requires. At parse
time, listing a feature transitively pulls in its dependencies and their
apps (`resolve_dependent_features/2`, `resolve_dependent_apps/2`). For
example, `EMQX_FEATURES=metrics` resolves to `metrics`, `dashboard`, and
`auth` all enabled, because the Prometheus scrape endpoint is served by
the dashboard's REST listener and the management API requires auth.

This is a deliberate reversal of the earlier draft, which insisted on "no
implicit enablement" and proposed only *warning* about the
`metrics -> dashboard` coupling. The implemented behavior auto-enables
dependencies so that any single feature name resolves to a working
deployment without the operator having to know the internal dependency
graph. The dependency edges in the current implementation:

* `data_integration -> schema_registry`
* `message_transformation -> schema_registry`
* `schema_validation -> schema_registry`
* `ai -> schema_registry`
* `gateways -> auth`
* `gcp_device -> auth`
* `metrics -> dashboard, auth`
* `opentelemetry -> dashboard`

### Environment variable

A single env var controls the resolved set:

```
EMQX_FEATURES=<value>
```

The value takes one of two forms:

1. **A preset name in ALL CAPS.** Currently `FULL` or `ESSENTIAL`.
2. **A list of lowercase feature names** from the table above, separated
   by commas and/or spaces.

Examples:

```
EMQX_FEATURES=FULL                                # all features on
EMQX_FEATURES=ESSENTIAL                           # all optional features off
EMQX_FEATURES=dashboard,auth                      # explicit subset
EMQX_FEATURES=dashboard,auth,data_integration,metrics
EMQX_FEATURES=metrics                             # resolves to metrics+dashboard+auth
```

Mixing a preset with extra features is not supported: `FULL,metrics` is
rejected (the parser tries to resolve `FULL` as a feature name, fails,
and the node refuses to boot). The set of features is small enough that
hand-listing is acceptable.

ALL CAPS is reserved for preset names; lowercase is reserved for feature
names. This convention makes the parser unambiguous and gives readers a
visual cue.

### Default when unset

If `EMQX_FEATURES` is unset (or empty), the broker behaves as if the
value were `FULL`. This preserves the current default behavior of EMQX:
existing deployments upgrade with no change in feature surface.

### Parser semantics

Resolution at boot (`emqx_machine_features:cache_features/0`,
`parse_features/1`):

1. Read `EMQX_FEATURES`.
2. If unset or empty, treat as `FULL` (`#{preset => full}`).
3. If the value equals `FULL`, the preset is `full` -- every umbrella app
   is allowed (`is_umbrella_application_enabled/1` returns `true` for
   all).
4. If the value equals `ESSENTIAL`, the preset is `essential` with an
   empty allowed-app set -- only core apps start.
5. Otherwise the value is split on commas and spaces. Each token must be
   the name of a known feature. For each known feature, its apps and the
   apps of its transitive deps are added to the allowed-app set, and the
   feature plus its transitive dep features are recorded as enabled. The
   resolved preset is `custom`.
6. Any token that is not a known feature (including a stray ALL CAPS
   token like `UNKNOWN`, or a typo like `data_integratio`) aborts
   resolution with an `unknown_feature` error carrying the offending
   token, the list of known features, and a "did you mean ...?" hint
   computed by Jaro similarity. The node logs this at `critical`
   (`invalid_feature_specification`) and exits with a non-zero code --
   it does not boot.

The resolved set is logged once at boot at `notice` level with
`msg => "feature_gates_resolved"` and the fields of
`emqx_machine_features:info/0` (`preset`, `enabled`, `disabled`):

```
[notice] msg: feature_gates_resolved,
         preset: full,            % or "essential" / "custom"
         enabled: [ai, auth, cluster_link, dashboard, data_integration,
                   exhook, file_transfer, gateways, gcp_device, metrics,
                   message_transformation, multi_tenancy, mqtt_extensions,
                   opentelemetry, schema_registry, schema_validation],
         disabled: []
```

### Where the resolved set lives

`EMQX_FEATURES` is **not** mapped into the HOCON configuration tree.
There is no `features.enabled` config path, no schema entry, and no
hocon-typed field. The resolved set is parsed once at boot and cached in
a `persistent_term` keyed by the `emqx_machine_features` module.

This keeps the env-var-only semantics honest: nothing in the configs
API, dashboard config editor, or `cluster.hocon` can see or modify the
feature gates. The governance boundary is enforced by *absence from the
config tree* and by the gated apps simply not starting, not by an
annotation on a schema field.

Queries from the rest of the codebase go through the module:

```erlang
emqx_machine_features:info().                              %% -> #{preset, enabled, disabled}
emqx_machine_features:is_umbrella_application_enabled(App). %% -> true | false
```

`is_umbrella_application_enabled/1` is the hook the boot sequence uses to
decide whether to start each umbrella app. Validation (typo rejection,
unknown-token errors) happens in the parser at boot.

### REST API

A single read-only endpoint exposes the resolved state
(`emqx_mgmt_api_features`, scope `?SCOPE_SYSTEM`):

```
GET /api/v5/features
200 OK
{
  "preset":   "full",
  "enabled":  ["ai", "auth", "cluster_link", "dashboard", ...],
  "disabled": [],
  "bundled":  []
}
```

```
GET /api/v5/features            # custom example
200 OK
{
  "preset":   "custom",
  "enabled":  ["data_integration", "dashboard", "auth", "schema_registry"],
  "disabled": ["message_transformation", "schema_validation",
               "gateways", "cluster_link", "multi_tenancy", "ai",
               "metrics", "mqtt_extensions", ...],
  "bundled":  []
}
```

The response schema declares `preset`, `enabled`, `disabled`, and
`bundled`. The handler returns `emqx_machine_features:info/0`, which
currently populates `preset`, `enabled`, and `disabled`.

This endpoint lives in `emqx_management`, so it is part of the
`dashboard` feature surface: it is only reachable when `dashboard` is
enabled. A deployment running without the dashboard inspects the resolved
set via the boot log (`feature_gates_resolved`).

### Dashboard surface

The dashboard UI hides menu items and pages whose backing feature is
disabled. It fetches the resolved set from `/api/v5/features` at load
time and maps feature names to UI components -- the mapping lives on the
dashboard side and must be kept in sync with the broker's feature list.

End users only ever see the features available to them; they do not see
options they cannot use. Discovery is via `/api/v5/features`, which is
always available when the `dashboard` feature is enabled.

### `metrics` requires `dashboard`

The Prometheus scrape endpoint is served by the dashboard's REST listener
in the current architecture, and the management API requires the auth
machinery. Rather than warn about this coupling, the implementation
declares it as a dependency: `metrics` auto-enables `dashboard` and
`auth`. Listing `metrics` alone yields a working metrics-scrape
deployment.

Decoupling the Prometheus scrape endpoint from the dashboard REST
listener (binding it to a dedicated port, the upstream
Prometheus-friendly `:9100/metrics` pattern) would remove this
dependency edge. That remains future work; until then the dependency is
expressed honestly in the feature graph instead of being papered over.

### Governance boundary

Feature gates are an *installer* concern, not a *runtime operator*
concern. The boundary is enforced by:

* the env-var-only interface (no file the dashboard can write);
* the absence of a `features.*` config branch entirely -- there is
  nothing in the HOCON config tree for the dashboard to mutate;
* the absence of an "edit feature gates" UI in the dashboard;
* boot-time-only evaluation (no SIGHUP-style reload); the gated apps are
  simply never started.

To change the enabled feature set, the installer edits the deployment
manifest (k8s `env:`, docker run, helm values, systemd unit) and
restarts the broker. The operator running the broker cannot bypass this.

## Configuration Changes

No HOCON schema changes. `EMQX_FEATURES` is not mapped into the
configuration tree; it is parsed once at boot and cached in a
`persistent_term` in `emqx_machine_features`.

No existing config keys change. Existing per-feature config sections
(`dashboard {...}`, `prometheus {...}`, `authorization {...}` etc.)
remain in place; they are only consulted when the corresponding feature's
apps are started.

New REST endpoint:

```
GET /api/v5/features    # read-only
```

(There are no new `emqx ctl features` CLI commands; the earlier draft
proposed them but they were not implemented. Non-dashboard deployments
read the resolved set from the boot log.)

## Backwards Compatibility

* `EMQX_FEATURES` unset => behaves identically to today (`FULL`).
* Setting `EMQX_FEATURES=FULL` explicitly is identical to the default.
* Setting `EMQX_FEATURES` to anything else disables features the
  deployment currently relies on, and is therefore an opt-in,
  operator-driven change.
* Existing per-feature config keys (`prometheus.enable = true`,
  `dashboard.listeners.*`, etc.) continue to work. When the corresponding
  gate is disabled, the backing apps do not start and those config
  sections are simply not consulted; this lets a deployment ship the same
  `emqx.conf` across environments differing only in their `EMQX_FEATURES`
  value.

No wire-protocol changes. No on-disk format changes. No license-format
changes (license-driven feature gating is explicit future work and not
covered here).

## Document Changes

* Operator documentation: a new "Feature gates" page describing
  `EMQX_FEATURES`, the preset names, the explicit-list form, the
  dependency auto-enablement, and the resolved feature list.
* Helm chart README: how to set `EMQX_FEATURES` via `emqxConfig`.
* Docker README: example `docker run -e EMQX_FEATURES=...` invocations.
* Dashboard user guide: note that menu items missing from the dashboard
  may be feature-gated, with a pointer to `/api/v5/features`.
* Release notes: backwards-compatible default, migration guidance for
  operators who want to switch to `ESSENTIAL` or a custom list.

## Testing Suggestions

These mirror the tests landed in the implementation
(`apps/emqx_machine/test/emqx_machine_features_*`,
`apps/emqx_management/test/emqx_mgmt_api_features_SUITE.erl`,
`scripts/test/test_emqx_boot.py`):

* Parser unit tests covering: unset, empty, `FULL`, `ESSENTIAL`,
  arbitrary subset lists, dependency closure, unknown tokens (with the
  "did you mean" hint), whitespace / comma handling.
* Boot integration test (`test_emqx_boot.py`): with
  `EMQX_FEATURES=ESSENTIAL`, the node boots, `preset` is `essential`,
  `enabled` is empty, and only core apps are started.
* Boot integration test: with `EMQX_FEATURES=FULL`, the node boots and
  `disabled` is empty.
* Boot integration test: each known feature individually (including
  `file_transfer`, `gcp_device`, `exhook`, `opentelemetry`) yields
  `preset = custom` and the feature in `enabled`; and all features at
  once.
* Boot failure test: an unknown preset (`UNKNOWN`) and an unknown /
  misspelled feature (`data_integratio`) both cause a non-zero exit with
  a `critical` `invalid_feature_specification` log carrying
  `reason: unknown_feature` and a `hint`.
* REST test: `GET /api/v5/features` returns the resolved set when
  `dashboard` is enabled.
* Static-check test: `scripts/check-umbrella-apps.exs` fails when
  `umbrella_apps.txt` drifts from the `apps/` directory.

## Future Work

* **Decouple `metrics` from `dashboard`.** Bind the Prometheus scrape
  endpoint to its own HTTP listener so the two features become
  independent and the `metrics -> dashboard` dependency edge can be
  dropped. Separate proposal.
* **License-driven feature gating.** The license payload may carry a set
  of permitted features; the resolved enabled-set becomes
  `intersect(EMQX_FEATURES, license.allowed_features)`. Drops in without
  changing the env-var interface. When the intersection excludes
  something the operator requested, log `feature_disabled_by_license` at
  warn level.
* **Finer-grained `data_integration` toggles.** If a deployment shape
  emerges that legitimately wants, say, sources without actions,
  introduce sub-toggles. Until such a shape exists, the current
  bundle-toggle is preferred for its simplicity.
* **Per-protocol `gateways` toggles.** Split the single `gateways` gate
  per protocol if a governance case appears.
* **Split `auth` into `authn` / `authz`.** The earlier draft modelled
  these separately; they were merged for the first cut. They can be split
  later without changing the env-var grammar.
* **CLI inspection.** Add `emqx ctl features ...` for non-dashboard
  deployments that today rely on the boot log.
* **Gate the plugin framework (`plugins` feature).** Today `emqx_plugins`
  is a core app and is always started. Promote it to a gated feature so a
  regulated deployment can forbid third-party plugins entirely. When the
  feature is not allowed, `emqx_plugins` should not start, and the
  dashboard should not render the plugin management UI (upload, install,
  enable/disable, configure) -- the same menu-hiding driven by
  `/api/v5/features`.

## Declined Alternatives

* **HOCON file as the canonical surface, with env var only as override.**
  Rejected because it gives the dashboard a writable surface (anything in
  HOCON the dashboard can mutate via the configs API), undermining the
  governance boundary. The env-var-only interface keeps installer policy
  off the runtime mutation surface entirely.
* **One boolean per feature in HOCON (`features.dashboard.enabled = true`,
  etc.).** Rejected because the number of features is small enough that a
  list reads better than a dozen scattered booleans, and the list form
  encodes uniformly into licenses and env vars without per-key fan-out.
* **Acronym blob (`EMQX_FEATURES=DPAm`).** Rejected because the
  compactness gain (a few bytes) is dwarfed by the readability cost.
  Compactness is a non-goal at this scale.
* **Allow mixing preset and explicit list
  (`EMQX_FEATURES=ESSENTIAL,mqtt_extensions`).** Rejected; the feature
  list is short enough to enumerate explicitly, and the mixed form
  complicates the parser and the `preset` field semantics.
* **A separate REST scope-check "deny" layer for disabled features.** The
  earlier draft proposed translating disabled features into a denied-scope
  set and returning `403 FEATURE_DISABLED` from
  `emqx_mgmt_auth:check_scopes`. Rejected in favor of simply not starting
  the backing apps: a disabled feature's REST modules are never
  registered, so there is no endpoint to guard and no second enforcement
  path to keep in sync with the app-start path.
* **No implicit enablement / warn-only dependencies.** The earlier draft
  refused to auto-enable dependencies and would only warn about
  `metrics -> dashboard`. Rejected in favor of auto-resolving the
  dependency closure so any single feature name yields a working
  deployment; the operator does not need to know the internal graph.
* **Runtime mutability via dashboard.** Rejected because feature gates are
  deployment policy, not operational settings. Several candidate features
  (dashboard listener, metrics listener, rule engine ETS tables, authn
  chain registration) have non-trivial teardown semantics that are
  expensive to support correctly. Boot-time evaluation sidesteps the
  issue.
</content>
</invoke>
