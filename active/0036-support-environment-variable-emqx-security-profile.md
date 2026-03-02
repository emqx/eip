# Support environment variable `EMQX_SECURITY_PROFILE`

## Changelog

* 2026-02-28: @zmstone Initial draft
* 2026-03-02: @zmstone Replace ACL catch-all design with profile-aware `authorization.no_match`
* 2026-03-02: @zmstone Adjust rollout plan: keep 6.2 defaults for backward compatibility, switch defaults in v7

## Abstract

This proposal introduces a security profile environment variable,
`EMQX_SECURITY_PROFILE`, to make bootstrap security posture explicit and
controllable. It defines two modes: `legacy` and `hardened`.

`legacy` keeps current permissive behavior for EMQX 6.2 compatibility.
`hardened` enforces secure startup and access defaults, including rejecting
known default Erlang cookies, rejecting dashboard login when `public` is the
admin password, and denying anonymous MQTT login when authentication chain is
empty.

For authorization fallback, this proposal extends `authorization.no_match`
(currently `allow | deny`) with a new enum value `profile` (recommended symbol).
When `authorization.no_match = profile`, behavior is profile-aware:

* `legacy` => act as `allow`
* `hardened` => act as `deny`

Rollout is versioned for compatibility:

* EMQX 6.2 defaults to `legacy`, keeps `authorization.no_match = deny`, and
  keeps `{allow, all}.` in default `acl.conf`.
* EMQX 7 defaults to `hardened` and changes default
  `authorization.no_match` from `deny` to `profile`.

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

| Release | Default `EMQX_SECURITY_PROFILE` (when unset) | Default `authorization.no_match` | Default `acl.conf` catch-all |
| --- | --- | --- | --- |
| 6.2 | `legacy` | `deny` | Keep `{allow, all}.` |
| 7 | `hardened` | `profile` | Remove default `{allow, all}.` |

Invalid values should fail fast at boot with a clear error message listing
supported values.

### Behavioral requirements

| Behavior | `legacy` | `hardened` |
| --- | --- | --- |
| Erlang cookie default values (`emqxsecretcookie`, `emqx50elixir`) | Allowed | Boot fails if used |
| HTTP (not HTTPS) listener default bind | `0.0.0.0` | `127.0.0.1` |
| Dashboard admin password `public` | Login allowed | Login denied until password is changed |
| MQTT anonymous login when auth chain is empty | Allowed | Denied |
| `authorization.no_match = profile` effective result | `allow` | `deny` |

### Authorization `no_match` extension

Current enum values:

* `allow`
* `deny`

Proposed new enum value:

* `profile` (recommended symbol)

Semantics when `authorization.no_match = profile`:

* if `EMQX_SECURITY_PROFILE=legacy`, fallback decision is `allow`;
* if `EMQX_SECURITY_PROFILE=hardened`, fallback decision is `deny`.

If user explicitly sets `authorization.no_match=allow` or `deny`, existing
behavior is preserved and profile-based mapping is not used.

Default value by release:

* 6.2 default: `authorization.no_match = deny`.
* 7 default: `authorization.no_match = profile`.

### ACL file behavior

For backward compatibility in 6.2, default `acl.conf` keeps the final
`{allow, all}.` rule.

In 7, default `acl.conf` removes the final `{allow, all}.` catch-all rule.

If no ACL rule matches, final decision comes from `authorization.no_match`.

### Implementation notes

* Resolve profile once at boot and make it available to relevant subsystems.
* Add validation with clear startup errors for profile and hardened checks.
* Extend `authorization.no_match` schema/parser to include `profile`.
* Ensure logs clearly show active profile and any compatibility behavior in
  `legacy`.
* Keep behavior deterministic across node restart and cluster join.

## Configuration Changes

HOCON schema change:

* extend `authorization.no_match` enum from `allow | deny` to
  `allow | deny | profile`.

Default values by release:

```hocon
# 6.2 default
authorization {
  no_match = deny
}
```

```hocon
# 7 default
authorization {
  no_match = profile
}
```

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

## Backwards Compatibility

For EMQX 6.2, defaulting to `legacy` preserves current behavior when users do
not set the variable. Keeping default `authorization.no_match = deny` and
default `{allow, all}.` in `acl.conf` also preserves existing behavior.

For EMQX 7, defaulting to `hardened` is a deliberate security tightening and
changing `authorization.no_match` default from `deny` to `profile` introduces
profile-aware fallback behavior. Migration guidance should recommend explicitly
setting `EMQX_SECURITY_PROFILE=legacy` during transition and then remediating to
move to `hardened`.

No wire protocol changes are introduced.

## Document Changes

Update operational docs to include:

* profile semantics (`legacy` vs `hardened`);
* release default timeline (6.2 and 7+), including
  `authorization.no_match` defaults;
* migration guidance for v7 default hardening;
* examples for containerized and package-based deployments.

## Testing Suggestions

Add automated coverage for both profile values:

* boot succeeds/fails against each Erlang cookie case;
* dashboard login acceptance/rejection with `public` password;
* MQTT anonymous access behavior when auth chain is empty/non-empty;
* HTTP (not HTTPS) listener default bind address behavior in `legacy` (`0.0.0.0`) and
  `hardened` (`127.0.0.1`);
* `authorization.no_match=profile` resolves to `allow` in `legacy` and `deny`
  in `hardened`;
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
