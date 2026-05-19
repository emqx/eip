# RFC 9431 ACE Authentication for MQTT

## Changelog

* 2026-04-23: @zmstone Initial draft.

## Abstract

This proposal adds support for [RFC 9431](https://www.rfc-editor.org/rfc/rfc9431)
(the MQTT-TLS profile of ACE) as a new authentication backend in EMQX.

Clients connect over standard TLS and present an OAuth 2.0 access token (JWT)
via MQTT v5 Enhanced Authentication with method name `"ace"`. A short
challenge-response exchange during connection setup proves the client holds the
key bound to the token. The token's AIF-MQTT `scope` claim is converted into
per-topic publish/subscribe ACL rules and enforced for the lifetime of the
session. Clients can rotate tokens mid-session via AUTH packets without
dropping the connection.

The initial release covers the `TLS:Anon + MQTT:ace` flow with JWT tokens and
challenge-response proof-of-possession only. CWT tokens, TLS-Exporter PoP, and
the two-connection `authz-info` / TLS-PSK flow are explicitly deferred
(see Declined Alternatives).

## Motivation

EMQX today authenticates clients via password databases, JWT, X.509
certificates, LDAP, and similar backends. Authorization is configured
separately, at the broker, and is typically coarse-grained per-user or
per-client-id.

OAuth 2.0 / ACE shifts this model:

- A dedicated Authorization Server (AS) issues short-lived tokens that carry
  identity, audience, expiry, a proof-of-possession key binding, and
  fine-grained per-topic permissions.
- The broker becomes a Resource Server that only has to validate tokens and
  enforce the scope embedded in them. It no longer needs to own the user
  directory or the per-client ACL.
- Tokens are bound to a key the client must prove it holds, so a stolen token
  alone is not enough to impersonate a device.

For IoT deployments this is a significantly better fit than password-based
auth: devices can be onboarded and permissioned by the AS, tokens can be
rotated without broker-side changes, and per-topic scope keeps the blast
radius of a compromised device small.

The concrete driver is a stakeholder with a fleet of embedded telematics
devices (retrofit and integrated: charging stations, fork lifts, trucks, cars,
medical devices) that span both heavily resource-constrained MCUs and Linux
gateways. They already run an AS that issues JWTs for internal services and
want to extend it to MQTT. They control both their embedded MQTT client and
TLS stack, so MQTT v5 Enhanced Authentication is viable on every device tier.

## Design

### Flow overview

    Client                              AS                           EMQX
      |                                  |                              |
      |-- token request (HTTPS) -------->|                              |
      |<-- JWT (aud, exp, scope, cnf) ---|                              |
      |       (direct, out of band — EMQX is not involved)              |
      |                                                                 |
      |== TLS handshake (server-auth only, client anonymous) =========>|
      |                                                                 |
      |-- CONNECT ------------------------------------------------->    |
      |   Authentication-Method: "ace"                                  |
      |   Authentication-Data:    [Tok-Len:2][Token]                    |
      |                                                                 |
      |<-- AUTH (0x18 Continue) ----------------------------------------|
      |   Authentication-Data: [RS-Nonce:8]                             |
      |                                                                 |
      |-- AUTH (0x18 Continue) ---------------------------------------->|
      |   Authentication-Data: [Client-Nonce:8][HMAC-SHA256:32]         |
      |                                                                 |
      |<-- CONNACK (0x00 Success, scope enforced) ----------------------|
      |                                                                 |
      |-- PUBLISH/SUBSCRIBE (checked against token's scope) --          |
      |                                                                 |
      |-- AUTH (0x19 Re-authenticate) with fresh token ------>          |
      |<-- challenge / response / scope refresh --------------          |

Key properties:

- Single standard TLS listener. No special cipher suites, no separate
  listener for token upload, no two-connection pre-provisioning step.
- The broker never contacts the AS on the connection hot path. JWT signature
  verification is local, using the AS's public key (or a shared secret for
  HMAC).
- The same listener can carry ACE clients and non-ACE clients — the
  authenticator returns `ignore` when `Authentication-Method =/= "ace"`, so
  other authenticators in the chain handle them normally.

### New application: `emqx_auth_ace`

A standalone OTP application under `apps/emqx_auth_ace`, modeled after
`apps/emqx_auth_jwt`. Dependencies: `emqx`, `emqx_auth`, `jose`.

Core modules:

- `emqx_auth_ace_token` — Parse the binary `Authentication-Data` wire format,
  verify the JWT (`jose`), and extract the `aud` / `exp` / `scope` / `cnf`
  claims. Supports `cnf` in `jwk` (inline), `kid` (reference), and `jkt`
  (thumbprint) forms.
- `emqx_auth_ace_pop` — Challenge-response proof-of-possession. Generates an
  8-byte random broker nonce and verifies the client's
  `HMAC-SHA256(PoP-Key, RS-Nonce ‖ Client-Nonce)` response using
  constant-time comparison.
- `emqx_auth_ace_scope` — Convert AIF-MQTT scope (a JSON array of
  `[topic_filter, [permissions]]` pairs) into EMQX ACL rule maps that
  `emqx_authz_client_info` already understands. Permissions are `"pub"`
  and `"sub"`.
- `emqx_authn_ace` — The authenticator provider that plugs into the EMQX auth
  chain. Implements the standard `authenticate/2` callback returning `ignore`
  / `{continue, AuthData, AuthCache}` / `{ok, AuthResult}` / `{error, _}`.

### Auth chain integration

The authenticator registers in the **global** MQTT auth chain
(`mqtt:global`). Per-listener chains are deprecated in EMQX v6. The chain
already dispatches by listener and protocol; `emqx_authn_ace` opts in only
when `auth_method == "ace"` and opts out otherwise.

On a CONNECT with `auth_method = "ace"`:

1. Parse `Authentication-Data`, validate the JWT (signature, `aud`, `exp`,
   algorithm whitelist).
2. Extract the PoP key from the `cnf` claim and the AIF-MQTT scope from the
   `scope` claim.
3. Generate an 8-byte broker nonce, stash `{pop_key, scope, claims, nonce}`
   in `auth_cache`, return `{continue, Nonce, AuthCache}`.

On the subsequent AUTH packet:

1. Verify `HMAC-SHA256(pop_key, broker_nonce ‖ client_nonce)` in constant
   time.
2. Convert the cached scope to ACL rules.
3. Compute `expire_at` from the `exp` claim so the session is terminated (or
   reauthentication is forced) when the token expires.
4. Return `{ok, #{acl => ACL, expire_at => ExpireAt,
   client_attrs => #{<<"ace_token_aud">> => Aud}}}`.

### Non-goal: AS discovery via CONNACK

RFC 9431 allows the broker to signal the location of its Authorization
Server to a client that connects without a usable token, by attaching a
`User-Property` (e.g. `"X-AS" = "https://as.example.com/token"`) to the
failure CONNACK. The client can then fetch a token and retry.

This is intentionally **out of scope** for the initial release. A rejected
CONNECT will carry only the standard reason code (`0x87` Not Authorized);
no AS hint is attached. The assumption is that operators provision their
devices with the AS endpoint out of band — this matches the driving
deployment, where the customer owns both the client and the AS and
pre-configures the pairing.

AS discovery via CONNACK `User-Property` is tracked as future work and can
be added later as a purely additive change (a new optional config field on
the authenticator plus a property on the rejection path); nothing in this
design precludes it.

### Mid-session token refresh

MQTT v5 already defines reauthentication via AUTH with reason code `0x19`.
The existing channel code routes it back into the auth chain, and the same
authenticator handles it by running the flow above against the new token.
On success the client's ACL and expiry are replaced (not merged); on failure
the broker sends DISCONNECT `0x87`.

### Remote token introspection (optional)

For opaque (non-JWT) tokens the authenticator can be configured to POST the
token to the AS's RFC 7662 introspection endpoint. The AS returns the same
shape of claims (`active`, `scope`, `exp`, `aud`, `cnf`). Results are cached
per-token with a configurable TTL to keep the AS off the connection hot path.

### MQTT v3.1.1 fallback (best-effort)

MQTT v3.1.1 has no Enhanced Authentication. RFC 9431 specifies a fallback in
which the username is `"ace" ++ base64url(token)`, and PoP relies on
TLS-Exporter. Because TLS-Exporter PoP is deferred, the v3.1.1 path in the
initial release performs JWT validation and scope enforcement but logs a
warning that cryptographic PoP is not being performed. Operators can decide
whether this is acceptable in their deployment.

### Dashboard and API

The ACE authenticator appears alongside the existing authentication backends
in the Dashboard, REST API, and config file (`authentication` array). No new
auth-chain machinery is needed — this is a new `mechanism = ace` entry.

## Configuration Changes

Add a new `authentication` entry type. Local JWT verification:

    authentication = [
      {
        mechanism = ace
        backend   = built_in

        token_format       = jwt
        verification_key   = "file:///etc/emqx/ace_key.pem"
        allowed_algorithms = ["HS256", "EdDSA"]

        audience      = "mqtt-broker-1"
        authorize_will = true
      }
    ]

Remote introspection (for opaque tokens):

    authentication = [
      {
        mechanism = ace
        backend   = built_in

        token_format                = opaque
        introspection_url           = "https://as.example.com/introspect"
        introspection_client_id     = "broker1"
        introspection_client_secret = "secret"
        introspection_cache_ttl     = "5m"

        audience = "mqtt-broker-1"
      }
    ]

No changes to existing authentication or listener configuration. No new
top-level config keys.

## Backwards Compatibility

The feature is strictly additive:

- A new optional application. Not started unless configured.
- A new `mechanism` value (`ace`). Existing configurations are unaffected.
- No changes to existing authenticator behavior. The chain still returns
  `ignore` past ACE for non-ACE clients.
- No changes to the channel state machine — MQTT v5 Enhanced Authentication
  and reauthentication are already supported.

No migration is required. Deployments that do not configure `mechanism = ace`
behave exactly as before.

## Document Changes

- New authentication guide page: "ACE (RFC 9431)" covering token format,
  `cnf` claim shapes, AIF-MQTT scope, PoP, reauthentication, introspection,
  and example AS integrations.
- Update the authentication overview page to list ACE alongside the existing
  backends.
- Config reference: auto-generated from the HOCON schema
  (`emqx_authn_ace_schema`) plus i18n in `rel/i18n/emqx_authn_ace_schema.hocon`.
- Interop notes for client authors: wire format of `Authentication-Data` in
  CONNECT and AUTH, challenge-response sequencing, v3.1.1 limitations.

## Testing Suggestions

Unit tests (eunit):

- Token parsing: valid / truncated / oversized binaries, header length
  handling.
- JWT validation: good, expired, wrong-`aud`, bad-signature, disallowed
  algorithm.
- `cnf` extraction: `jwk` (symmetric / asymmetric), `kid`, `jkt`, missing.
- Challenge-response: nonce randomness, correct MAC accepted, wrong MAC
  rejected, constant-time comparison.
- Scope conversion: pub-only, sub-only, mixed, wildcards, empty, malformed
  entries.

Integration tests (Common Test) using `emqtt` with custom Enhanced-Auth
handlers:

- Connect with a valid token — CONNACK success, correct ACL applied.
- Connect with expired / wrong-aud / bad-signature / bad-PoP — CONNACK
  `0x87`.
- Publish / subscribe authorized and unauthorized — correct reason codes.
- Will message topic in / out of scope.
- Reauthenticate mid-session — scope replaced, old scope no longer granted.
- Remote introspection against a mock HTTP AS.
- v3.1.1 fallback — auth succeeds with scope, PoP warning logged.
- Non-ACE client on the same listener — authenticator returns `ignore`,
  other chain entries handle it.

Manual interop testing: a signed build (Docker image) is shared with the
stakeholder for joint interop against their real client and AS, starting once
the token-with-PoP and scope-enforcement milestones are stable.

## Future Work

### TLS-PSK with `authz-info` pre-upload (RFC 9431 Part 2)

RFC 9431 also defines a two-connection flow for devices that cannot do
MQTT v5 Enhanced Authentication: an anonymous TLS connection publishes a
token to a reserved `authz-info` topic, disconnects, and then reconnects
using TLS-PSK whose identity is bound to the token's `cnf.kid`. This is
complementary to the MQTT:ace flow, not an alternative — it serves device
tiers that the primary flow cannot.

Not in the initial release because:

- The driving stakeholder controls both their MQTT client and TLS stack and
  can ship MQTT v5 Enhanced Authentication on every device tier, so the
  primary flow covers their deployment end to end.
- The flow requires two listeners (one anonymous, one PSK), a DoS-hardened
  token store on the unauthenticated listener, and a resolution to the "PSK
  identity gap" (OTP's TLS handshake does not currently propagate the PSK
  identity into `conninfo`), which likely needs core EMQX changes.

