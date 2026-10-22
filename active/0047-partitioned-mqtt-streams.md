# Partitioned MQTT Streams

## Changelog

* 2026-10-07: Initial draft.
* 2026-10-22: Specify the publisher and subscriber MQTT packets; defer consumer groups to a separate proposal.

## Abstract

Add logical partitions and stable replay offsets to MQTT Streams. This proposal defines the MQTT API for publishing and consuming records:

| Client action | MQTT packets |
| --- | --- |
| Publish ordinary application traffic | `PUBLISH` to an application topic; matching streams select a partition. At QoS 1, `PUBACK` acknowledges the MQTT publication and carries no stream durability confirmation. |
| Append directly to one stream, optionally selecting a partition | QoS 1 `PUBLISH` to the stream's append topic; `PUBACK` reports durable success or rejection. |
| Consume all partitions | `SUBSCRIBE` to the stream's partition wildcard with one `earliest` or `latest` selector; receive records as `PUBLISH` packets. |
| Consume selected partitions | `SUBSCRIBE` with one Topic Filter and starting offset per partition; receive records as `PUBLISH` packets. |
| Stop consuming | `UNSUBSCRIBE`, followed by `UNSUBACK`. |
| Discover a stream's identity, partitions, and bounds | MQTT 5 request/response using `PUBLISH` packets. |

Subscriptions continue with new records after replay reaches the end. Applications choose all or selected partitions and persist their own processing positions.

The next proposal will define the consumer-group protocol, including membership, coordination, partition assignment, rebalancing, fencing, and durable group progress.

## Motivation

The current `$stream/<name>` API replays a stream using timestamp selectors. Applications need explicit units of parallel consumption and exact positions from which to resume. Broker and client-library implementers need a packet contract that does not depend on an SDK or EMQX storage internals.

This proposal provides static partition IDs, stable record identities, and explicit replay requests. Ordinary MQTT publishers continue to work without changes.

## Design

### Scope and MQTT conventions

This API applies to regular, append-only streams created in the partitioned format and uses [MQTT 5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html). Uppercase MUST, MUST NOT, and SHOULD indicate protocol requirements.

Out of scope: consumer groups; last-value streams and compaction; producer batching and deduplication; filtering within a partition; repartitioning; exactly-once processing; and live backend switching.

Packet examples below show decoded MQTT fields. Every field shown under `User Properties` is an MQTT UTF-8 string pair. Binary record payloads remain raw bytes. Examples use stream `telemetry` with three partitions and publisher Client ID `car-17`.

| Convention | Rule |
| --- | --- |
| Topic namespace | `$streams/v1/`; separate from the existing `$stream/` namespace. |
| `<name>` | Stream name encoded as one topic level: UTF-8 bytes outside ASCII letters, digits, `-`, `.`, `_`, `~` are percent-encoded using uppercase hex. Decode exactly once; reject noncanonical encodings and invalid UTF-8. |
| `<partition>` | Non-negative integer from `0` to `partition_count - 1`, written using ASCII digits `0`–`9`, with no sign or leading zeros except for `0` itself. |
| Stream identity | Opaque `stream-id`, required on append and on subscriptions with numeric start offsets. Optional when all starts are `earliest` or `latest`. Deleting and recreating a name produces a new ID. |
| Offsets | Unsigned 64-bit integers encoded as base-10 strings using only ASCII digits `0`–`9`, with no sign or leading zeros except for `0` itself, including in JSON. Compare numerically. Reserve the maximum value for positions; records must leave room for an exclusive end. |
| Protocol properties | Each property defined for a request occurs at most once. Reject missing required properties, duplicate properties, and unrecognized `stream-*` or `partition-*` request properties. |
| Connection | Direct-append and stream-subscription clients MUST enable Request Problem Information (`1`, the MQTT default), so acknowledgment properties can be returned. |
| Acknowledgment size | Before accepting an append or subscription, check that its required acknowledgment fits the client's receive limit. |
| Reserved traffic | Protocol requests, replies, and deliveries MUST NOT be captured by streams or retained. Record deliveries are addressed only to the requesting subscription. The broker MUST reject client publications to partition delivery topics with `NOT_AUTHORIZED`. |

Maximum Packet Size limits the complete MQTT packet, including headers and properties. The client advertises its receive limit in `CONNECT`; the server advertises its configured receive limit in `CONNACK`. Each applies to packets sent to that peer. If the property is absent, MQTT's protocol size limit applies. The stream's `max_record_bytes` setting is a separate storage limit.

The broker MUST support Subscription Identifiers for this API. Non-stream subscriptions and publications retain their normal MQTT behavior.

### Streams, partitions, and positions

