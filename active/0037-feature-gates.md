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

## Abstract

This proposal introduces a deployment-time feature governance mechanism
controlled by a single environment variable `EMQX_FEATURES`. The installer
of an EMQX deployment chooses which optional features are available; the
running broker and dashboard cannot enable or disable features beyond what
the installer specified.

A small set of basic components is always available: MQTT broker,
configuration, CLI, logging, license, plugins, durable storage, audit
log, live trace, node rebalance, retainer, TLS PSK, and outbound
telemetry (the last is license-controlled rather than gate-controlled).
The user-listable optional features include dashboard, authentication,
authorization, data integration, gateways, cluster linking,
multi-tenancy, AI features, metrics, message transformation, schema
validation, schema registry, and MQTT extensions. A handful of further
features (file transfer, GCP device shim, external hooks,
OpenTelemetry) are bundled into the `FULL` preset but are not
addressable individually in the env-var list.

When all optional features are disabled, EMQX boots in *essential* mode --
the same shape proposed independently in the boot-mode prototype. The two
designs converge here: essential mode is just `EMQX_FEATURES=ESSENTIAL`.

The mechanism is intentionally simple. Selection happens once at boot
and `EMQX_FEATURES` is not part of the HOCON configuration tree (no
schema entry, nothing in `emqx.conf` or `cluster.hocon`, nothing the
dashboard can write). There is no runtime toggle, no dependency
resolution, no implicit
enablement. Operators who need a feature must explicitly list it.

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
compiled from the `apps/` tree on `release-63` as of this drafting;
features added on later branches must be added to the list (and
classified as basic or gated) when those branches merge.

### Basic components (always available)

The following components are always started. They have no enable/disable
control; turning them off would mean the broker cannot run, cannot be
operated, or cannot meet compliance requirements that the rest of the
product assumes.

* MQTT broker (the protocol core, listeners, sessions, routing)
* Configuration subsystem (`emqx_conf`)
* CLI (`emqx_ctl`)
* Logging
* License validation (`emqx_license`)
* Plugin loader (`emqx_plugins`; framework only -- individual plugins
  remain opt-in via install)
* Durable storage (`emqx_durable_storage`, `emqx_ds_backends`,
  `emqx_ds_builtin_local`, `emqx_ds_builtin_raft`, `emqx_durable_timer`)
* Cluster RPC (`emqx_bpapi`)
* Audit log (`emqx_audit`)
* Live trace (`emqx_trace`, the REST surface in `emqx_management`
  is gated by `dashboard`)
* Node rebalance / evacuation (`emqx_node_rebalance`,
  `emqx_eviction_agent`)
* Retainer (`emqx_retainer` -- can still be disabled per-listener via
  existing MQTT config; not a feature gate)
* TLS PSK (`emqx_psk` -- per-listener config, not a feature gate)
* Outbound telemetry (`emqx_telemetry` -- enable/disable is determined
  by the active license, not by feature gates)
* Connector / bridge framework apps (`emqx_resource`,
  `emqx_connector_aggregator`, `emqx_gen_bridge` -- loaded but idle
  when `data_integration` is off)

### Optional features (gated by `EMQX_FEATURES`)

The following features can be turned off. Names are lowercase,
underscore-separated, and form the alphabet of the explicit-list form
described later.

