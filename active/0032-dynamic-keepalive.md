# Dynamic Per-Client Keepalive Adjustment

## Changelog

* 2026-01-24: Initial draft

## Abstract

This proposal introduces a server-side mechanism that allows dynamic adjustment of the keepalive tolerance per client, without forcing client-side reconnection or protocol changes. This feature enables MQTT clients to operate efficiently in both active and sleep states, addressing power consumption concerns in vehicle networking and mobile device scenarios.

## Motivation

In vehicle networking and mobile device scenarios, MQTT clients need to switch between an **active state** (high-frequency communication) and a **sleep state** (low-power long connection maintenance).

A fixed MQTT keepalive interval cannot simultaneously satisfy:
- Low power consumption during long idle periods (e.g. vehicle parked, engine off)
- Fast detection of disconnection during active usage

In typical vehicle scenarios, MQTT clients run on a T-Box powered by the vehicle battery. When the vehicle is parked, excessive heartbeat traffic can lead to significant battery drain. However, the MQTT connection must remain alive so that remote commands from users can still be delivered at any time.

Due to NAT aging in mobile networks (4G/5G), MQTT connections must periodically send traffic within the NAT timeout window (typically 2–5 minutes) to prevent silent disconnection.

This feature introduces a **server-side mechanism** that allows dynamic adjustment of the keepalive tolerance **per client**, without forcing client-side reconnection or protocol changes.

## Design

### High-Level Design

Introduce a **server-side keepalive override interface** that allows the broker to dynamically adjust the keepalive timeout used for session liveness checks, without changing the negotiated MQTT keepalive value or disconnecting the client.

Overrides are applied **in-memory** to active sessions only.

### Control Interface

#### System Topic Prefix

Use a generic system topic prefix for server-side option updates:

```
$SETOPTS
```

#### Keepalive Topics

Single client update (applies to the publishing client):

```
$SETOPTS/mqtt/keepalive
```

Batch update (multiple clients in one message):

```
$SETOPTS/mqtt/keepalive-bulk
```

#### Payload Format

##### Mode 1: Single Device (String Integer)

Payload is a string that parses to a non-negative integer keepalive interval in seconds.

Example payload:

```
300
```

##### Mode 2: Batch Devices (Array)

Payload is a JSON array of objects.

```json
[
  {
    "clientid": "car_device_001",
    "keepalive": 300
  },
  {
    "clientid": "car_device_002",
    "keepalive": 60
  }
]
```

#### Field Definitions

- `clientid` (string, required, bulk only): Target MQTT client identifier
- `keepalive` (integer, required, bulk only): New keepalive interval in seconds
- Single device payload is a string integer; the client id is derived from the publishing client's session.

The broker computes the effective timeout as:

```
keepalive * 1.5
```

### Server-Side Processing Flow

1. **Message Reception**
   - Broker receives a PUBLISH message on
     - `$SETOPTS/mqtt/keepalive` for single updates (applies to the publishing client), or
     - `$SETOPTS/mqtt/keepalive-bulk` for batch updates
   - Payload is parsed based on the topic type

2. **Payload Normalization**
   - For single updates, parse payload as a string integer and use the `clientid` of the publishing client
   - For batch updates, parse payload as a JSON array of objects
   - Invalid formats cause the message to be rejected

3. **Per-Client Processing**
   For each item in the normalized list:
   - Validate presence and type of `clientid` and `keepalive`
   - Look up the active MQTT session (in live connections table) by `clientid`

4. **Session Handling**
   - If session exists:
     - Send a message to the process which should get handled by `emqx_channel` module
     - Recalculate keepalive timeout (according to the `keepalive_multiplier` config)
     - Update the session's keepalive monitoring timer:
       - Read the current timer to see how much time remaining
       - Calculate the remaining timeout to start a new timer
       - If remaining < 0, emit the timeout signal immediately
     - Apply the change without disconnecting the client
   - If session does not exist:
     - Log at debug level for the operation as failed for this client
     - Do not create a new session or persist configuration

5. **Compatibility Guarantee**
   - If the client continues to send heartbeats at a **shorter interval** than the updated threshold, the connection must remain valid
   - Server-side changes only **relax or tighten the tolerance window** and must never force protocol-level renegotiation

### Key Design Constraints

- **No connection interruption** during keepalive updates
- **No protocol changes** visible to MQTT clients
- **Thread-safe / concurrent-safe** session updates
- **Minimal performance impact** on session timer management
- Must not break existing keepalive semantics for unaffected clients

### Scope

#### In Scope

- Dynamically adjust server-side keepalive timeout thresholds for specific clients
- Support both single-device and batch-device updates
- Use MQTT system topic for control-plane commands
- Hot update of session timers without disconnecting clients
- Backward compatible with existing MQTT clients

#### Out of Scope

- Client-side keepalive interval modification
- Persistent storage of keepalive overrides across broker restarts
- Dashboard / UI integration
- Authentication / authorization redesign for system topics

## Configuration Changes

No configuration changes are required. The feature uses existing system topic infrastructure and session management mechanisms.

## Backwards Compatibility

This feature is fully backward compatible:
- Existing MQTT clients continue to work without any changes
- The keepalive value negotiated during MQTT CONNECT remains unchanged
- Only the server-side timeout tolerance is adjusted dynamically
- Clients that do not receive keepalive overrides continue with default behavior

## Document Changes

- Document the new system topics `$SETOPTS/mqtt/keepalive` and `$SETOPTS/mqtt/keepalive-bulk`
- Document the payload formats for single and batch updates
- Document the behavior when sessions do not exist
- Document that overrides are in-memory only and lost on broker restart
- Add examples for vehicle networking use cases

## Testing Suggestions

- Test single client keepalive updates via `$SETOPTS/mqtt/keepalive` (publishing client updates its own keepalive)
- Test batch client keepalive updates via `$SETOPTS/mqtt/keepalive-bulk`
- Test that active sessions update keepalive timeout without disconnection
- Test that clients with shorter heartbeat intervals remain connected
- Test invalid payload formats are rejected gracefully
- Test that non-existent client IDs are handled without errors
- Test concurrent updates to the same client
- Test that default keepalive behavior is unaffected for normal clients
- Verify no regression in existing keepalive behavior

## Risks & Considerations

- Batch updates should not block the broker event loop
- System topic access should be restricted to trusted publishers
- Memory-only overrides will be lost on broker restart (by design)

## Declined Alternatives

- Use `$keepalive/update` topic and support only bulk requests.
  This was rejected because:
  - We want to avoid introducing root-level system topics for one specific use case
  - The `$SETOPTS/` prefix was chosen for future extensibility, e.g. `$SETOPTS/tcp/keepalive/...`
  - The separation of single and bulk topics allows finer control of ACL. For example, one may allow any MQTT client to change its own keepalive interval via the single-client topic, but require a special ACL rule to allow specific clients to publish bulk requests


