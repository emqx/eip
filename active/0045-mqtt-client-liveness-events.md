# MQTT Client Liveness Events

## Changelog

* 2026-08-20: Initial draft.
* 2026-08-20: Define the Keep Alive-driven lease, ordering, and projection design.

## Abstract

This EIP proposes an event stream that exports periodic online evidence for
MQTT client connections.

The event does not represent a client-generated `PINGREQ`, nor does it attempt
to define business activity.  It represents that EMQX has observed the client
connection as online at a given point in time.  Each event carries an expiry
time (an online lease).  External consumers consider the client offline when
the latest lease expires without a newer event.

The first version is limited to MQTT connections.  The main design reuses the
existing MQTT Keep Alive evaluations as its scheduling source and applies a
server-controlled minimum reporting interval to bound event volume.

## Motivation

EMQX already exposes the `$events/client/ping` event.  That event is useful for
diagnostics, but it is not a reliable source of client liveness.

### `PINGREQ` is not a periodic client signal when the client is busy

MQTT Keep Alive requires a client to send a `PINGREQ` only when it has not sent
another MQTT Control Packet during the Keep Alive interval.  A client that is
continuously publishing may therefore send no `PINGREQ` for a long time.  The
MQTT 5.0 specification describes this behavior in section 3.1.2.10:

