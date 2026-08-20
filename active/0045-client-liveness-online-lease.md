# Client Liveness Online Lease Events

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
existing MQTT Keep Alive check path to sample inbound packet activity and emit
throttled liveness events.  Per-connection timers, centralized live-channel
scanning, and an event-driven timing wheel are retained as alternatives.

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

### Proposed event contract

The public Rule Engine event name is proposed as:

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
  "connection_id": "019D2A67F9A1000AB231000000000001",
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
  "connection_id": "019D2A67F9A1000AB231000000000001",
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
  is an opaque value and must not be sorted or parsed as a timestamp.
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

The public event name is `$events/client/liveness` and the corresponding
hookpoint is `client.liveness`.

### Connection identity and event ordering

EMQX generates one 128-bit `connection_id` after a connection has successfully
authenticated and opened or taken over its session.  The identifier is stored
in binary form with the channel and rendered as 32 hexadecimal characters in
the event.  `emqx_guid:gen/0` is a candidate implementation.  The public
contract requires the identifier to be unique among all connection
incarnations whose events can still be delivered or retained; its encoding is
not part of the contract.

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

With `min_report_interval = 30s`, `liveness_margin = 5s`, and the default
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

Each connection captures the configured `liveness_margin` when it is created;
the default is `5s`.  An online record sets:

```text
valid_until = timestamp + G + liveness_margin
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
S = liveness_margin
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

### Main design: Keep Alive-integrated liveness sampling

The liveness producer is placed in the existing MQTT Keep Alive check path.
`emqx_keepalive` already samples the inbound `recv_pkt` counter and decides
whether the negotiated Keep Alive deadline has been reached.  The liveness
logic can reuse that observation without adding a second timer or a separate
packet hook for every MQTT Control Packet.

The intended flow is:

```text
inbound MQTT Control Packet
    -> recv_pkt counter increases

Keep Alive check
    -> detect whether recv_pkt changed
    -> update last_seen_at when activity was observed
    -> if timeout:
           run client.liveness(state=offline)
       else if min_report_interval L has elapsed since the previous online record:
           run client.liveness(state=online)