| Name | Apps covered | What it covers |
| --- | --- | --- |
| `dashboard` | `emqx_dashboard`, `emqx_management` | Dashboard UI **and** REST API (`emqx_dashboard_sso` and `emqx_dashboard_rbac` are sub-features described below) |
| `authn` | `emqx_auth` (chain) + backends | Authentication chain machinery |
| `authz` | `emqx_auth` (chain) + backends | Authorization chain machinery |
| `data_integration` | `emqx_rule_engine`, `emqx_bridge`, `emqx_bridge_*`, `emqx_connector` | Bundle: rule engine + connectors + actions + sources |
| `message_transformation` | `emqx_message_transformation` | Per-message transformation hooks |
| `schema_validation` | `emqx_schema_validation` | Per-message schema validation |
| `schema_registry` | `emqx_schema_registry` | Managed schema definitions referenced by validation and bridges |
| `gateways` | `emqx_gateway` + 9 protocol gateways (CoAP, ExProto, GBT32960, JT808, LwM2M, MQTT-SN, NATS, OCPP, Stomp) | Non-MQTT protocol gateways. One toggle for all. |
| `cluster_link` | `emqx_cluster_link` | Federated brokers |
| `multi_tenancy` | `emqx_mt` | Multi-tenancy |
| `ai` | `emqx_ai_completion`, `emqx_a2a_registry` | AI features: LLM completion hooks and agent-to-agent registry |
| `metrics` | `emqx_prometheus` | Internal metrics collection and Prometheus scrape endpoint |
| `mqtt_extensions` | `emqx_setopts`, `emqx_modules` (`delayed_publish`, `topic_rewrite`, `topic_metrics`), `emqx_auto_subscribe`, `emqx_slow_subs`, `emqx_streams`, `emqx_mq` | Non-MQTT-core message / topic features bundled into one gate |

`data_integration` is one toggle and covers the rule engine, connectors,
actions, and sources together. Enabling rules without actions is not a
shape we want to support: rules without effects have no purpose, and
the rule engine, connectors, actions, and sources are tightly
entangled internally.

`mqtt_extensions` is similarly a bundle. The included sub-features each
have their own existing per-feature config (so an operator can disable
`topic_rewrite` while keeping `delayed_publish` enabled via config),
but the feature gate is single-grained.

`gateways` is one toggle for all nine protocols. A future refinement
may split per-protocol; for now governance is "all or none."

#### Dashboard sub-features

When `dashboard` is enabled, two sub-toggles refine the dashboard's
auth surface:

| Sub-feature | App | What it covers |
| --- | --- | --- |
| `dashboard.sso` | `emqx_dashboard_sso` | Single sign-on for dashboard users |
| `dashboard.rbac` | `emqx_dashboard_rbac` | Role-based access control for dashboard users |

Sub-features are addressed in the env-var list form by their dotted
name: `EMQX_FEATURES=dashboard,dashboard.sso,authn,authz` enables
the dashboard with SSO but without RBAC. Listing a sub-feature without
its parent (`dashboard.sso` with no `dashboard`) fails boot.

#### Features bundled into `FULL` but not individually listable

A handful of features are part of the `FULL` preset but cannot be
addressed by name in the explicit-list form. They are governance
"all-or-nothing": either the deployment uses `FULL` and gets them, or
it uses a custom list and does not.

| App | Why it is not individually listable |
| --- | --- |
| `emqx_ft` | File Transfer over MQTT. Niche transport feature. Off by default unless the operator configures a file-transfer endpoint; including it in `FULL` costs nothing for deployments that do not use it. |
| `emqx_gcp_device` | Migration-only compatibility shim for Google IoT Core. Tied to a narrow user base. |
| `emqx_exhook` | External gRPC hooks. Replaced for most use cases by plugins; remaining users typically know they want it and run `FULL`. |
| `emqx_opentelemetry` | OpenTelemetry exporter. Most deployments pick either Prometheus (`metrics`) or OTel, not both; the OTel exporter remains startable from configuration even when `FULL` is not selected. |

Trying to address them in a custom list (`EMQX_FEATURES=file_transfer`)
fails boot with `unknown feature: file_transfer; known: [...]`. The
implication is that "FULL minus one of these four" is not directly
expressible in the env var. Operators who need this shape build the
custom list of features they do want and accept that the hidden four
go with the `FULL`/`ESSENTIAL` decision.

Future EIPs may promote any of these to the listable vocabulary if the
governance case becomes clear.

### Environment variable

A single env var controls the resolved set:

```
EMQX_FEATURES=<value>
```

The value takes one of two forms:

1. **A preset name in ALL CAPS.** Currently `FULL` or `ESSENTIAL`.
2. **A comma-separated list of lowercase feature names** from the table
   above.

Examples:

```
EMQX_FEATURES=FULL                                # all optional features on
EMQX_FEATURES=ESSENTIAL                           # all optional features off
EMQX_FEATURES=dashboard,authn,authz               # explicit subset
EMQX_FEATURES=dashboard,authn,authz,data_integration,metrics
```

