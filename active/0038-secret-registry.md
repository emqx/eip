# Secret registry for data-integration templates

## Changelog

* 2026-05-21: @zmstone Initial draft

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
* **Audit / governance**: an operator who needs to configure a new
  bridge today must know the value of the shared API token. There is
  no way to grant "you can reference the production token" without
  also granting "you can read its value."
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
   name        :: binary(),      %% primary key, ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$
   value       :: binary(),      %% raw bytes, UTF-8 well-formed
   description :: binary(),      %% operator-supplied free-form note, optional
   created_at  :: integer(),     %% monotonic millis
   updated_at  :: integer()      %% monotonic millis
}
```

Constraints:

* `name` matches `^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$` (same alphabet as
  `emqx_utils:is_restricted_str/1` used for client-attr names). 63-byte
  cap. Names are case-sensitive.
* `value` is at most 16 KiB. Stored as-is after a UTF-8 well-formedness
  check. PEM-encoded private keys (newline-containing) are permitted.
* `description` is at most 512 bytes, UTF-8, control-character-free
  except whitespace.
* The total number of secrets in the cluster is capped at 1024 (configurable;
  see Configuration Changes).

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
  Creates a new secret. Errors on name collision.
* `GET /api/v5/secrets`
  Returns a paginated list of `{ name, description, created_at,
  updated_at }`. **The value is never returned.**
* `GET /api/v5/secrets/{name}`
  Returns `{ name, description, created_at, updated_at }`. **The
  value is never returned.**
* `PUT /api/v5/secrets/{name}`
  body: `{ "value": "...", "description": "..." }`
  Overwrites the existing secret. This is the rotation path.
* `DELETE /api/v5/secrets/{name}`
  Removes the secret. The renderer's strict-fail behavior applies to
  any subsequent template render that references the deleted name.

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
return the value to an operator with sufficient privilege. Rejected:
once read-back exists, the boundary "operator can configure bridges
but does not know the secret value" disappears. Read-back also makes
the audit story muddier -- "did this operator read this secret"
becomes a question whose answer must be logged, where today the
answer is uniformly "no." Rotation is the rotation path; if an
operator needs the value to put it somewhere else, they should
store it themselves.

### Allowing the placeholder in MQTT topics and payloads

Considered: permit `$secret{...}` in rule republish topic / payload
templates. Rejected: no compelling use case (the placeholder is for
*outbound* credentials to backends, not for shaping MQTT-protocol
content), and significant downside (audit logs of published
messages would either need to special-case secrets or risk leaking).
Easier to reject at config-validation time than to retrofit
redaction across the MQTT logging path.