| Term | Contract |
| --- | --- |
| Stream | A unique name, immutable `stream_id`, and fixed `partition_count`. |
| Partition | One ordered log, identified by a static integer. The broker MUST NOT change the set of partitions selected by a subscription. |
| Record identity | `(stream_id, partition, offset)`. Replay preserves the record's topic, payload, key, timestamp, and optional message ID. |
| Record offset | Strictly increases in append order within a partition. Gaps are allowed; offsets are never reused or wrapped. There is no order across partitions. |
| `start_offset` | Minimum valid read position; advances when retention removes history. |
| `end_offset` | Exclusive durable end. No new record can later appear below this position. |
| Read position | Inclusive: deliver the first retained record whose offset is greater than or equal to the requested position. A position in a gap is valid. |
| `next_offset` | Safe resume position after a delivered record. Greater than that record's offset and at or below the durable end. No stored or future record may lie between the record's offset and this position. Clients use the supplied value. |

Both bounds are durable and never decrease. An empty partition has equal bounds. Valid numeric read positions satisfy `start_offset <= position <= end_offset`; a subscription at `end_offset` waits for new records.

Partitions are logical. Physical shards, replica locations, backend cursors, and storage generations do not appear in the API.

### Topic and packet reference

| Purpose | Client sends | Topic Name or Topic Filter |
| --- | --- | --- |
| Ordinary publish | `PUBLISH` | Application topic, for example `devices/17/temp` |
| Direct append | `PUBLISH`, QoS 1, RETAIN 0 | `$streams/v1/<name>/append` |
| Consume all partitions | `SUBSCRIBE`, requested QoS 1 | `$streams/v1/<name>/partitions/+` |
| Consume selected partitions | `SUBSCRIBE`, requested QoS 1 per filter | One `$streams/v1/<name>/partitions/<partition>` filter per selected partition |
| Stop an all-partitions subscription | `UNSUBSCRIBE` | `$streams/v1/<name>/partitions/+` |
| Stop selected partitions | `UNSUBSCRIBE` | List the `$streams/v1/<name>/partitions/<partition>` strings to stop; other partition subscriptions continue. |
| Describe stream | `PUBLISH`, QoS 1, RETAIN 0, Response Topic, Correlation Data | `$streams/v1/<name>/describe` |

The MQTT Topic Filter is the subscription string: `$streams/v1/telemetry/partitions/1` selects partition `1`; `$streams/v1/telemetry/partitions/+` selects every partition. Only this final-level `+` wildcard is supported. Other wildcard forms and `$share/...` filters are not accepted.

Use either one all-partitions filter or a list of explicit partition filters in a `SUBSCRIBE` packet. All stream filters in the packet name the same stream. Explicit entries create independently removable subscriptions, even when sent in one packet; they can cover any subset or all partitions. Split large explicit requests across packets if necessary to fit the server's receive limit and the client's `SUBACK` receive limit.

### Publishers

#### Ordinary MQTT publishing

No stream-specific fields are required. For a stream named `telemetry` matching `devices/#`:

```text
Client -> Broker: PUBLISH
  Topic Name: devices/17/temp
  QoS: 1
  RETAIN: 0
  Packet Identifier: 10
  Payload: {"temperature":21.5}

Broker -> Client: PUBACK
  Packet Identifier: 10
  Reason Code: 0x00 (Success)
```

The broker evaluates the stream's key expression and selects a partition. The default key is the publishing Client ID. A stream fixes its key expression, key encoding, and hash version at creation; the same key continues to select the same partition.

An ordinary publication can match several streams and still reaches live subscribers. Its `PUBACK` carries no stream result properties and does not confirm durable storage in any matching stream. A failed stream write is reported in that stream's metrics. Applications requiring a per-stream storage receipt use direct append.

#### Direct append

The append topic accepts one record per QoS 1, non-retained `PUBLISH`. Its payload is the record's raw payload. Requests are consumed by the broker's stream handler and are not forwarded to ordinary subscribers.

| Request User Property | Required | Value |
| --- | --- | --- |
| `stream-id` | Yes | Expected immutable stream ID. |
| `stream-topic` | Yes | Original application Topic Name; MUST match the stream's configured topic filter. |
| `stream-partition` | No | Explicit partition ID. If omitted, use the stream's key rule. |
| `stream-message-id` | No | Producer-supplied bytes encoded as standard padded base64. Stored and replayed; no deduplication is implied. |

```text
Client -> Broker: PUBLISH
  Topic Name: $streams/v1/telemetry/append
  QoS: 1
  RETAIN: 0
  Packet Identifier: 11
  User Properties:
    stream-id: s-9f3c
    stream-topic: devices/17/temp
    stream-partition: 1
  Payload: {"temperature":21.5}

Broker -> Client: PUBACK
  Packet Identifier: 11
  Reason Code: 0x00 (Success)
  User Properties:
    stream-id: s-9f3c
    stream-partition: 1
    partition-offset: 58
```

