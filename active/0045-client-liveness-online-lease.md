# Client Liveness Online Lease Events

## Changelog

* 2026-08-20: Initial draft.

## Abstract

This EIP proposes an event stream that exports periodic online evidence for
MQTT client connections.

The event does not represent a client-generated `PINGREQ`, nor does it attempt
to define business activity.  It represents that EMQX has observed the client
connection as online at a given point in time.  Each event carries an expiry
time (an online lease).  External consumers consider the client offline when
the latest lease expires without a newer event.

The first version is limited to MQTT connections.  The implementation strategy
is intentionally left open between per-connection timers, a centralized live
connection exporter, and an event-driven timing-wheel design.

## Motivation

EMQX already exposes the `$events/client/ping` event.  That event is useful for
diagnostics, but it is not a reliable source of client liveness.

### `PINGREQ` is not a periodic client signal when the client is busy

MQTT Keep Alive requires a client to send a `PINGREQ` only when it has not sent
another MQTT Control Packet during the Keep Alive interval.  A client that is
continuously publishing may therefore send no `PINGREQ` for a long time.  The
MQTT 5.0 specification describes this behavior in section 3.1.2.10:

* [MQTT Version 5.0, Keep Alive](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html#_Toc3901045)

This is also the behavior exposed by common client SDKs:

* [Eclipse Paho Python](https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html)
  describes PING messages as necessary when no other messages are exchanged.
* [Eclipse Paho Java](https://eclipse.dev/paho/files/javadoc/org/eclipse/paho/client/mqttv3/MqttConnectOptions.html)
  guarantees network traffic within the Keep Alive period and sends a small
  ping in the absence of a data-related message.
* [MQTT.js](https://github.com/mqttjs/MQTT.js) enables `reschedulePings` by
  default, rescheduling the ping after messages are sent.
* [HiveMQ MQTT Client](https://github.com/hivemq/hivemq-mqtt-client/blob/master/src/main/java/com/hivemq/client/internal/mqtt/handler/ping/MqttPingHandler.java)
  schedules a PINGREQ only when the relevant traffic timestamps are idle.

Consequently, `$events/client/ping` answers the question:

> Did EMQX receive a client-generated PINGREQ?

It does not answer:

> Is the MQTT connection currently observed by EMQX as online?

### A connection can disappear without producing a final event

External systems often maintain a client online/offline projection.  Relying
only on `client.connected` and `client.disconnected` leaves stale online state
when a node, process, network path, or event delivery pipeline fails before the
disconnect event is delivered.

The proposed online lease gives the external system a bounded-staleness rule:

```text
online  = latest valid_until is in the future
offline = latest valid_until has expired
```

If EMQX or the event pipeline stops, no new lease is issued and the external
projection eventually expires without requiring a negative event.

### Liveness is deliberately narrower than business activity

For this EIP, `liveness` means that EMQX observes the MQTT client connection as
online.  It does not mean that the client has recently published an application
message, that a business operation succeeded, or that the persistent MQTT
session exists.  A persistent session may remain after its socket has closed;
that session must not renew this lease.

## Design

### Proposed event contract

The public Rule Engine event name is proposed as:

```text
Hookpoint:  client.liveness
Event topic: "$events/client/liveness"
```

The event is a periodic online assertion, not a one-time transition event.
The tentative payload is:

```json
{
  "event": "client.liveness",
  "state": "online",
  "clientid": "device-001",
  "username": "device",
  "connected_at": 1787191200000,
  "issued_at": 1787191230000,
  "valid_until": 1787191410000,
  "node": "emqx@node1"
}
```

The following points are part of the intended semantics:

* A client emits an initial online event after a successful MQTT connection.
* The broker periodically emits newer online leases while the connection is
  observed as `connected` (and, if applicable, `reauthenticating`).
* No offline event is required for the external projection; expiry is the
  offline signal.
* `valid_until` is fixed when the event is created.  Retrying an old event must
  not extend its validity.
* `connected_at` identifies the connection incarnation sufficiently for the
  first version.  Whether a separate `connection_id` is needed is TBD.
* The event must not be emitted for a disconnected persistent session.

The final event name and payload fields are TBD.

### Option A: Per-connection periodic timer

Each MQTT connection process owns a liveness timer.  On every tick it checks
its channel state and emits an online lease.

Advantages:

* The connection state is local and authoritative.
* No central registry or scan is required.
* The implementation is conceptually straightforward.

Costs and risks:

* Every online connection must be periodically woken, creating O(N) timer
  wakeups in addition to O(N) event output.
* The current `stats_timer` is not a continuously periodic timer: after an
  `emit_stats` tick it is cleared and is normally restarted by a later message.
  It cannot be reused without changing that lifecycle.
* The current `stats_timer` also depends on `stats.enable` and reuses
  `mqtt.idle_timeout`, neither of which has liveness semantics.

### Option B: Centralized exporter scanning live channels

A node-level `client_liveness_exporter` wakes periodically and scans the set of
live MQTT channels.  It emits online leases in batches and never sends a query
to each channel process.

The existing channel-management tables provide the required building blocks:

* `CHAN_LIVE_TAB` identifies locally live channel processes.
* `CHAN_CONN_TAB` maps a channel process to its client ID and connection module.
* `CHAN_INFO_TAB` contains cached channel state and connection metadata.
* `emqx_cm:all_channels_stream/1` already demonstrates bounded, chunked ETS
  scanning.

A new `emqx_cm:live_channels_stream/1` may encapsulate the ETS joins and return
  only live MQTT channel records, for example:

```erlang
{ClientId, ChannelPid, ConnState, ConnInfo, ClientInfo}
```

The exporter would filter for `connected`/`reauthenticating`, construct a
bounded batch of lease records, and pass that batch to an output Adapter.

Advantages:

* Only one node-level process (or a small number of shards) is periodically
  woken; connection processes remain idle.
* The scan can be chunked and paced to bound scheduler and memory impact.
* A node or exporter restart naturally stops lease renewal; external state
  expires.
* The design is easy to recover: the next full scan reconstructs the current
  online set.

Costs and risks:

* Every interval performs O(N) ETS traversal for N live channels.
* A disconnect or takeover may race with a scan, so the event contract must
  tolerate bounded stale online leases.
* Rule Engine delivery must support batching or the per-record event/action
  cost remains O(N) even though connection wakeups are avoided.
* The exact relationship between the cached channel state and socket process
  liveness needs to be documented and tested.

### Option C: Event-driven registry with a centralized timing wheel

The broker registers a connection when `client.connected` runs and removes it
when `client.disconnected` or channel cleanup runs.  A centralized timing wheel
keeps the next renewal deadline for each registered connection.  Only the
connections in the current deadline bucket are processed on each tick.

Advantages:

* Avoids a full O(N) scan on every interval.
* Does not wake every connection process.
* Keeps renewal work proportional to the number of leases due in the current
  bucket.

Costs and risks:

* More state must be kept and reconciled when hooks, channel cleanup, or the
  exporter restart.
* Takeover, duplicate registration, and stale entries require explicit
  handling.
* The timing-wheel implementation adds complexity before the scale requirement
  is measured.

### Option D: Connected/disconnected events only

External systems use the existing `client.connected` and
`client.disconnected` events and do not receive periodic online leases.

Advantages:

* No periodic broker work and no additional event volume.
* No new event producer is required.

Costs and risks:

* A missing disconnect event leaves stale online state indefinitely.
* It cannot provide the bounded expiry semantics required by this EIP.
* It does not distinguish a live socket from a stale event projection.

This option does not satisfy the liveness requirement unless an independent
reconciliation or polling mechanism is added.

### Current direction

TBD.  The initial implementation choice should be made after measuring:

* local ETS scan cost at the target number of connections;
* event and connector throughput for the selected lease interval;
* scheduler and memory impact of centralized versus per-connection timers;
* stale-lease behavior during takeover, disconnect races, node restart, and
  connector outage.

## Configuration Changes

TBD.

The likely configuration will need an enable switch, an online renewal interval,
and a lease duration.  The lease duration should be greater than the renewal
interval by a documented safety margin.

## Backwards Compatibility

TBD.

The proposed event is additive.  Existing `$events/client/ping`,
`$events/client/connected`, and `$events/client/disconnected` events retain
their current semantics.

## Document Changes

TBD.

Documentation will need to explain that `$events/client/liveness` is a stream
of online leases and that offline is derived from `valid_until`, not emitted as
a required negative event.

## Testing Suggestions

TBD.

At minimum, tests should cover:

* initial online lease after a successful MQTT connection;
* repeated renewal while the socket remains connected but no MQTT packets are
  exchanged;
* expiry after exporter/timer/node failure;
* takeover and reconnect of the same client ID;
* stale ETS rows and disconnect races;
* MQTT TCP, TLS, and WebSocket connection modules;
* bounded scan memory and batch behavior;
* connector retry without extending `valid_until`.

## Declined Alternatives

### Reusing `$events/client/ping`

Declined as the authoritative liveness event.  It reports only received
`PINGREQ` packets, while MQTT clients are allowed to suppress PINGREQ when they
are sending other MQTT Control Packets such as PUBLISH.  It also provides no
lease expiry semantics for external state projection.

### Emitting an event for every received MQTT packet

Declined for the initial design because event volume scales with application
traffic and would couple liveness export to the packet hot path.  A liveness
lease should be sampled and renewed at a controlled rate.

## Open Questions

* Should the public event be named `$events/client/liveness`,
  `$events/client/online`, or another name?
* Should each event include a generated `connection_id`, or is `connected_at`
  sufficient for the first version?
* Should the exporter output one event per client or support a batch-specific
  Adapter?
* What default renewal interval and lease duration are acceptable at the target
  connection scale?
* Should a connector outage be interpreted as client offline, or should a
  separate exporter/source liveness signal be added later?
* Should the first version use a full live-channel scan or an incremental timing
  wheel?