Mixing a preset with extra features is *not* supported:
`ESSENTIAL,mqtt_extensions` is rejected. The set of features is small
enough that hand-listing is acceptable.

ALL CAPS is reserved for preset names; lowercase is reserved for feature
names. This convention makes the parser unambiguous and gives readers a
visual cue.

### Default when unset

If `EMQX_FEATURES` is unset (or empty), the broker behaves as if the
value were `FULL`. This preserves the current default behavior of EMQX:
existing deployments upgrade with no change in feature surface.

### Parser semantics

Resolution at boot:

1. Read `EMQX_FEATURES`.
2. If unset or empty, treat as `FULL`.
3. If the trimmed value equals `FULL`, set enabled-set to all optional
   features.
4. If the trimmed value equals `ESSENTIAL`, set enabled-set to the empty
   set.
5. If the trimmed value is any other ALL CAPS token, fail boot with
   `unknown_feature_preset: <token>; supported: [FULL, ESSENTIAL]`.
6. Otherwise split on `,`, trim each token. Each token must match a
   known lowercase feature name. Unknown tokens fail boot with
   `unknown_feature: <token>; known: [...]`.

The resolved enabled-set is logged once at boot:

```
[info] msg: feature_gates_resolved,
       source: env,
       preset: FULL,                  % or "custom" / "ESSENTIAL"
       enabled: [dashboard, authn, authz, data_integration,
                 message_transformation, schema_validation, schema_registry,
                 gateways, cluster_link, multi_tenancy, ai, metrics,
                 mqtt_extensions],
       bundled: [file_transfer, gcp_device, exhook, opentelemetry],
       disabled: []
```

### Where the resolved set lives

`EMQX_FEATURES` is **not** mapped into the HOCON configuration tree.
There is no `features.enabled` config path, no schema entry, and no
hocon-typed field. The resolved set is held in a dedicated module
(e.g. `emqx_features`) as a one-time-at-boot value -- `persistent_term`
or `application:set_env/3` are both reasonable storage choices.

This keeps the env-var-only semantics honest: nothing in the configs
API, dashboard config editor, or `cluster.hocon` can see or modify the
feature gates. The governance boundary is enforced by *absence from
the config tree*, not by an annotation on a schema field.

Queries from the rest of the codebase go through the module:

```erlang
emqx_features:is_enabled(dashboard).   %% -> true | false
emqx_features:enabled().               %% -> [dashboard, authn, authz, ...]
emqx_features:preset().                %% -> 'FULL' | 'ESSENTIAL' | custom
```

Validation (typo rejection, unknown-token errors) happens in the parser
at boot.

### REST API

A single read-only endpoint exposes the resolved state:

```
GET /api/v5/feature_flags
200 OK
{
  "preset":   "FULL",
  "enabled":  ["dashboard", "authn", "authz", "data_integration",
               "message_transformation", "schema_validation", "schema_registry",
               "gateways", "cluster_link", "multi_tenancy", "ai",
               "metrics", "mqtt_extensions"],
  "disabled": [],
  "bundled":  ["file_transfer", "gcp_device", "exhook", "opentelemetry"]
}
```

If the deployment used an explicit list, `preset` is `"custom"` and
the `bundled` list is empty (those features are not part of a custom
configuration):

```
GET /api/v5/feature_flags
200 OK
{
  "preset":   "custom",
  "enabled":  ["dashboard", "authn", "authz", "data_integration"],
  "disabled": ["message_transformation", "schema_validation",
               "schema_registry", "gateways", "cluster_link",
               "multi_tenancy", "ai", "metrics", "mqtt_extensions"],
  "bundled":  []
}
```

This endpoint is part of the `dashboard` feature surface; it is therefore
only reachable when `dashboard` itself is enabled. A deployment running
without the dashboard inspects state via `emqx ctl features list` (CLI is
always available).

### Mapping features to API scopes