For this reserved append topic, the broker MUST delay successful `PUBACK` until the record is durable. The three result properties above are required. Acknowledged appends survive a restart with intact storage and the loss of one storage replica.

- Validate stream identity, append authorization, publish authorization on `stream-topic`, topic-filter match, partition, key evaluation, and record size before storage.
- Both publishing paths evaluate the key over the original topic, raw payload, and authenticated publishing Client ID (`message.topic`, `message.payload`, and `message.from`). Explicit partition placement overrides routing, but the evaluated key is still stored. Failed key evaluation rejects the append.
- Direct append writes only the named stream. It neither delivers to live subscribers of `stream-topic` nor writes other matching streams. Publishing normally and appending directly stores two records.
- A negative `PUBACK` rejects that append attempt without storing a record. A lost acknowledgment or connection leaves the outcome unknown; resubmission can duplicate the record. Rejection of a retry does not settle an earlier unknown outcome. Client libraries MUST NOT infer rejection from a timeout or automatically submit a new append on that basis.
- Normal QoS 1 retransmission can also produce duplicates. Neither MQTT Packet Identifier nor `stream-message-id` is an idempotency key in this version.

### Subscribers

#### Start subscriptions

A `SUBSCRIBE` request selects a named stream, one or more partitions, and a starting position for each partition. Each accepted subscription reads from that position and continues with newly appended records.

The stream name addresses the current stream instance; `stream-id` identifies that instance. Deleting and recreating the stream under the same name creates a new instance with a new ID. Requests carrying the old ID fail with `STREAM_ID_MISMATCH`.

| Scenario | Starting position | `stream-id` |
| --- | --- | --- |
| Read retained history | `earliest`: resolve once to the partition's current `start_offset`. | Optional |
| Follow new records | `latest`: resolve once to the partition's current `end_offset`; wait for subsequent appends. | Optional |
| Resume or replay from a known position | Integer offset per explicit partition filter, for example `42`: validate against current bounds and start inclusively at that position. | Required |

| Request field | Required value |
| --- | --- |
| Topic Filters | Either one `$streams/v1/<name>/partitions/+`, or one `$streams/v1/<name>/partitions/<partition>` per selected partition, with explicit, static partition IDs and no duplicates. All stream filters in the packet name the same stream. |
| User Property `stream-id` | Expected immutable stream ID, at most once per packet. Required if any start selector is numeric; otherwise optional. When supplied, it must match even for `earliest` or `latest`. |
| User Property `partition-offset` | Required for the all-partitions filter: `earliest` or `latest`, applied independently to each partition. Absent with explicit partition filters. |
| User Property `partition-offset/<partition>` | Required for explicit partition filters: exactly one per selected partition, containing an integer offset, `earliest`, or `latest`. Absent with the all-partitions filter; no entries for unselected partitions. |

The partition suffix in `partition-offset/<partition>` associates a packet-wide User Property with its Topic Filter, allowing different offsets in one `SUBSCRIBE`.

Subscription Options and Subscription Identifier are standard MQTT fields. Stream subscriptions require QoS `1`, No Local `0`, and a fresh Subscription Identifier per request; do not reuse an identifier while associated subscriptions or in-flight deliveries remain. Retain As Published and Retain Handling keep their MQTT meanings; the offset selector controls replay. Examples use options byte `0x21`.

##### All partitions

This request reads retained history from every partition and then follows new records. Use `partition-offset: latest` to start at each partition's current end instead. No prior `describe` request or knowledge of the partition count is needed.

```text
Client -> Broker: SUBSCRIBE
  Packet Identifier: 19
  Subscription Identifier: 100
  User Properties:
    partition-offset: earliest
  Payload:
    Topic Filter: $streams/v1/telemetry/partitions/+
    Subscription Options: 0x21

Broker -> Client: SUBACK
  Packet Identifier: 19
  Reason Codes: [0x01] (Granted QoS 1)
  User Properties:
    stream-id: s-9f3c
    partition-offset/0: 100
    partition-start-offset/0: 100
    partition-end-offset/0: 113
    partition-offset/1: 41
    partition-start-offset/1: 41
    partition-end-offset/1: 59
    partition-offset/2: 7
    partition-start-offset/2: 7
    partition-end-offset/2: 10
```

The broker accepts all partitions or rejects the filter with one `SUBACK` reason code. It checks read authorization and availability for every partition before accepting; a failure starts none of them. This is one subscription with a separate delivery cursor for each static partition ID.

##### Selected partitions

List explicit filters to choose partitions, start them at different positions, or unsubscribe from them independently:

```text
Client -> Broker: SUBSCRIBE
  Packet Identifier: 20
  Subscription Identifier: 101
  User Properties:
    partition-offset/0: earliest
    partition-offset/1: earliest
    partition-offset/2: latest
  Payload:
    Topic Filter: $streams/v1/telemetry/partitions/0
    Subscription Options: 0x21
    Topic Filter: $streams/v1/telemetry/partitions/1
    Subscription Options: 0x21
    Topic Filter: $streams/v1/telemetry/partitions/2
    Subscription Options: 0x21

Broker -> Client: SUBACK
  Packet Identifier: 20
  Reason Codes: [0x01, 0x01, 0x01] (Granted QoS 1 for each filter)
  User Properties:
    stream-id: s-9f3c
    partition-offset/0: 100
    partition-start-offset/0: 100
    partition-end-offset/0: 113
    partition-offset/1: 41
    partition-start-offset/1: 41
    partition-end-offset/1: 59
    partition-offset/2: 10
    partition-start-offset/2: 7
    partition-end-offset/2: 10
```

This packet creates three independent subscriptions. A single-partition request uses the same format with one Topic Filter and one offset property.

For both forms, the broker resolves the name to one stream ID for the request, checks any supplied ID, and binds all accepted subscriptions to that identity. After shared request fields pass validation, it checks each partition's read authorization, availability, options, and offset. It returns one `SUBACK` reason code per filter, in request order, before sending records for accepted subscriptions. With explicit filters, a partition's failure does not prevent other valid partitions from being accepted.

For every accepted partition, `SUBACK` includes `partition-offset/<partition>`, `partition-start-offset/<partition>`, and `partition-end-offset/<partition>`, plus the common `stream-id`, even if the request omitted it. An all-partitions result includes every partition. The returned offsets are numeric, including for `earliest` and `latest`. Applications save the ID together with those positions for later replay. Bounds and selectors are resolved independently per partition; they do not represent a simultaneous snapshot or reserve retention.

Two clients may subscribe to the same partition at different offsets. Each receives its own replay. A subscription grants no exclusive ownership.

#### Receive records

Each stored record is delivered as one QoS 1, non-retained `PUBLISH` on its concrete `$streams/v1/<name>/partitions/<partition>` topic, including for an all-partitions subscription. The broker originates this delivery at QoS 1 even if the original application publication used QoS 0. Record metadata is carried in User Properties; the payload is unchanged.

Deliveries from partitions subscribed in one packet share its Subscription Identifier. Use that identifier together with `stream-partition` to route each delivery. A record describes one partition, so its metadata uses `partition-offset` without a partition suffix.

An all-partitions subscription and explicit partition subscriptions may coexist in one session. Their replays are independent: the broker sends separate deliveries carrying each subscription's identifier, even when they contain the same stored record.

```text
Broker -> Client: PUBLISH
  Topic Name: $streams/v1/telemetry/partitions/1
  QoS: 1
  RETAIN: 0
  DUP: 0
  Packet Identifier: 300
  Subscription Identifier: 101
  User Properties:
    stream-message-kind: record
    stream-id: s-9f3c
    stream-partition: 1
    partition-offset: 58
    partition-next-offset: 59
    stream-timestamp: 1791415200123456
    stream-key: Y2FyLTE3
    stream-topic: devices/17/temp
  Payload: {"temperature":21.5}

Client -> Broker: PUBACK
  Packet Identifier: 300
  Reason Code: 0x00 (Success)
```

| Delivery User Property | Meaning |
| --- | --- |
| `stream-message-kind` | Possible values: `record` for a raw record payload, or `error` for a JSON subscription error notification. |
| `stream-id`, `stream-partition`, `partition-offset` | Permanent record identity. |
| `partition-next-offset` | Position from which to resume after processing this record and every earlier delivered record in this partition. MUST NOT skip any record after `partition-offset`. |
| `stream-timestamp` | Stored broker acceptance time, decimal epoch microseconds. |
| `stream-key` | Stored key bytes, standard padded base64. |
| `stream-topic` | Original application Topic Name. |
| `stream-message-id` | Present only if supplied on direct append; standard padded base64. |

On record deliveries, all properties except `stream-message-id` are required. Original MQTT Packet Identifiers, delivery flags, and application User Properties are not part of the record format. Stream replay does not inherit the original publication's Message Expiry Interval; stream retention governs replay availability.

- First deliveries within a partition follow increasing offsets. QoS 1 duplicates can repeat an earlier offset; clients identify records by stream ID, partition, and offset, not by MQTT Packet Identifier or DUP alone.
- After the current end, the subscription remains active and delivers new appends. There is no fetch request, batch completion packet, or per-record application acknowledgment in this API.
- Receive Maximum bounds outstanding QoS 1 deliveries across the connection. Brokers MUST also bound prefetch and client libraries MUST bound buffering; Receive Maximum alone does not bound application work after automatic `PUBACK`.
- A delivery `PUBACK` acknowledges MQTT receipt. It MUST NOT be interpreted as durable application progress. Negative `PUBACK` reason codes likewise do not define retry or dead-letter behavior for a record.
- Applications save `(stream_id, partition, partition-next-offset)` after processing. With concurrent processing, save only progress for a completed prefix of the partition. After a failure, subscribe again using that saved position; records processed before the save may repeat.

