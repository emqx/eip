# Support environment variable `EMQX_SECURITY_PROFILE`

## Changelog

* 2026-02-28: @zmstone Initial draft

## Abstract

This proposal introduces a security profile environment variable,
`EMQX_SECURITY_PROFILE`, to make bootstrap security posture explicit and
controllable. It defines two modes: `legacy` and `hardened`.

`legacy` keeps current permissive behavior for EMQX 6.2 compatibility.
`hardened` enforces secure startup and access defaults, including rejecting
known default Erlang cookies, rejecting dashboard login when `public` is the
admin password, and denying anonymous MQTT login when authentication chain is
empty.

For ACL, this proposal replaces the current last rule `{allow, all}.` with
`{check, "$EMQX_SECURITY_PROFILE"}.` and does not use `{allow, all}.` as the
last rule even when profile is `legacy`.

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

When `EMQX_SECURITY_PROFILE` is unset:

* EMQX 6.2 defaults to `legacy`.
* EMQX 7 defaults to `hardened`.

Invalid values should fail fast at boot with a clear error message listing
supported values.

### Behavioral requirements

#### `legacy`

Keep compatibility behavior:

* Allow using default Erlang cookie (known cookies are `emqxsecretcookie` and
  `emqx50elixir`).
* Allow admin user to login with `public` password.
* Allow anonymous login for MQTT clients.

#### `hardened`

Enforce secure behavior:

* Do not boot if Erlang cookie is any known default value
  (`emqxsecretcookie` or `emqx50elixir`).
* Do not allow dashboard login if `public` is the password; password must be
  changed first via `emqx ctl`.
  Or the admin account is bootstrapped with non-public password.
* Do not allow anonymous login for MQTT clients; if authentication chain is
  empty, deny access.

### ACL final rule

Replace the current last rule `{allow, all}.` with:

```erlang
{check, "$EMQX_SECURITY_PROFILE"}.
```

This replacement applies for all profiles. `legacy` must not keep
`{allow, all}.` as the final rule in `acl.conf`.

### Implementation notes

* Resolve profile once at boot and make it available to relevant subsystems.
* Add validation with clear startup errors for profile and hardened checks.
* Ensure logs clearly show active profile and any compatibility behavior in
  `legacy`.
* Keep behavior deterministic across node restart and cluster join.

## Configuration Changes

No HOCON schema changes are required for initial rollout.

The feature is configured through environment variable:

```bash
EMQX_SECURITY_PROFILE=legacy
```

or:

```bash
EMQX_SECURITY_PROFILE=hardened
```

## Backwards Compatibility

For EMQX 6.2, defaulting to `legacy` preserves current behavior when users do
not set the variable.

For EMQX 7, defaulting to `hardened` is a deliberate security tightening and
may break deployments relying on permissive defaults. Migration guidance should
recommend explicitly setting `EMQX_SECURITY_PROFILE=legacy` during transition
and then remediating to move to `hardened`.

No wire protocol changes are introduced.

## Document Changes

Update operational docs to include:

* profile semantics (`legacy` vs `hardened`);
* release default timeline (6.2 and 7+);
* migration guidance for v7 default hardening;
* examples for containerized and package-based deployments.

## Testing Suggestions

Add automated coverage for both profile values:

* boot succeeds/fails against each Erlang cookie case;
* dashboard login acceptance/rejection with `public` password;
* MQTT anonymous access behavior when auth chain is empty/non-empty;
* ACL final rule behavior using `{check, "$EMQX_SECURITY_PROFILE"}` in both
  `legacy` and `hardened`;
* boot default behavior in 6.2 (`legacy`) and 7 (`hardened`) when env var is
  unset.

Include integration tests to verify environment-variable-driven behavior in real
startup flows.

## Declined Alternatives

* Enforce hardened behavior unconditionally in 6.2.