* [MQTT Version 5.0, Keep Alive](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html#_Toc3901045)

Common MQTT clients follow this behavior by postponing PINGREQ while other
MQTT traffic is sent, including
[Eclipse Paho Python](https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html),
[Eclipse Paho Java](https://eclipse.dev/paho/files/javadoc/org/eclipse/paho/client/mqttv3/MqttConnectOptions.html),
[MQTT.js](https://github.com/mqttjs/MQTT.js), and
[HiveMQ MQTT Client](https://github.com/hivemq/hivemq-mqtt-client/blob/master/src/main/java/com/hivemq/client/internal/mqtt/handler/ping/MqttPingHandler.java).

Consequently, `$events/client/ping` answers the question:

> Did EMQX receive a client-generated PINGREQ?

It does not answer:

> Is the MQTT connection currently observed by EMQX as online?

### Lifecycle events alone are insufficient for device presence

Device online state is often consumed as an external projection.  Relying only
on `client.connected` and `client.disconnected` is insufficient because the
disconnect event is not guaranteed to be produced after an abrupt node or VM
termination, or when a connection process terminates before normal channel
cleanup completes.  An out-of-memory termination is one possible cause.  In
these cases, an external consumer may keep the last connected state forever.

This EIP addresses that specific failure mode by exporting an online lease.  If
the broker-side producer stops renewing the lease, the external projection can
eventually expire without requiring a final offline event.

This proposal does not replace MQTT Keep Alive or TCP keepalive.  A silent
network-path failure is detected by those mechanisms when they are configured
with a finite timeout.  It is not a separate motivation for this event, and no
finite network-failure bound can be promised when both mechanisms are disabled
or unbounded.

Event-delivery failure is also not a motivation for this feature.  The liveness
event uses the configured event-delivery path and has the same delivery
limitations as other EMQX events.

### Liveness is deliberately narrower than business activity

For this EIP, `liveness` means that EMQX observes the MQTT client connection as
online.  It does not mean that the client has recently published an application
message, that a business operation succeeded, or that the persistent MQTT
session exists.  A persistent session may remain after its socket has closed;
that session must not renew this lease.

## Design

### Main design

The liveness producer is placed in the existing MQTT Keep Alive path.
`emqx_keepalive` already samples inbound `recv_pkt` activity and decides whether
the negotiated Keep Alive deadline has been reached.  Liveness reuses those
evaluations without adding another timer or scanning connection registries.

```text
inbound MQTT Control Packet
    -> recv_pkt counter increases

Keep Alive evaluation
    -> update last_seen_at if recv_pkt increased
    -> if timeout:
           run client.liveness(state=offline)
       else if min_report_interval has elapsed since the previous online record:
           run client.liveness(state=online)
```

The connection lifecycle is included in the same stream:

* `client.connected` produces the initial online record;
* the first successful Keep Alive evaluation after the configured minimum
  interval produces a periodic online record;
* a dynamic Keep Alive change immediately produces `keepalive_updated` or, if
  the shortened timeout has already elapsed, takes the terminal timeout path;
* `client.disconnected` produces a terminal offline record.

PINGREQ-triggered evaluations must not bypass the minimum reporting interval.
The hook is run from the channel integration layer; `emqx_keepalive` remains
responsible for Keep Alive state calculation and does not perform Rule Engine
or external I/O.

### Proposed event contract

The public Rule Engine event and hookpoint are:

```text
Hookpoint:  client.liveness
Event topic: "$events/client/liveness"
```

The stream contains periodic online assertions and terminal lifecycle records.
All timestamps are Unix epoch milliseconds.

An online record has the following shape:

```json
{
  "event": "client.liveness",
  "state": "online",
  "reason": "periodic_check",
  "clientid": "device-001",
  "username": "device",
  "connection_id": "opaque-connection-id-A",
  "sequence": 2,
  "connected_at": 1787191200000,
  "last_seen_at": 1787191230000,
  "valid_until": 1787191300000,
  "timestamp": 1787191235000,
  "node": "emqx@node1"
}
```

An explicitly observed terminal connection event has the following shape:

```json
{
  "event": "client.liveness",
  "state": "offline",
  "reason": "takenover",
  "clientid": "device-001",
  "username": "device",
  "connection_id": "opaque-connection-id-A",
  "sequence": 3,
  "connected_at": 1787191200000,
  "last_seen_at": 1787191230000,
  "valid_until": null,
  "timestamp": 1787191240000,
  "node": "emqx@node1"
}
```

The fields have the following semantics:

* `connection_id` identifies one successful MQTT connection incarnation.  It
  is an opaque serialized value and must not be parsed or sorted.
* `sequence` orders liveness records produced by the same connection
  incarnation.
* `connected_at` is retained for presentation and diagnosis.  It is not a
  connection identity or ordering field.
* `last_seen_at` is the most recent time at which Keep Alive processing
  observed new inbound MQTT activity.
* `valid_until` is the fixed lease deadline for an online record.  It is
  explicitly `null` for an offline record.
* `timestamp` is the time at which EMQX created the event record.

Online records use one of these reasons:

* `connected`: the initial record after a successful connection;
* `periodic_check`: a scheduled liveness report produced from Keep Alive
  processing;
* `keepalive_updated`: an immediate record after the connection's effective
  Keep Alive changes.

Offline records reuse the same reason value exposed by the existing
`client.disconnected` event.  This preserves distinctions such as normal
disconnect, Keep Alive timeout, takeover, kick, and socket closure without
creating a second disconnect-reason vocabulary.

The event stream has the following semantics:

* A client with a non-zero negotiated Keep Alive emits an initial online event
  after a successful MQTT connection.
* The broker periodically emits newer online leases while recent inbound MQTT
  activity remains within the negotiated Keep Alive window.
* A terminal connection event is mirrored as `state = offline` so that normal
  disconnects are reflected without waiting for lease expiry.
* `valid_until` is fixed when the event is created.  Retrying an old event must
  not extend its validity.
* An online record must have a non-null `valid_until`; an offline record must
  have `valid_until = null`.
* `last_seen_at` records when EMQX most recently observed an inbound MQTT
  Control Packet.  It is not limited to PINGREQ packets.
* The event must not be emitted for a disconnected persistent session.
* A client with `keepalive = 0` does not emit liveness lease events.

`last_seen_at` follows this lifecycle:

* the initial online record sets it to `connected_at`;
* a Keep Alive evaluation that observes an increased `recv_pkt` counter sets it
  to the evaluation timestamp;
* a periodic evaluation without new activity leaves it unchanged;
* a dynamic Keep Alive update leaves it unchanged;
* the terminal offline record carries its final value.

The public event name is `$events/client/liveness` and the corresponding
hookpoint is `client.liveness`.

### Connection identity and event ordering

EMQX uses the channel process PID as the internal identity for one successful
MQTT connection incarnation.  The public event serializes that PID as an
opaque `connection_id` string or binary.  Consumers must not parse it, sort it,
or depend on the Erlang node name embedded in its representation.  The public
contract requires the serialized value to remain unique among all connection
incarnations whose events can still be delivered or retained; the encoding can
be replaced if the connection implementation changes in the future.

Each connection incarnation owns a non-negative 64-bit `sequence` counter.
The counter starts at `1` for the initial online record and increases for every
subsequent liveness record generated by that connection, including renewals,
Keep Alive changes, and the terminal offline record.

The ordering guarantees are:

* `sequence` is strictly increasing within one `connection_id`;
* sequence values do not need to be contiguous at the consumer;
* no sequence order is defined between different connection IDs or clients;
* retrying or redelivering an event must preserve its original
  `connection_id`, `sequence`, `timestamp`, and `valid_until`;
* an event whose sequence is less than or equal to the highest sequence already
  observed for that connection ID is a duplicate or stale event;
* an offline record is terminal for its connection ID.  No later event may be
  generated for that incarnation.

The channel process is the single owner of the counter, so assigning a
sequence does not require cluster coordination.

`connected_at` cannot replace `connection_id`: two reconnects may complete in
the same millisecond, and a takeover on another node may receive an earlier
wall-clock timestamp because node clocks are not perfectly synchronized.
Likewise, event timestamps cannot replace `sequence`, because multiple events
may share a millisecond and wall clock can move backwards.

### Keep Alive-driven reporting interval

Liveness reuses the existing MQTT Keep Alive timer as its only scheduling
source, while a server-side setting limits how frequently a connection may
produce online records.

Let:

```text
C = effective keepalive_check_interval for the connection
L = configured client_liveness.min_report_interval
```

An online record is emitted by the first Keep Alive evaluation that occurs
after `L` has elapsed since the previous online record.  Keep Alive evaluations
are not aligned to a fixed wall-clock grid: an incoming PINGREQ may perform an
immediate evaluation and reset the timer.  Therefore the actual reporting gap
is variable:

```text
L <= actual_report_gap <= L + C + scheduling_jitter
```

For lease calculation, define the maximum expected report gap as:

```text
G = L + C
```

Thus `L` limits event frequency but the next eligible check may occur up to one
Keep Alive check interval later.  For example, if `L = 30s` and `C = 20s`, the
next online record may be generated between 30 and 50 seconds after the
previous record.

With `min_report_interval = 30s`, `margin = 5s`, and the default
configured Keep Alive check interval of `30s`, representative connection
settings produce the following bounds:

| Negotiated Keep Alive | Effective check interval `C` | Report gap range | Maximum gap `G` | Lease duration `G + S` | Worst-case node/process failure detection |
| --- | ---: | ---: | ---: | ---: | ---: |
| `60s` | `30s` | `30s` to `60s` | `60s` | `65s` | `65s` |
| `5s` | `2.5s` | `30s` to `32.5s` | `32.5s` | `37.5s` | `37.5s` |
| `1s` | `1s` | `30s` to `31s` | `31s` | `36s` | `36s` |
| `0` | no timer | no reporting | N/A | N/A | not supported |

The configured `30s` is a minimum spacing between online records, not a strict
30-second maximum detection error.  The maximum error also includes up to one
effective Keep Alive check interval and the liveness margin.

For each connection, EMQX also records `last_seen_at` when Keep Alive
processing observes an increase in the inbound `recv_pkt` counter.  The field
is diagnostic and does not determine the liveness lease deadline.  Accepted
inbound MQTT Control Packets include PUBLISH, acknowledgements, SUBSCRIBE,
UNSUBSCRIBE, AUTH, and PINGREQ.

The activity source is intentionally defined in terms of accepted inbound
MQTT packets rather than a fixed list of public hookpoints.  Existing hooks
such as `client.ping` and `message.publish` may be used as adapters, but the
initial implementation must not assume that every packet type has a separate
public hookpoint.

Each connection captures the configured `margin` when it is created;
the default is `5s`.  An online record sets:

```text
valid_until = timestamp + G + margin
```

Normal client or network inactivity remains governed by MQTT Keep Alive.  If a
Keep Alive check reaches its timeout, EMQX emits an offline record immediately.
The online lease is the fallback for failures that prevent a terminal event,
such as abrupt node or connection-process termination.

When the effective Keep Alive interval changes dynamically, EMQX recomputes
`C` and `G`.  This lifecycle/configuration event is not limited by
`min_report_interval`:

* if the new Keep Alive is non-zero and the connection has not reached the new
  timeout, EMQX immediately emits an online record with reason
  `keepalive_updated` and the new `valid_until`;
* if the shorter Keep Alive makes the connection already timed out, EMQX takes
  the normal Keep Alive timeout path and emits a terminal offline record;
* if the new Keep Alive is zero, periodic liveness reporting stops and the last
  emitted lease expires naturally.

When the effective MQTT Keep Alive is zero, no Keep Alive timer exists and the
first version does not emit liveness records for that connection.

### Delivery-delay and loss guarantee

The selected lease duration is exactly one maximum reporting gap plus the
margin.  Therefore the liveness projection assumes that each online record
is delivered; it does not guarantee continuity when an entire periodic online
record is lost.

Let:

```text
D = maximum end-to-end event-delivery delay
J = timer jitter and Broker/consumer clock-skew budget
S = configured margin
```

To ensure the next online record arrives before the previous lease expires:

```text
D + J < S
```

With the default `S = 5s`, the combined delivery-delay, scheduling-jitter, and
clock-skew budget must remain below five seconds.  If a whole online record is
lost, the consumer may temporarily project an active connection as offline
until a later record arrives.  Tolerating one complete lost renewal would
require a lease of at least `2 * G + S`; that alternative is intentionally not
selected because it doubles the worst-case detection delay for node or process
failure.

An event-delivery pipeline outage has the same observable result as a stopped
liveness producer: no new online records arrive and leases expire.  The first
version therefore projects affected clients offline during such an outage.  It
does not add an independent source-health signal to distinguish client failure
from event-pipeline failure; deployments that require that distinction need a
separate health channel.

### External projection

An external consumer maintains the latest record for each connection
incarnation:

```text
states[clientid][connection_id] = highest-sequence liveness record
```

On receipt of an event `E`, the consumer applies:

```text
current = states[E.clientid][E.connection_id]

if current does not exist or E.sequence > current.sequence:
    states[E.clientid][E.connection_id] = E
else:
    ignore E as duplicate or stale
```

One connection incarnation is online when its highest-sequence record is
online and its lease has not expired:

```text
connection_online(E, now) =
    E.state == online and now < E.valid_until
```

For an offline record, the consumer ignores `valid_until` and considers the
connection offline immediately.  For an online record, a null `valid_until` is
invalid input and must not be treated as online.

A client is online when at least one of its connection incarnations is online:

```text
client_online(ClientId, now) =
    exists E in states[ClientId]: connection_online(E, now)
```

This existential rule is intentional.  During takeover, EMQX may briefly
observe both the old and new connection incarnations.  An offline event for the
old connection must not make the new connection offline.

#### Takeover example

The old connection `A` is online:

```text
A/1 online  timestamp=10:00:00  valid_until=10:01:05
```

A new connection `B` takes over the same client ID:

```text
B/1 online  timestamp=10:00:30  valid_until=10:01:35
```

The old connection finishes cleanup after the new connection is online:

```text
A/2 offline timestamp=10:00:31
```

The projected state is:

```text
A = offline
B = online and unexpired

client_online = connection_online(A) OR connection_online(B)
              = false OR true
              = true
```

If the consumer stored only one record per client ID, the later `A/2 offline`
would incorrectly overwrite `B/1 online`.  Event timestamps cannot solve this:
`A/2` was legitimately created later, but it refers only to connection `A`.

#### Reordered and duplicate event example

A connection generates events in this logical order:

```text
A/1 online  timestamp=10:00:00
A/2 online  timestamp=10:00:30
A/3 offline timestamp=10:01:00
```

An at-least-once output Adapter may deliver them as:

```text
A/1, A/3, A/2, A/3
```

After accepting `A/3`, the consumer ignores `A/2` because `2 < 3`, and ignores
the second `A/3` because `3 == 3`.  The connection remains offline.  Delivery
order does not change the projection.

#### Missing terminal event example

The last event from connection `A` is:

```text
A/5 online timestamp=10:00:00 valid_until=10:01:05
```

If the node terminates at `10:00:10`, no `A/6 offline` event may be produced.
The projection remains online until `10:01:05` and becomes offline when the
lease expires.  A delayed delivery of `A/5` after `10:01:05` cannot revive the
connection because the original `valid_until` is already in the past.

#### Tombstone retention

After an offline record or lease expiry, a consumer must not immediately forget
the highest sequence for the connection ID.  Otherwise, a delayed old online
record could be accepted as a new record and revive the connection.

The consumer should retain at least this tombstone:

```text
(clientid, connection_id, highest_sequence)
```

for no less than the maximum retry or replay window of its event-delivery
pipeline.  The full event payload may be discarded earlier.

For an explicitly observed disconnect, the expected delay is the event
delivery delay.  If the broker or connection process terminates before it can
produce the offline event, the stale-online bound is the lease validity period
plus delivery and clock-skew margins.  A silent network path remains bounded
by the configured MQTT Keep Alive or TCP keepalive detection mechanism.

## Performance Considerations

The main direction is the Keep Alive-integrated liveness sampling design above.
For `N` online connections and configured minimum interval `L`, the maximum
periodic logical online-event rate is:

```text
N / L
```

For example, `N = 1,000,000` and `L = 30s` gives a maximum periodic rate of
approximately `33,333` logical events per second.

The actual rate may be lower because the report waits for the next Keep Alive
evaluation and its gap may approach `G = L + C`.  Initial connection,
Keep Alive update, and terminal offline records are lifecycle/configuration
events and are not included in this periodic estimate.

When liveness is enabled for a connection, the channel evaluates the reporting
schedule, assigns sequence values, and runs the `client.liveness` hook
independently of whether a Rule Engine rule or Action is configured.  The Rule
Engine exposes that hook as `$events/client/liveness`; skipping event-column
materialization when no rule matches is an Adapter optimization and does not
change the connection-level schedule or ordering contract.

> Note: `client.liveness` is triggered from the connection/Keep Alive path.
> Rule Engine actions should preferably use asynchronous buffered delivery so
> external I/O does not delay MQTT packet processing or later Keep Alive
> checks.  This EIP does not prohibit synchronous actions; deployments that
> select them must account for their latency and backpressure impact.

## Configuration Changes

The proposed configuration is:

```hocon
mqtt.client_liveness {
  enable = false
  min_report_interval = 30s
  margin = 5s
}
```

`enable` controls whether MQTT connections produce liveness records.
`min_report_interval` is the minimum spacing between online records; the next
record is emitted by the first Keep Alive evaluation after that interval.  The
lease uses the maximum expected gap `G = L + C`.  `margin` is added to that gap
to cover bounded event-delivery delay, scheduling jitter, and clock skew; its
default is `5s`.  Periodic liveness reporting is disabled when the effective
MQTT Keep Alive is zero.

`enable` is a boolean.  `min_report_interval` and `margin` use the HOCON
`duration()` type.  The first version validates:

```text
margin >= 1s
min_report_interval >= 2 * margin
```

The second constraint is an operational guard to keep the safety margin from
dominating the reporting interval; it is not an MQTT protocol requirement.

The liveness configuration is captured when a new MQTT connection is created.
Runtime changes to `enable`, `min_report_interval`, or `margin` apply only to
connections established afterward.  Existing connections retain their
captured values until they disconnect; EMQX does not scan or signal all live
connections to retrofit configuration changes.

Consequently, enabling the feature does not immediately create a complete
projection for already-connected clients, and disabling it does not stop
records from connections that captured `enable = true`.  Complete coverage is
available only after all pre-enable connections have disconnected or
reconnected.  Immediate fleet-wide enablement or shutdown would require a scan,
broadcast, or forced reconnect and is outside this EIP.

## Backwards Compatibility

The proposed event is additive.  Existing `$events/client/ping`,
`$events/client/connected`, and `$events/client/disconnected` events retain
their current semantics.

The feature is disabled by default.  Enabling it only after every node has been
upgraded is an operational prerequisite, not an automatically negotiated
feature gate.  A mixed-version cluster cannot provide a complete
client-liveness projection because older nodes do not emit `client.liveness`
records or recognize the new Rule Engine event source.  No mixed-version
liveness guarantee is provided.  After enabling, connections established
before enablement must also reconnect before the projection has complete
coverage.

## Document Changes

Documentation will need to explain that `$events/client/liveness` is a stream
of online leases plus explicitly observed offline lifecycle events.  External
consumers derive offline from `valid_until` when no terminal event is
available.

## Testing Suggestions

At minimum, tests should cover:

* initial online lease after a successful MQTT connection;
* online reasons `connected`, `periodic_check`, and `keepalive_updated`;
* offline reasons matching the existing `client.disconnected` event;
* online records carrying a non-null `valid_until` and offline records carrying
  `valid_until = null`;
* actual reporting gaps between `L` and `L + C` under normal scheduling;
* at most one online record within `min_report_interval`;
* successful idle checks emitting online until Keep Alive timeout;
* `valid_until = timestamp + G + margin`;
* PINGREQ-triggered checks not bypassing the minimum reporting interval;
* no periodic liveness event for `keepalive = 0`;
* dynamic Keep Alive changes bypassing the minimum interval, recomputing `C`
  and `G`, and immediately updating the lease;
* a shortened dynamic Keep Alive that is already expired taking the terminal
  timeout path instead of emitting online;
* runtime liveness configuration changes affecting only connections created
  afterward;
* `enable = true` running the hook independently of current Rule Engine rule or
  Action configuration;
* configured margin values changing the lease deadline for new connections;
* lease expiry after the Keep Alive producer or node fails;
* a unique `connection_id` for each reconnect and takeover incarnation;
* strictly increasing `sequence` values within one connection incarnation;
* retry preserving the original sequence, timestamp, and lease deadline;
* duplicate and reordered delivery not rolling back a connection state;
* a delayed offline event for an old connection not closing a new connection;
* tombstone retention preventing an expired connection from being revived;
* delivery delay below and above the configured margin;
* a completely lost online renewal causing the documented temporary offline
  projection;
* event-pipeline outage causing lease expiry as documented;
* MQTT TCP, TLS, WebSocket, and QUIC connection modules;
* connector retry without extending `valid_until`.

## Declined Alternatives

### Emit on every Keep Alive check

Emitting one online record for every Keep Alive check gives more renewal
redundancy, but a client with a one-second check interval would produce one
full-chain event per second.  The selected server-controlled minimum interval
bounds this cost.

### Dedicated liveness scheduling

A separate per-connection timer or centralized timing wheel could provide a
more exact reporting cadence.  It was not selected because it duplicates the
existing Keep Alive schedule and adds timer state, wakeups, and lifecycle
coordination solely for this event.

### Centralized live-channel scan

A node-level exporter could scan cached live-channel state and emit leases in
batches.  This avoids connection-process reporting work, but adds continuous
O(N) scans, relies on cached state, and duplicates connection-local knowledge
already maintained by Keep Alive.