#### Stop subscriptions

`UNSUBSCRIBE` lists the same subscription strings originally sent in `SUBSCRIBE`. It removes only those entries and needs no stream ID or offset properties. To stop an all-partitions subscription:

```text
Client -> Broker: UNSUBSCRIBE
  Packet Identifier: 21
  Payload:
    Topic Filter: $streams/v1/telemetry/partitions/+

Broker -> Client: UNSUBACK
  Packet Identifier: 21
  Reason Codes: [0x00] (Success)
```

Unsubscribing from `/partitions/1` does not exclude partition `1` from an existing `/partitions/+` subscription. Selective unsubscribe requires explicit partition subscriptions.

For an eight-partition stream `events`, with explicit subscriptions to partitions `0` through `7`, this packet stops `0` through `3` while `4` through `7` continue:

```text
Client -> Broker: UNSUBSCRIBE
  Packet Identifier: 24
  Payload:
    Topic Filter: $streams/v1/events/partitions/0
    Topic Filter: $streams/v1/events/partitions/1
    Topic Filter: $streams/v1/events/partitions/2
    Topic Filter: $streams/v1/events/partitions/3

Broker -> Client: UNSUBACK
  Packet Identifier: 24
  Reason Codes: [0x00, 0x00, 0x00, 0x00] (Success for each filter)
```

#### Replay and reconnect

To restart an explicit subscription to partition `1` of `telemetry` after processing the record at offset `58`, include the ID learned from `SUBACK` with the saved numeric position:

```text
Client -> Broker: SUBSCRIBE
  Packet Identifier: 22
  Subscription Identifier: 102
  User Properties:
    stream-id: s-9f3c
    partition-offset/1: 59
  Payload:
    Topic Filter: $streams/v1/telemetry/partitions/1
    Subscription Options: 0x21
```

Subscriptions to partitions `0` and `2` continue. A replay uses an earlier valid position. Already in-flight deliveries can outlive unsubscription or replacement; clients complete their MQTT acknowledgment exchange and identify them by partition and old Subscription Identifier. The broker MUST preserve that identifier on retransmission. Clients MUST NOT advance a restarted partition's saved position from old deliveries.

| Situation | Behavior |
| --- | --- |
| A new `SUBSCRIBE` replaces the same Topic Filter | Validate first, then restart at the newly requested offset with the new Subscription Identifier. A rejected replacement leaves the existing subscription unchanged. |
| Stop or pause selected explicit subscriptions | `UNSUBSCRIBE` their exact subscription strings. Resume with a new `SUBSCRIBE` and an explicit position for each partition. |
| Switch from all partitions to a subset or saved numeric positions | `UNSUBSCRIBE` the `/partitions/+` filter, then subscribe to explicit partition filters with the saved stream ID and position for each selected partition. |
| Reconnect without an MQTT session | Send new `SUBSCRIBE` packets using application-saved positions and stream IDs. |
| Reconnect with Session Present `1` | MQTT session state includes each subscription's pinned stream ID and partition set, resolved positions, delivery cursors, and in-flight QoS 1 records. Continue transport delivery; do not re-evaluate `earliest` or `latest`. To replay from application-saved progress, use explicit partition subscriptions. |
| Stream deleted and recreated | Existing subscriptions remain bound to the old ID and fail; they MUST NOT attach to the replacement stream. |

Persisted MQTT delivery state is separate from application processing progress. The broker MUST recover the cursor together with in-flight deliveries without skipping records. Session expiry or loss does not erase records still retained in the stream. Subscriptions MUST NOT hold back retention; a delivery cursor that falls behind retention produces an explicit error. Already in-flight records may still be retransmitted after their stream retention expires.

#### Subscription errors

An invalid initial position is rejected for that partition in `SUBACK`; the broker MUST NOT silently clamp it to retained history. Here partition `0` succeeds and partition `1` fails:

```text
Client -> Broker: SUBSCRIBE
  Packet Identifier: 23
  Subscription Identifier: 103
  User Properties:
    stream-id: s-9f3c
    partition-offset/0: 100
    partition-offset/1: 20
  Payload:
    Topic Filter: $streams/v1/telemetry/partitions/0
    Subscription Options: 0x21
    Topic Filter: $streams/v1/telemetry/partitions/1
    Subscription Options: 0x21

Broker -> Client: SUBACK
  Packet Identifier: 23
  Reason Codes: [0x01, 0x83] (Granted QoS 1; Implementation specific error)
  User Properties:
    stream-id: s-9f3c
    partition-offset/0: 100
    partition-start-offset/0: 100
    partition-end-offset/0: 113
    stream-error/1: OFFSET_OUT_OF_RANGE
    partition-start-offset/1: 41
    partition-end-offset/1: 59
```

