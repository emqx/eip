# Support environment variable `EMQX_SECURITY_PROFILE`

## Changelog

* 2026-02-28: @zmstone Initial draft
* 2026-03-02: @zmstone Replace ACL catch-all design with profile-aware `authorization.no_match`
* 2026-03-02: @zmstone Adjust rollout plan: keep 6.2 defaults for backward compatibility, switch defaults in v7
* 2026-05-13: @id Merge ideas from #94: MQTT/WS listener bind in `hardened`, dashboard rejection hint, tighter v7 default ACL rules
* 2026-05-19: @savonarola Use new `who()` condition in `acl.conf` instead of `authorization.no_match=profile` for simplifying the transition. Target 6.3 release for the changes.
* 2026-05-26: @savonarola Use `deny` for failures in external authorization backends.
* 2026-06-05: @savonarola Add ACL checks for Management API induced subscriptions and publishes.
* 2026-06-05: @savonarola Use fail-closed authentication behavior for authenticator errors in `hardened`.
* 2026-06-11: @savonarola Make JWT JWKS transport secure by default in `hardened`.

## Abstract

This proposal introduces a security profile environment variable,
`EMQX_SECURITY_PROFILE`, to make bootstrap security posture explicit and
controllable. It defines two modes: `legacy` and `hardened`.

`legacy` keeps current permissive behavior for EMQX 6.2 compatibility.
`hardened` enforces secure startup and access defaults, including 
* rejecting
known default Erlang cookies;
* rejecting dashboard login when `public` is the
admin password;
* denying anonymous MQTT login when authentication chain is
empty;
* denying authentication on security-relevant authenticator errors instead of
falling through to potentially weaker authenticators;
* requiring authenticated transport by default when fetching JWT JWKS signing
keys;
* enabling ACL checks by default for Management API operations that force MQTT clients to subscribe or publish.

For authorization fallback, this proposal extends `acl.conf`'s syntax.
It adds a new `who()` condition: `{security_profile, legacy| hardened}` which is true when the
configured profile matches.

Rollout is versioned for compatibility:

* EMQX 6.2 defaults to `legacy`, and
  updates `{allow, all}` to `{allow, {security_profile, legacy}}` in default `acl.conf`.
* EMQX 6.3 defaults to `hardened`. The default `acl.conf` retains unchainged: with `{allow, {security_profile, legacy}}` as the final rule.

## Motivation

Several insecure defaults are convenient in bootstrap environments but risky in
production when accidentally left enabled. Today, these behaviors are split
across components and are not governed by one explicit security posture switch.

We need a single environment-level control that:

* keeps compatibility for EMQX 6.2 users;
* enables hardened operation with clear enforcement;
* supports a planned default transition in EMQX 6.3;
* is visible and auditable in deployment manifests.

## Design

### Environment variable

Introduce `EMQX_SECURITY_PROFILE` with two supported values:

* `legacy`
* `hardened`

### Release default policy

Release defaults:

| Release | Default `EMQX_SECURITY_PROFILE` (when unset) | Default `acl.conf` catch-all |
| --- | --- | --- |
| 6.2 | `legacy` | Update to `{allow, {security_profile, legacy}}.` |
| 6.3 | `hardened` | Retain `{allow, {security_profile, legacy}}.` |

Invalid values should fail fast at boot with a clear error message listing
supported values.

### Behavioral requirements

| Behavior | `legacy` | `hardened` |
| --- | --- | --- |
| Erlang cookie default values (`emqxsecretcookie`, `emqx50elixir`) | Allowed | Boot fails if used |
| HTTP (not HTTPS) listener default bind | `0.0.0.0` | `127.0.0.1` |
| MQTT/WS listener default bind (`tcp.default`, `ssl.default`, `ws.default`, `wss.default`) | `0.0.0.0` | `127.0.0.1` |
| Dashboard admin password `public` | Login allowed | Login denied until password is changed |
| MQTT anonymous login when auth chain is empty | Allowed | Denied |
| Authenticator backend, verification, precondition, or stored-record errors | May fall through to later authenticators | Denied when security-relevant for the client |
| JWT JWKS signing-key transport defaults | Existing outbound HTTP/TLS defaults | HTTPS with TLS peer verification required by default |
| Default `check_acl` for Management API induced client subscriptions and publishes | `false` | `true` |

### Dashboard login rejection message

When `hardened` blocks login because the admin password is still `public`, the
dashboard should return a clear remediation hint, for example:

```
Default admin password must be changed before login is allowed.
* Run: emqx ctl admins passwd admin <a-strong-password>
* Or configure: dashboard.default_password = "<a-strong-password>"
```

### ACL file behavior

For backward compatibility in 6.2, updates `acl.conf` to replace the default catch-all
with a profile-aware rule: `{allow, {security_profile, legacy}}.` rule.
By default, the profile is legacy, so this preserves existing behavior.

In 6.3, default `acl.conf` retains the default profile-aware rule `{allow, {security_profile, legacy}}.`
When the default profile is hardened, this rule stops triggering, and the
decision falls back to `authorization.no_match`.

### ACL behavior on external backend errors

Currently, when an authz backend fails (e.g., HTTP or PostgreSQL is down), EMQX  
treats the failure as `nomatch`, moving to the next authz source or to the default nomatch.  
This behaviour may lead to unexpected privilege escalation if subsequent sources are more  
permissive. Also, this behaviour may be abused: an attacker may purposely issue numerous  
actions requiring authorization to trigger backend failures.

With the `hardened` profile, authz changes the behaviour.  
On backend failure because of unavailability or misconfiguration, EMQX returns `deny` to block any access.

### Authentication behavior on authenticator errors

Currently, some authenticators and shared authentication-chain paths convert
security-relevant failures to `ignore` or provider failure and continue to later
authenticators. Examples include external backend errors, unexpected backend
results, verification failures for credentials that matched an authenticator's
scope, precondition-render failures caused by malformed or missing client data,
and malformed stored credential records. In a chain with a weaker fallback, this
can let a failed stronger authenticator fall through to a less strict one.

With the `hardened` profile, authentication must fail closed for
security-relevant authenticator failures. If an authenticator is applicable to a
client and encounters a backend error, malformed backend result, unsupported
outcome, credential verification error, precondition-render error, or malformed
stored credential data, the chain must deny authentication instead of treating
the result as no-match and continuing to later authenticators.

The `legacy` profile preserves existing chain behavior for compatibility, where
such failures may be treated as no-match and the chain may continue to later
authenticators.

### JWT JWKS transport defaults

JWT authenticators that use JWKS trust the fetched key set as the root for token
signature verification. If the JWKS document is fetched over plain HTTP or over
TLS without peer verification, an on-path attacker can substitute signing keys
and make EMQX accept attacker-signed JWTs.

With the `hardened` profile, JWKS fetching must use authenticated transport by
default:

* JWKS endpoints must use HTTPS unless the operator explicitly opts out.
* TLS peer verification must be enabled by default for JWKS HTTP clients.

The `legacy` profile preserves existing outbound HTTP/TLS defaults for
compatibility.

### Management API induced subscribe/publish ACL checks

Some administrator-level Management API endpoints can force an online MQTT client
to subscribe to a topic or publish a message. Without an explicit ACL check, the
API can induce an action that the same client would be denied from performing
through the normal MQTT `SUBSCRIBE` or `PUBLISH` path.

Add a boolean `check_acl` option to the Management API requests that induce
client subscribe or publish operations. For example:

```json
{
  "topic": "example/topic",
  "qos": 0,
  "check_acl": true
}
```

When `check_acl` is enabled, Management API induced subscribe and publish
operations must run the same authorization checks as the corresponding MQTT
operation, using the target MQTT client's identity and the induced action/topic.
If authorization denies the action, the Management API operation must fail and
the client must not be subscribed or used to publish the message.

If `check_acl` is omitted from the request, its default depends on
`EMQX_SECURITY_PROFILE`:

| Profile | Default request `check_acl` |
| --- | --- |
| `legacy` | `false` |
| `hardened` | `true` |

In `legacy`, the default preserves existing behavior: administrator-level API
callers can induce client subscribe/publish operations without checking the
target client's ACL. In `hardened`, the default closes this privilege-escalation
path unless the API caller explicitly sets `check_acl` to `false` in the request.

### Implementation notes

* Resolve profile once at boot and make it available to relevant subsystems.
* Add validation with clear startup errors for profile and hardened checks.
* Ensure logs clearly show active profile and any compatibility behavior in
  `legacy`.
* Keep behavior deterministic across node restart and cluster join.
* For authentication chains in `hardened`, distinguish true authenticator
  no-match from security-relevant provider failure. Provider failure must stop
  the chain with authentication denied when the authenticator was applicable to
  the client.
* For JWT JWKS in `hardened`, derive secure defaults before starting the JWKS
  client: require HTTPS, set TLS verification to `verify_peer`.
