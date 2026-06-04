# Session Buffer Byte Observability

## Changelog

* 2026-06-04: @hjianbo Clarify missing configuration behavior during upgrades.
* 2026-06-02: @hjianbo Initial draft.

## Abstract

This proposal adds lightweight observability for payload bytes retained by MQTT
memory-session buffers.

Today EMQX limits session buffering mainly by message count
(`mqtt.max_mqueue_len`).  A small number of large payloads can still retain a
large amount of resident memory in the session mqueue and inflight window.  This
proposal exposes that payload volume per session, adds throttled warning logs,
and provides an on-demand cluster top-K CLI for diagnosis.

## Motivation

Large MQTT payloads are stored as Erlang refc binaries.  These referenced
binaries are not counted as ordinary heap memory of the session process, so
existing heap-size based `force_shutdown` policies cannot protect a node from
this specific memory-retention pattern.

The risk becomes more visible during reconnect storms or session takeover.
A session holding hundreds of MB, or even GB, of buffered payloads may
cause a sharp VM memory spike when its state is transferred to a new owner.
Many concurrent takeovers can further increase Erlang distribution pressure
and make the node harder to diagnose.

## Design

### User-facing data

Expose this field in memory-session data returned by client/session APIs such as
`/clients`, `/clients_v2`, and `/clients/{clientid}`:

* `total_payload_bytes`

`total_payload_bytes` is the sum of MQTT payload bytes currently retained by the
session mqueue and inflight window.

It does not include topic, headers, MQTT properties, or internal
Erlang record overhead.

Note: Durable sessions report `0` for this field because their buffered state is
not held by the memory-session mqueue/inflight structures.

### Warning logs

When one memory session's `total_payload_bytes` is above
`buffered_payload_high_watermark`, EMQX emits a throttled warning log.  The log
is for diagnosis only and does not change MQTT delivery, mqueue eviction,
inflight handling, or session takeover behavior.

The warning log should include:

* `clientid`
* `pid`
* `mqueue_length`
* `inflight_count`
* `total_payload_bytes`
* `buffered_payload_high_watermark`

The log is checked from the existing session stats path, not on every message
operation.  Throttling prevents repeated logs from the same long-lived high
buffer session.

### Cluster top-K CLI

Add an on-demand cluster-level CLI:

```bash
emqx ctl session-top --count <K> --sort <mqueue_length|total_payload_bytes> --out <file>
```

Arguments:

* `--count <K>`: number of sessions to return.  The default is `10`; the maximum
  is `1000`.
* `--sort`: sort key.  Supported values are `mqueue_length` and
  `total_payload_bytes`.
* `--out <file>`: required output path.  The command writes CSV instead of
  printing potentially large results to the console.

CSV columns:

```csv
clientid,pid,node,mqueue_length,total_payload_bytes,inflight_count
```

The command is asynchronous.  A named worker process owns the scan so EMQX can
control concurrency and scan pace.  The CLI starts the task and reports where
the result will be written.

The scan is cluster-level:

* the initiating node asks all running nodes to scan local cached session data;
* each node returns only its local top K;
* the initiating node merges and re-sorts the partial results;
* the final top K is written to the requested CSV file.

## Configuration Changes

Add minimal configuration for warning logs:

```hocon
sysmon.session {
  buffered_payload_high_watermark = 0
}
```

The field is:

* `buffered_payload_high_watermark`: per-session `total_payload_bytes` threshold
  for emitting warning logs.  `0` disables the warning log.  The session payload
  byte counter remains available regardless of this value.

During rolling or hot upgrade, older running configurations may not contain this
field yet.  Runtime reads must treat a missing `sysmon.session` section, a
missing `buffered_payload_high_watermark` field, or an `undefined` value as the
default value `0`.

## Implementation

### Cached session data

The maintained counter is exposed through the existing session stats and
cached in channel info together with other session fields.  API reads and CLI
scans read the cached values rather than asking every session process to inspect
its buffered messages.

The value is an operational gauge.  It is as fresh as the session stats and
channel-info update path.

### Top-K scan worker

The top-K CLI scan is performed by a named worker process.

The worker should:

* allow only a bounded number of active scans, preferably one per node in the
  first implementation;
* scan local channel-info cache with controlled pacing;
* keep a bounded local top K instead of materializing all sessions;
* return only local top K rows to the initiating node;
* merge partial results on the initiating node and write the final CSV.

For `N` local sessions and requested `K`, local memory usage should be `O(K)` and
scan CPU should be `O(N log K)` or better.

## Backwards Compatibility

This is a new optional configuration field.  Existing configurations remain
valid.  During rolling or hot upgrade, nodes that have not materialized the new
configuration default must behave as if `buffered_payload_high_watermark = 0`.

## Document Changes

If accepted and implemented, update:

* configuration reference for `sysmon.session`;
* management API docs for the new client/session field;
* CLI documentation for `emqx ctl session-top`;

## Testing Suggestions

If accepted and implemented, verify:

* `total_payload_bytes` is updated when messages enter or leave mqueue and
  inflight;
* client/session APIs expose the field, and durable sessions report `0`;
* warning logs are emitted above `buffered_payload_high_watermark` and throttled
  while a session remains above the watermark;
* `session-top` returns the requested cluster top K and writes CSV output.

## Declined Alternatives

### Periodic node aggregation, Prometheus gauges, and alarms

An earlier design added:

* node-level `/stats` totals for all local sessions;
* Prometheus gauges for local-node buffered bytes;
* periodic node sampling over channel info;
* a node-level alarm with a bounded `top_clients` list;
* a client-level high-watermark alarm.

This was declined for the initial design.

The periodic scan adds continuous O(local sessions) background work, which is
hard to justify for very large nodes.  The alarm behavior also introduces
threshold and clear semantics that are easy to make noisy or misleading.  Other
similar observability signals, such as mqueue length and mailbox length, do not
have dedicated alarms.  The lighter approach is to expose one per-session gauge,
emit throttled warning logs, and provide an explicit top-K diagnostic CLI.

### Whole-message size accounting

An earlier design used:

```erlang
message_bytes(Msg) ->
    erlang:external_size(Msg).
```

This was declined for the initial design.  `external_size/1` estimates the
external term format size, not exact VM resident memory.  It also traverses the
whole message term and counts fields outside the main risk being targeted here.

The initial design uses `byte_size(Payload)` instead.  This is cheaper, avoids
term traversal, and keeps the user-facing field semantics clear: payload bytes
retained by memory-session buffers.

## Open Questions

### Should EMQX add aggregate metrics and alarms?

This proposal declines these two features for the initial implementation because
of implementation complexity, runtime overhead, and the risk of frequent
per-client memory alarms.  They may still be useful in the future:

1. Aggregate metrics would help operators chart usage over time and allow
   external monitoring systems to alert on this signal.
2. Built-in EMQX alarms would proactively notify operators of possible runtime
   risk, instead of requiring passive investigation through logs and CLI
   commands.

### Should EMQX add a byte-volume limit?

This EIP focuses on observability.  A follow-up design may add a per-session
limit for session-buffer payload bytes.