If retention overtakes an active subscription, the broker stops it and sends an error on the affected partition's concrete topic. For an all-partitions subscription, this stops delivery from every partition in that subscription; other subscriptions continue. An error on the explicit subscription to partition `1` looks like this:

```text
Broker -> Client: PUBLISH
  Topic Name: $streams/v1/telemetry/partitions/1
  QoS: 1
  RETAIN: 0
  Packet Identifier: 301
  Subscription Identifier: 102
  Content Type: application/json
  User Properties:
    stream-message-kind: error
    stream-id: s-9f3c
    stream-partition: 1
    stream-error: OFFSET_OUT_OF_RANGE
  Payload: {"position":"59","start_offset":"70","end_offset":"95"}

Client -> Broker: PUBACK
  Packet Identifier: 301
  Reason Code: 0x00 (Success)
```

Error notifications have the identity properties above and a JSON object payload. `OFFSET_OUT_OF_RANGE` includes all three shown positions; other errors use `{}` unless specified otherwise. Error notifications carry no `partition-next-offset` and do not advance processing progress. The subscription remains stopped until replaced or unsubscribed; records already in flight may still arrive. This also applies after session resumption.

`STREAM_DELETED`, `UNAVAILABLE`, and `RECORD_TOO_LARGE` use the same notification form. The broker MUST NOT skip a record that exceeds the client's Maximum Packet Size. If even the error notification cannot fit, it disconnects with reason `0x95` (Packet too large), without advancing past the undelivered record.

### Error codes and acknowledgment rules

Use standard MQTT Reason Codes plus a machine-readable error User Property: `stream-error/<partition>` for an explicit partition filter's `SUBACK` result, or `stream-error` for an all-partitions filter, `PUBACK`, delivery notification, or error applying to the whole stream request. Human-readable Reason String is optional and MUST NOT be parsed for protocol decisions.

| `stream-error` | MQTT acknowledgment reason | Meaning |
| --- | --- | --- |
| `INVALID_REQUEST` | `0x83` | Missing, repeated, invalid, or unsupported request fields/options, including a numeric start offset without `stream-id`. |
| `STREAM_NOT_FOUND` | `0x83` | No stream exists with that name. |
| `STREAM_ID_MISMATCH` | `0x83` | Name exists, but expected ID differs. |
| `PARTITION_NOT_FOUND` | `0x83` | Partition is outside the stream's configured range. |
| `OFFSET_OUT_OF_RANGE` | `0x83` (`SUBACK`) | Position is below start or above end; include `partition-start-offset/<partition>` and `partition-end-offset/<partition>`. |
| `NOT_AUTHORIZED` | `0x87` | Read, append, describe, or original-topic publish permission denied. |
| `TOPIC_MISMATCH` | `0x90` (`PUBACK`) | Append's original topic is invalid or does not match the stream filter. |
| `INVALID_FILTER` | `0x8F` (`SUBACK`) | Filter is neither a valid explicit partition filter nor the supported all-partitions filter. |
| `KEY_EVALUATION_FAILED` | `0x83` (`PUBACK`) | Stream key expression could not produce a key. |
| `RECORD_TOO_LARGE` | `0x83` (`PUBACK`) | Record exceeds the stream's append or per-partition byte limit. |
| `QUOTA_EXCEEDED` | `0x97` | Append rejected by a hard limit, or subscription resource budget exhausted. |
| `UNAVAILABLE` | `0x83` | Required storage authority unavailable before the operation was accepted. |

Authorization is checked before returning stream identity or bounds. An all-partitions filter requires read permission on every partition. A failed filter creates no new subscription and leaves any previous subscription to that filter unchanged.

Errors in shared request fields, mixed stream names, mixed all-partitions and explicit filters, duplicate filters, or offset properties for unselected partitions reject all stream filters in the packet with `INVALID_REQUEST`. The all-partitions form rejects numeric `partition-offset` values or any `partition-offset/<partition>` properties. The explicit form rejects an unsuffixed `partition-offset`; missing, duplicated, or invalid offsets for a selected partition reject that partition. An invalid filter receives `0x8F` without partition-keyed properties. Ordinary filters, if present, are handled normally.

If an append's storage outcome is uncertain, the broker MUST NOT report a definite rejection. It closes the connection with `DISCONNECT` reason `0x80` (Unspecified error), and the client treats any append without a definitive `PUBACK` as having an unknown outcome.

If Request Problem Information is `0`, reject stream append/subscription requests with `0x83` and omit User Properties. Check the full acknowledgment size before applying any stream subscription changes. If its required properties cannot fit the client's receive limit, reject all stream filters with `0x83`, including `stream-error: INVALID_REQUEST` only if it fits; append uses the same rejection rule. If even the minimal acknowledgment cannot fit, disconnect with reason `0x95`. Clients MUST handle a negative MQTT reason without diagnostic properties.