* For management API publish/subscribe:
  * Extend `emqx:publish/1` with opts which go to the underlying `emqx_broker:publish/2` opts. Add a new option `check_acl => boolean()`.
  * Extend `emqx_management_proto_v5:subscribe/3` to receive opts; extend channels to support `{subscribe, TopicFilters, Options}`. Add a new option `check_acl => boolean()`.

## Configuration Changes

Profile is configured through environment variable and release defaults:

```bash
# 6.2 default when unset
EMQX_SECURITY_PROFILE=legacy
```

or:

```bash
# 6.3 default when unset
EMQX_SECURITY_PROFILE=hardened
```

Default `acl.conf` changes:

```erlang
%% 6.2 and 6.3 default
{allow, {security_profile, legacy}}.
```

## Backwards Compatibility

For EMQX 6.2, defaulting to `legacy` preserves current behavior when users do
not set the variable, since `{allow, {security_profile, legacy}}.` evaluates to `allow` in this case,
which is equivalent to the previous `{allow, all}.` default.

For EMQX 6.3, defaulting to `hardened` is a deliberate security tightening and update
guidance should recommend explicitly setting `EMQX_SECURITY_PROFILE=legacy`
during transition and then remediating to move to `hardened`.

When the request omits `check_acl`, Management API induced subscribe/publish ACL
checks are disabled by default in `legacy`, preserving the existing EMQX 6.2
administrator-level API behavior.

Authenticator error handling remains compatible in `legacy`: provider failures
and `ignore` results can continue to later authenticators as before.

JWT JWKS transport remains compatible in `legacy`: existing HTTP and TLS defaults
are preserved unless the operator opts into hardened behavior.

No MQTT wire protocol changes are introduced.

## Document Changes

Update operational docs to include:

* profile semantics (`legacy` vs `hardened`);
* release default timeline (6.2 and 6.3), including
  `{allow, {security_profile, legacy}}` defaults;
* migration guidance for 6.3 default hardening;
* examples for containerized and package-based deployments.

## Testing Suggestions

Add automated coverage for both profile values:

* boot succeeds/fails against each Erlang cookie case;
* dashboard login acceptance/rejection with `public` password;
* MQTT anonymous access behavior when auth chain is empty/non-empty;
* HTTP (not HTTPS) listener default bind address behavior in `legacy` (`0.0.0.0`) and
  `hardened` (`127.0.0.1`);
* MQTT/WS listener default bind address behavior in `legacy` (`0.0.0.0`) and
  `hardened` (`127.0.0.1`);
* 6.3 default `acl.conf` denies `$SYS/#`, `#`, and `+/#` subscriptions for
  non-dashboard, non-localhost clients;
* default behavior in 6.2:
  `EMQX_SECURITY_PROFILE=legacy` (unset), `authorization.no_match=deny`, and
  default `acl.conf` becomes `{allow, {security_profile, legacy}}.`;
* default behavior in 6.3:
  `EMQX_SECURITY_PROFILE=hardened` (unset) and default `acl.conf` remains `{allow, {security_profile, legacy}}.`.
* authentication chain behavior in `hardened`: backend errors, malformed backend
  results, unsupported outcomes, verification errors, precondition-render
  errors, and malformed stored credential records deny authentication instead of
  falling through to a weaker later authenticator.
* authentication chain behavior in `legacy`: existing fall-through behavior is
  preserved for compatibility.
* JWT JWKS transport behavior in `hardened`: HTTPS and TLS peer verification are
  required by default, and insecure transport requires an explicit override or is
  rejected by validation.
* JWT JWKS transport behavior in `legacy`: existing outbound HTTP/TLS defaults
  are preserved.
* Management API induced subscribe/publish behavior with `check_acl=true`:
  an API-induced operation is denied when the target MQTT client's ACL denies the
  corresponding MQTT `SUBSCRIBE` or `PUBLISH` action.
* Management API induced subscribe/publish behavior with `check_acl=false`:
  existing administrator-level API behavior is preserved.
* Management API induced subscribe/publish behavior when `check_acl` is omitted:
  it defaults to `false` in `legacy` and `true` in `hardened`.

Include integration tests to verify environment-variable-driven behavior in real
startup flows.

## Declined Alternatives

* Enforce hardened behavior unconditionally in 6.2.
* Keep ACL `{check, "$EMQX_SECURITY_PROFILE"}` as the catch-all mechanism.
* Remove default `{allow, all}.` from 6.2 immediately.
* For Management subscribe/publish API, enforce ACL checks by config settings (instead of request argument). This just limits conveniency of UX, and does not give any additional guarantees.