A complete implementation plan is on the shelf
(`20260409-rfc9431-ace-psk.md`) and can be picked up when a concrete
deployment requires it — e.g. interop with a third-party client that lacks
MQTT v5 Enhanced Authentication, or a hardware tier that cannot afford
multi-step CONNECT.

## Declined Alternatives

### CWT (CBOR Web Token) support

CWT is attractive for cellular-connected devices because CBOR is more compact
than JSON on the wire. It is deferred to a follow-up release: the JWT path
is fully functional, and the stakeholder explicitly accepted JWT-only for
the initial release. Adding CWT later is an additive change — another token
format alongside JWT — and does not invalidate this design.

### TLS-Exporter proof-of-possession (RFC 5705)

TLS-Exporter PoP avoids the extra AUTH round-trip by deriving PoP material
from the TLS session itself. It is attractive for Deep Packet Inspection use
cases that need single-step authentication.

Declined for the initial release because **the TLS library EMQX relies on
does not currently expose a TLS-Exporter interface**. This cannot be worked
around inside EMQX — it requires upstream changes with their own release
cycle. The stakeholder's DPI use case is projected for Q1/27, so we have
runway to pursue the upstream route, but we cannot promise it in the initial
release. Challenge-response PoP provides equivalent cryptographic security;
the only practical difference is one additional round-trip during connection
setup.

### Raw Public Keys (RFC 7250) at the TLS layer

RPK would be a lightweight alternative to X.509 for constrained devices.
The underlying TLS library does not support RPK, only X.509. As with
TLS-Exporter this is an upstream limitation outside EMQX's control. It is
not required by this EIP: authentication happens at the MQTT layer via the
access token, and TLS provides server authentication only.

### AS discovery via CONNACK `User-Property`

RFC 9431 permits the broker to advertise its AS endpoint on a rejected
CONNECT, letting a client auto-discover where to obtain a token. Deferred
for the initial release — see the "Non-goal: AS discovery via CONNACK"
subsection in Design. Recorded here so a future EIP or follow-up release
can pick it up without re-litigating the decision.

### Per-listener authenticator registration

Per-listener auth chains are deprecated in EMQX v6. This EIP registers the
ACE authenticator in the global `mqtt:global` chain; the chain already
dispatches by listener and protocol, and `ignore` lets ACE coexist with
other authenticators on the same listener.
