# Support environment variable `EMQX_SECURITY_PROFILE`

## Changelog

* 2026-02-28: @zmstone Initial draft
* 2026-03-02: @zmstone Replace ACL catch-all design with profile-aware `authorization.no_match`
* 2026-03-02: @zmstone Adjust rollout plan: keep 6.2 defaults for backward compatibility, switch defaults in v7
* 2026-05-13: @id Merge ideas from #94: MQTT/WS listener bind in `hardened`, dashboard rejection hint, tighter v7 default ACL rules
* 2026-05-19: @savonarola Use new `who()` condition in `acl.conf` instead of `authorization.no_match=profile` for simplifying the transition.

## Abstract

This proposal introduces a security profile environment variable,
`EMQX_SECURITY_PROFILE`, to make bootstrap security posture explicit and
controllable. It defines two modes: `legacy` and `hardened`.

`legacy` keeps current permissive behavior for EMQX 6.2 compatibility.
`hardened` enforces secure startup and access defaults, including rejecting
known default Erlang cookies, rejecting dashboard login when `public` is the
admin password, and denying anonymous MQTT login when authentication chain is
empty.

For authorization fallback, this proposal extends `acl.conf`'s syntax.
It adds a new `who()` condition: `{security_profile, legacy| hardened}` which is true when the
configured profile matches.

* `legacy` => act as `allow`
* `hardened` => act as `deny`

Rollout is versioned for compatibility:

* EMQX 6.2 defaults to `legacy`, and
  updates `{allow, all}` to `{allow, {security_profile, legacy}}` in default `acl.conf`.
* EMQX 7 defaults to `hardened`.

## Motivation

Several insecure defaults are convenient in bootstrap environments but risky in
production when accidentally left enabled. Today, these behaviors are split
across components and are not governed by one explicit security posture switch.

We need a single environment-level control that:

* keeps compatibility for EMQX 6.2 users;
* enables hardened operation with clear enforcement;
* supports a planned default transition in EMQX 7;
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
| 7 | `hardened` | Update to `{allow, {security_profile, legacy}}.` |

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

In 7, default `acl.conf` retains the default profile-aware rule `{allow, {security_profile, legacy}}.`
When the default profile is hardened, this rule stops triggering, and the
decision falls back to `authorization.no_match`.

### Implementation notes

* Resolve profile once at boot and make it available to relevant subsystems.
* Add validation with clear startup errors for profile and hardened checks.
* Ensure logs clearly show active profile and any compatibility behavior in
  `legacy`.
* Keep behavior deterministic across node restart and cluster join.

## Configuration Changes

Profile is configured through environment variable and release defaults:

```bash
# 6.2 default when unset
EMQX_SECURITY_PROFILE=legacy
```

or:

```bash
# 7 default when unset
EMQX_SECURITY_PROFILE=hardened
```

Default `acl.conf` changes:

```
%% 6.2 default
{allow, all}.
```

```erlang
%% 6.3 and 7 default
{allow, {security_profile, legacy}}.
```

## Backwards Compatibility

For EMQX 6.2, defaulting to `legacy` preserves current behavior when users do
not set the variable, since `{allow, {security_profile, legacy}}.` evaluates to `allow` in this case,
which is equivalent to the previous `{allow, all}.` default.

For EMQX 7, defaulting to `hardened` is a deliberate security tightening and update
guidance should recommend explicitly setting `EMQX_SECURITY_PROFILE=legacy`
during transition and then remediating to move to `hardened`.

No wire protocol changes are introduced.

## Document Changes

Update operational docs to include:

* profile semantics (`legacy` vs `hardened`);
* release default timeline (6.2 and 7+), including
  `{allow, {security_profile, legacy}}` defaults;
* migration guidance for v7 default hardening;
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
* v7 default `acl.conf` denies `$SYS/#`, `#`, and `+/#` subscriptions for
  non-dashboard, non-localhost clients;
* explicit `authorization.no_match=allow` and `deny` behavior remains unchanged;
* default behavior in 6.2:
  `EMQX_SECURITY_PROFILE=legacy` (unset), `authorization.no_match=deny`, and
  default `acl.conf` keeps `{allow, all}.`;
* default behavior in 7:
  `EMQX_SECURITY_PROFILE=hardened` (unset),
  `authorization.no_match=profile`, and default `acl.conf` removes
  `{allow, all}.`.

Include integration tests to verify environment-variable-driven behavior in real
startup flows.

## Declined Alternatives

* Enforce hardened behavior unconditionally in 6.2.
* Keep ACL `{check, "$EMQX_SECURITY_PROFILE"}` as the catch-all mechanism.
* Remove default `{allow, all}.` from 6.2 immediately.