Enforcement of feature gates at the REST layer reuses the API-key scope
machinery already introduced on `release-60`. That machinery has every
`minirest_api` module declare a `scopes/0` callback returning one of a
fixed set of macros (`?SCOPE_CONNECTIONS`, `?SCOPE_DATA_INTEGRATION`,
`?SCOPE_ACCESS_CONTROL`, `?SCOPE_MONITORING`, etc.; full list in
`apps/emqx/include/emqx_api_key_scopes.hrl`). `emqx_mgmt_auth:check_scopes/2`
is invoked on every authenticated request; a missing scope returns
`403 UNAUTHORIZED_ROLE`.

Feature gates plug into the same chain. The boot-resolved disabled-set is
translated into a *denied-scopes* set; the scope checker consults both the
caller's granted scopes and the deployment's denied scopes. A request to
an endpoint whose declared scope is in the denied-set is rejected even
when the caller's API key has been granted that scope.

The response keeps the existing 403 status but carries a distinct
machine-readable code so frontends can render the absence differently
from a permission failure:

```
403 Forbidden
{
  "code":    "FEATURE_DISABLED",
  "feature": "data_integration",
  "message": "This feature is disabled by deployment configuration."
}
```

Most features align with an existing scope; several share a scope, so
the actual enforcement key is `(scope, minirest_api module)` rather
than scope alone. Initial mapping:

| Feature gate | Primary scope(s) | Notes |
| --- | --- | --- |
| `dashboard` | n/a | REST listener not started; no scope check reachable |
| `dashboard.sso`, `dashboard.rbac` | `?SCOPE_ACCESS_CONTROL` | only the specific SSO / RBAC sub-modules |
| `authn` | `?SCOPE_ACCESS_CONTROL` | authn-specific modules only |
| `authz` | `?SCOPE_ACCESS_CONTROL` | authz-specific modules only |
| `data_integration` | `?SCOPE_DATA_INTEGRATION` | rule engine + bridges + connectors + actions + sources |
| `message_transformation` | `?SCOPE_DATA_INTEGRATION` | transformation endpoints |
| `schema_validation` | `?SCOPE_DATA_INTEGRATION` | validation endpoints |
| `schema_registry` | `?SCOPE_DATA_INTEGRATION` | schema management endpoints |
| `gateways` | `?SCOPE_GATEWAYS` | all 9 gateway protocols |
| `cluster_link` | `?SCOPE_CLUSTER_OPERATIONS` | cluster-link config + status |
| `multi_tenancy` | (new) | tenant-management endpoints; may need new scope |
| `ai` | `?SCOPE_DATA_INTEGRATION` (LLM hooks) + (new for agent registry) | LLM completion config + agent-to-agent registry |
| `metrics` | `?SCOPE_MONITORING` | prometheus + collection endpoints |
| `mqtt_extensions` | `?SCOPE_CONNECTIONS` (most) | per-sub-module: setopts, delayed_publish, topic_rewrite, topic_metrics, auto_subscribe, slow_subs, streams, mq |

Multiple features can share a scope (`authn` and `authz` both under
`?SCOPE_ACCESS_CONTROL`; the `data_integration` family under
`?SCOPE_DATA_INTEGRATION`). Scope-level granularity is therefore not
always enough: the check helper consults a central registry of
`feature -> [minirest_api module]` so disabling one feature inside a
shared scope does not disable its siblings.

A few features have no obvious existing scope (`multi_tenancy`, the
agent-registry half of `ai`). The implementation may either introduce
new scope macros for them, or pick the closest semantic match
(e.g. `?SCOPE_SYSTEM` for tenant ops). This is implementation latitude
and does not affect the env-var interface.

If a finer-grained scope is needed in the future (e.g. splitting
`?SCOPE_ACCESS_CONTROL` into `?SCOPE_AUTHN` and `?SCOPE_AUTHZ`), this
proposal does not block it; new scopes can be added without changing
the env-var interface.

### Dashboard surface

The dashboard UI hides menu items and pages whose backing feature is
disabled. It fetches the resolved set from `/api/v5/feature_flags` at
load time and maps feature names to UI components -- the mapping lives
on the dashboard side and must be kept in sync with the broker's
feature list. The same fetch result drives both the menu-hiding and the
fall-back behavior when the UI encounters an unexpected `FEATURE_DISABLED`
response (for example, after the operator rebooted with a different
`EMQX_FEATURES` value).