For an unsupported QoS on append or describe, reject QoS 2 with `PUBREC` reason `0x83`, or QoS 0 with `DISCONNECT` reason `0x83`, before performing the operation. Reject RETAIN `1` with `INVALID_REQUEST` and do not retain the request. Malformed MQTT packets follow MQTT's own error handling.

### Client-library requirements

No Streams SDK is required. A client library supporting this API needs the following MQTT capabilities:

| Capability | Required behavior |
| --- | --- |
| Subscription requests | Set a Subscription Identifier; support the all-partitions filter with `partition-offset`, and multiple explicit filters with `partition-offset/<partition>` properties in one `SUBSCRIBE`. |
| Acknowledgment results | Expose `PUBACK` and `SUBACK` reason codes and User Properties. Treat a success missing required protocol properties as an incompatible response, not proof that the stream operation succeeded. |
| Record callbacks | Expose raw payload, Topic Name, Subscription Identifier, and all protocol User Properties; route by identifier and partition and distinguish `record` from `error` using `stream-message-kind`. |
| Offset values | Preserve base-10 strings or use lossless integer types; do not round through floating-point numbers. |
| Reconnect | Let the application select saved offsets; do not automatically restart from an unresolved `latest` selector. |
| Flow control | Expose Receive Maximum and bound buffers. Manual acknowledgments, if offered, must preserve MQTT acknowledgment ordering across the connection. |

### Management: describe a stream

Describe uses MQTT request/response to discover partition count, bounds, and configuration. Initial `earliest`/`latest` subscriptions to all or known partitions need no describe request; neither does resuming with a saved stream ID and offsets. Stream creation, policy updates, and deletion remain deployment management operations.

The client subscribes to an authorized private response topic and waits for `SUBACK` before publishing the request. The broker checks both stream access and the client's right to receive on the Response Topic; other clients MUST NOT be able to forge replies on that topic. The request is handled internally, not forwarded to subscribers of the describe topic.

```text
Client -> Broker: SUBSCRIBE
  Packet Identifier: 30
  Payload:
    Topic Filter: clients/reader-7/stream-replies
    Subscription Options: 0x21

Broker -> Client: SUBACK
  Packet Identifier: 30
  Reason Codes: [0x01] (Granted QoS 1)

Client -> Broker: PUBLISH
  Topic Name: $streams/v1/telemetry/describe
  QoS: 1
  RETAIN: 0
  Packet Identifier: 31
  Response Topic: clients/reader-7/stream-replies
  Correlation Data: 0x01020304
  Content Type: application/json
  Payload: {}

Broker -> Client: PUBACK
  Packet Identifier: 31
  Reason Code: 0x00 (Success)

Broker -> Client: PUBLISH
  Topic Name: clients/reader-7/stream-replies
  QoS: 1
  RETAIN: 0
  Packet Identifier: 400
  Correlation Data: 0x01020304
  Content Type: application/json
  Payload:
    {"status":"ok","name":"telemetry","stream_id":"s-9f3c",
     "topic_filter":"devices/#","partition_count":3,
     "partitions":[
       {"partition":0,"start_offset":"100","end_offset":"113"},
       {"partition":1,"start_offset":"41","end_offset":"59"},
       {"partition":2,"start_offset":"7","end_offset":"10"}],
     "key_expression":"message.from","key_rule_version":"1",
     "max_record_bytes":1048576,
     "retention":{"limit_mode":"soft","max_age_ms":86400000,
       "max_records_per_partition":null,"max_bytes_per_partition":null,
       "overflow":"drop_old"}}

Client -> Broker: PUBACK
  Packet Identifier: 400
  Reason Code: 0x00 (Success)
```

The shown success fields are required. The key-rule version is opaque; clients need not reproduce broker routing. Partition bounds are observed independently, not as a cross-partition snapshot. `max_record_bytes` limits the stored record size as defined below, not the MQTT packet size. `null` means an unlimited retention setting.

The request body is `{}` or `{"stream_id":"s-9f3c"}` to check an expected identity. Response Topic, Correlation Data, and Content Type `application/json` are required. A result error is JSON, for example `{"status":"error","code":"STREAM_ID_MISMATCH"}`. Valid requests receive one logical result with exactly the request's Correlation Data; QoS 1 duplicates are possible. Malformed or unauthorized requests may be rejected with a negative `PUBACK` and no result. If the response cannot fit the client's Maximum Packet Size, reject the request with `QUOTA_EXCEEDED` before accepting it. Here, successful request `PUBACK` acknowledges transport acceptance only; the correlated result completes discovery. Describe requests are read-only and may be retried with new Correlation Data after a timeout.

### Retention and storage requirements