```

The connection lifecycle is included in the same event stream:

* `client.connected` produces the initial `client.liveness(state=online)`;
* the first successful Keep Alive evaluation after `L` has elapsed produces an
  online record, whether or not that check observes new activity;
* `client.disconnected` produces `client.liveness(state=offline)`.

Each successful periodic report is a fresh assertion that the connection has
not yet reached its MQTT Keep Alive timeout.  It sets `valid_until` from the
maximum reporting gap `G`, independently of `last_seen_at`.  If the
client becomes inactive, the Keep Alive timeout and offline event take
precedence over generating another online record.

The PINGREQ path also invokes Keep Alive checking and may reset the timer.  It
must not bypass the event-rate limit.  One connection incarnation may emit at
most one online liveness record within `L`; the next record is generated by the
first eligible Keep Alive evaluation.  This applies regardless of whether the
evaluation originated from a timer or an incoming PINGREQ.

The liveness hook is run from the channel/Keep Alive integration layer, not
from the `emqx_keepalive` state module itself.  The state module should remain
responsible for Keep Alive calculation and return whether new packet activity
was observed.  Existing hooks such as `client.ping` and `message.publish` may
remain available for their existing use cases, but they are not the source of
truth for liveness.

This design has the following properties:

* continuously publishing clients renew liveness without sending PINGREQ;
* idle clients may emit online observations until MQTT Keep Alive reaches its
  timeout, at which point an offline event takes precedence;
* no additional per-connection liveness timer is needed;
* no separate liveness timer or channel scan is needed;
* the server-controlled minimum reporting interval bounds full-chain event
  volume independently of a client's small Keep Alive value;
* when `keepalive = 0`, periodic liveness reporting is disabled.

The main implementation questions are how the sampled activity result is
returned without breaking the existing `emqx_keepalive` interface and where to
store the timestamp of the last emitted liveness record.

## Declined Alternatives

### Emit on every Keep Alive check interval

An alternative emits one online record for every effective Keep Alive check
interval.  This closely mirrors the internal check cadence and provides more
renewal redundancy without deriving a separate reporting interval.

This was not selected because clients may negotiate very small Keep Alive
values.  For example, a one-second effective check interval would produce one
full-chain liveness event per second per connection.  The selected design
retains the existing Keep Alive timer but applies a server-controlled minimum
reporting interval to bound event volume.

### Per-connection periodic timer

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

### Centralized exporter scanning live channels

A node-level `client_liveness_exporter` wakes periodically and scans the set of
live MQTT channels.  It emits online leases in batches and never sends a query
to each channel process.  The exporter must use the cached `last_seen_at` and
Keep Alive deadline, not merely the existence of a live channel record; a
central scan cannot independently prove that a hung connection process or a
half-open socket is responsive.

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

### Event-driven registry with a centralized timing wheel

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

### Connected/disconnected events only

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

### Reusing `$events/client/ping`

`$events/client/ping` reports only received PINGREQ packets.  MQTT clients may
omit PINGREQ while sending other MQTT Control Packets such as PUBLISH, so this
event cannot represent authoritative connection liveness and provides no lease
expiry semantics.

### Aggregating packet-specific public hooks

Another alternative derives liveness from hooks such as `client.ping`,
`message.publish`, and new acknowledgement-specific hooks.  This was not
selected because the existing public hooks do not cover every inbound MQTT
Control Packet, adding hooks solely for liveness would expand the public
interface, and Keep Alive already maintains the authoritative `recv_pkt`
observation needed by this proposal.

### Emitting an event for every received MQTT packet

This option couples liveness export directly to application traffic.  Event
volume would grow with packet rate instead of the server-controlled reporting
interval, making the packet hot path and external integrations vulnerable to
high-volume clients.

## Performance Considerations

The main direction is the Keep Alive-integrated liveness sampling design above.
For `N` online connections and configured minimum interval `L`, the maximum
periodic logical online-event rate is:

```text
N / L
```

The actual rate may be lower because the report waits for the next Keep Alive
evaluation and its gap may approach `G = L + C`.  Initial connection,
Keep Alive update, and terminal offline records are lifecycle/configuration
events and are not included in this periodic estimate.

When liveness is enabled for a connection, EMQX runs the `client.liveness`
hook and exposes the `$events/client/liveness` Rule Engine event independently
of whether any Rule Engine rule or Action is currently configured.  The target
deployment must validate the full Rule Engine and output Adapter throughput
for the rules it later enables.

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

Both `min_report_interval` and `margin` must be positive durations.

The liveness configuration is captured when a new MQTT connection is created.
Runtime changes to `enable`, `min_report_interval`, or `margin` apply only to
connections established afterward.  Existing connections retain their
captured values until they disconnect; EMQX does not scan or signal all live
connections to retrofit configuration changes.

## Backwards Compatibility

The proposed event is additive.  Existing `$events/client/ping`,
`$events/client/connected`, and `$events/client/disconnected` events retain
their current semantics.

The feature is disabled by default.  It must be enabled only after every node
in the cluster has been upgraded to a version that supports this EIP.  A mixed
version cluster cannot provide a complete client-liveness projection because
older nodes do not emit `client.liveness` records or recognize the new Rule
Engine event source.  No mixed-version liveness guarantee is provided.

## Document Changes

TBD.

Documentation will need to explain that `$events/client/liveness` is a stream
of online leases plus explicitly observed offline lifecycle events.  External
consumers derive offline from `valid_until` when no terminal event is
available.

## Testing Suggestions

TBD.

At minimum, tests should cover:

* initial online lease after a successful MQTT connection;
* online reasons `connected`, `periodic_check`, and `keepalive_updated`;
* offline reasons matching the existing `client.disconnected` event;
* online records carrying a non-null `valid_until` and offline records carrying
  `valid_until = null`;
* actual reporting gaps between `L` and `L + C` under normal scheduling;
* at most one online record within `min_report_interval`;
* successful idle checks emitting online until Keep Alive timeout;
* `valid_until = timestamp + G + liveness_margin`;
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