End users only ever see the features available to them; they do not see
options they cannot use. Discovery is via `/api/v5/feature_flags`, which
is always available when the `dashboard` feature is enabled.

### Known dependency: `metrics` requires `dashboard`

The Prometheus scrape endpoint is served by the dashboard's REST listener
in the current architecture. As a consequence, enabling `metrics` without
`dashboard` produces a setup where metrics are collected but cannot be
scraped.

This proposal **documents the dependency but does not resolve it**.

* The parser does **not** auto-enable `dashboard` when `metrics` is
  listed.
* The parser does **not** reject the combination at boot.
* The boot log emits a warning when `metrics` is enabled and `dashboard`
  is not:
  ```
  [warning] msg: feature_dependency_unmet, feature: metrics,
            requires: dashboard,
            consequence: metrics_collected_but_not_exposed
  ```

Resolving this properly belongs to a separate proposal that decouples the
Prometheus scrape endpoint from the dashboard REST listener (typically by
binding it to a dedicated port). That separation is the upstream
Prometheus-friendly pattern (e.g. `:9100/metrics`) and removes the
coupling at the architectural level rather than papering over it in the
parser.

Other features are mutually independent.

### Governance boundary

Feature gates are an *installer* concern, not a *runtime operator*
concern. The boundary is enforced by:

* the env-var-only interface (no file the dashboard can write);
* the absence of a `features.*` config branch entirely -- there is
  nothing in the HOCON config tree for the dashboard to mutate;
* the absence of an "edit feature gates" UI in the dashboard;
* boot-time-only evaluation (no SIGHUP-style reload).

To change the enabled feature set, the installer edits the deployment
manifest (k8s `env:`, docker run, helm values, systemd unit) and
restarts the broker. The operator running the broker cannot bypass this.

## Configuration Changes

No HOCON schema changes. `EMQX_FEATURES` is not mapped into the
configuration tree; it is parsed once at boot and held in a dedicated
runtime module (see "Where the resolved set lives").

No existing config keys change. Existing per-feature config sections
(`dashboard {...}`, `prometheus {...}`, `authorization {...}` etc.)
remain in place; they are only consulted when the corresponding feature
is enabled.

New REST endpoint:

```
GET /api/v5/feature_flags    # read-only
```

New CLI commands:

```
emqx ctl features list
emqx ctl features status <name>
```

Both query `emqx_features:enabled/0` / `emqx_features:is_enabled/1`,
which in turn read the boot-resolved set.

## Backwards Compatibility

* `EMQX_FEATURES` unset => behaves identically to today (`FULL`).
* Setting `EMQX_FEATURES=FULL` explicitly is identical to the default.
* Setting `EMQX_FEATURES` to anything else disables features the
  deployment currently relies on, and is therefore an opt-in,
  operator-driven change.
* Existing per-feature config keys (`prometheus.enable = true`,
  `dashboard.listeners.*`, etc.) continue to work. When the
  corresponding gate is disabled, those configs are ignored at startup
  rather than errored on; this lets a deployment ship the same
  `emqx.conf` across environments differing only in their
  `EMQX_FEATURES` value.

No wire-protocol changes. No on-disk format changes. No license-format
changes (license-driven feature gating is explicit future work and not
covered here).

## Document Changes

* Operator documentation: a new "Feature gates" page describing
  `EMQX_FEATURES`, the preset names, the explicit-list form, and the
  resolved feature list.
* Helm chart README: how to set `EMQX_FEATURES` via `emqxConfig`.
* Docker README: example `docker run -e EMQX_FEATURES=...` invocations.
* Dashboard user guide: note that menu items missing from the dashboard
  may be feature-gated, with a pointer to `/api/v5/feature_flags`.
* Release notes: backwards-compatible default, migration guidance for
  operators who want to switch to `ESSENTIAL` or a custom list.

## Testing Suggestions

* Parser unit tests covering: unset, empty, `FULL`, `ESSENTIAL`,
  arbitrary subset lists, unknown tokens, mixed ALL CAPS + lowercase
  (rejected), whitespace handling.