| Setting | Effect, independently for each partition |
| --- | --- |
| `max_age_ms` | Expire old records regardless of count or byte settings. |
| `max_records_per_partition` | Bound retained record count. |
| `max_bytes_per_partition` | Bound retained bytes. |
| `overflow: drop_old` | Expire the oldest prefix to make room. |
| `overflow: reject_new` | Reject the new append without removing history for that attempt; requires hard limits. |
| `limit_mode: soft` | Track usage off the write path; count/byte limits may be exceeded until expiration catches up within an advertised lag bound. Only `drop_old` is allowed. |
| `limit_mode: hard` | Atomically check usage, expire if needed, and append; count/byte limits are never exceeded by an append. |

Soft limits ship first. Hard limits and `reject_new` require a backend prototype that meets a throughput budget agreed during review; until supported, management rejects that configuration.

- Retained bytes count the uncompressed broker-encoded record once, including framing, topic, key, timestamp, optional message ID, and payload. Physical replicas and indexes are separate metrics.
- A record larger than `max_record_bytes` or `max_bytes_per_partition` is rejected before storing it or dropping history.
- Persist the new `start_offset` before reclaiming data. Expiration MUST NOT remove another partition's records outside that partition's policy, even when physical storage is shared.
- Age expiration uses persisted, nondecreasing append-age metadata; advertise expiration lag and clock assumptions. Acceptance timestamps and offsets are not expiration clocks for clients.
- Serialize retention-policy revisions with partition writes. Expose desired and effective revisions during a rollout; lowering a hard `reject_new` limit can block writes until existing usage fits. Raising a limit cannot restore history.
- Recover stream identities, partition bounds, acknowledged appends, and policy state consistently. A historical restore or import receives a new stream ID. Offset allocation MUST remain monotonic through failover and storage rotation.

Storage selection is an implementation decision. Existing Durable Storage, a stream-specific DS layout, and a dedicated backend remain candidates. Each must prove ordered partition reads, stable offsets and bounds, retention isolation, bounded delivery buffering, and the durability contract above. No consumer-group control store or coordination mechanism is selected by this EIP.

## Configuration Changes

Partitioned streams add immutable `partition_count`, `key_expression`, `key_rule_version`, and `limit_mode`. The default key expression is `message.from`; partitioned-format expressions may use only `message.topic`, `message.payload`, and `message.from`. Expression syntax and supported key-rule versions are implementation-defined and validated at creation.

Retention settings are `max_age_ms`, `max_records_per_partition`, `max_bytes_per_partition`, and `overflow`. Limits accept positive values or explicit unlimited; omission uses deployment defaults at creation. `soft` and `drop_old` are the defaults. Also configure and expose record-size limits, subscription resource budgets, and soft-limit expiration lag. Failed stream writes are counted per stream.

Exact EMQX configuration paths and default limit values remain implementation choices; they do not change the packet contract.

## Backwards Compatibility

- Ordinary MQTT publishers, including MQTT 3.1.1 publishers, need no changes. The API defined here requires MQTT 5.0.
- Existing `$stream/<name>` subscriptions remain available. On partitioned streams this compatibility subscription merges partitions without cross-partition ordering; it is separate from the versioned API above.
- Legacy `earliest`, `latest`, and timestamp selectors retain their existing meaning. Timestamp selectors resolve per partition against stored acceptance time and do not become stable offset bookmarks.
- Legacy deliveries retain `ts` and `key` properties and add `stream-id`, `partition`, and `offset` for identifying records. New applications use the topics and property names specified above.
- Last-value streams keep their existing format and API. Recreating a stream in the partitioned format or importing history allocates a new stream ID; old offsets MUST NOT silently apply to it.

## Declined Alternatives

- **Start offsets in Topic Filters**, for example `$streams/v1/telemetry/partitions/0/earliest`: this makes each subscription entry self-contained and removes the mapping to offset User Properties. Changing `earliest` to `100`, however, creates another MQTT subscription; replacing the replay requires unsubscribing the original filter and subscribing to the new one. Delivery topics must also retain the original selector to match the filter. Keeping offsets in properties preserves a stable partition filter: a new `SUBSCRIBE` can replace its replay position, and `UNSUBSCRIBE` does not depend on the starting offset.
- **Consume through request/response `open` and `fetch` commands:** consumers use standard `SUBSCRIBE`, `PUBLISH`, and `UNSUBSCRIBE`; no reader handles or fetch protocol are needed.
- **Broker-assigned subsets of partitions:** callers select all partitions or name fixed partitions and replay positions. Assignment and rebalancing belong in the consumer-group proposal.
- **Treat delivery acknowledgments as processing checkpoints:** MQTT receipt does not establish completed application work. This proposal leaves processing positions with the application.
- **Expose physical shards or DS cursors:** replay positions must survive storage layout changes and failover.
- **Reuse the `$stream/` namespace for versioned protocol topics:** existing stream names could collide with fixed protocol path segments.