* Boot-time integration test: with `EMQX_FEATURES=ESSENTIAL`, verify
  none of the optional feature apps are started, no dashboard listener
  is bound, `/api/v5/*` endpoints (other than feature_flags, which is
  off because dashboard is off) are unreachable.
* Boot-time integration test: with each feature individually enabled,
  verify the corresponding subsystem starts and the rest do not.
* REST test: `GET /api/v5/feature_flags` returns the resolved set when
  dashboard is enabled.
* REST test: each disabled feature's endpoints return `403` with
  `FEATURE_DISABLED` from the scope-check layer
  (`emqx_mgmt_auth:check_scopes/3`), distinguishable from
  `UNAUTHORIZED_ROLE` (which an API-key-with-insufficient-scope returns).
* Negative test: `PUT /api/v5/configs/features` (or equivalent) returns
  `403 READ_ONLY`.
* Boot-log test: confirm `feature_gates_resolved` line is emitted once
  per boot with the resolved set.
* Dependency-warning test: `EMQX_FEATURES=metrics` (without
  `dashboard`) emits `feature_dependency_unmet` warning.

## Future Work

* **Decouple `metrics` from `dashboard`.** Bind the Prometheus scrape
  endpoint to its own HTTP listener so the two features become
  independent. Eliminates the only known inter-feature dependency.
  Separate proposal.
* **License-driven feature gating.** The license payload may carry a
  set of permitted features; the resolved enabled-set becomes
  `intersect(EMQX_FEATURES, license.allowed_features)`. Drops in
  without changing the env-var interface. When the intersection
  excludes something the operator requested, log
  `feature_disabled_by_license` at warn level.
* **Finer-grained `data_integration` toggles.** If a deployment shape
  emerges that legitimately wants, say, sources without actions,
  introduce sub-toggles. Until such a shape exists, the current
  bundle-toggle is preferred for its simplicity.
* **Finer-grained API scopes.** Today several features share a single
  scope (`authn` and `authz` both under `?SCOPE_ACCESS_CONTROL`;
  `data_integration` / `message_transformation` / `schema_validation`
  all under `?SCOPE_DATA_INTEGRATION`). The
  `feature -> [minirest_api module]` registry compensates for this at
  the check layer, but if a clean per-feature scope split is wanted,
  new scope macros can be added without disturbing the env-var
  interface or the boot-resolution flow.

## Declined Alternatives

* **HOCON file as the canonical surface, with env var only as
  override.** Rejected because it gives the dashboard a writable
  surface (anything in HOCON the dashboard can mutate via the configs
  API), undermining the governance boundary. The env-var-only
  interface keeps installer policy off the runtime mutation surface
  entirely.
* **One boolean per feature in HOCON
  (`features.dashboard.enabled = true`, etc.).** Rejected because the
  number of features is small enough that a list reads better than ten
  scattered booleans, and the list form encodes uniformly into licenses
  and env vars without per-key fan-out.
* **Acronym blob (`EMQX_FEATURES=DPAm`).** Rejected because the
  compactness gain (a few bytes) is dwarfed by the readability cost.
  Compactness is a non-goal at this scale: the longest legitimate value
  is under 200 bytes, well within env-var and license-claim budgets.
* **Allow mixing preset and explicit list
  (`EMQX_FEATURES=ESSENTIAL,mqtt_extensions`).** Rejected because the
  feature list is short enough to enumerate explicitly, and supporting
  the mixed form doubles parser complexity and complicates the
  `/api/v5/feature_flags` `preset` field semantics.
* **Auto-resolve the `metrics -> dashboard` dependency.** Rejected
  because implicit enablement violates the "no magic" stance the
  proposal otherwise takes; once one such rule exists, the pressure to
  add more grows. A warning at boot is more honest than silent
  enablement. The proper fix is to remove the dependency
  architecturally (future work above).
* **Runtime mutability via dashboard.** Rejected because feature gates
  are deployment policy, not operational settings. Half the candidate
  features (dashboard listener, metrics listener, rule engine ETS
  tables, authn chain registration) have non-trivial teardown
  semantics that are expensive to support correctly. Boot-time
  evaluation sidesteps the issue.
