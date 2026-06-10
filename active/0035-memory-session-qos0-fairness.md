# Improve Memory Session Fairness for QoS 0 Under Mailbox Pressure

## Changelog

* 2026-02-14: @zmstone Initial draft.
* 2026-03-02: @zmstone Use send-count based sampling interval.
* 2026-06-10: @zmstone Drop mailbox-busy signal.

## Abstract

This proposal improves memory-session behavior under send-path pressure by preventing Erlang mailbox growth (large mailboxes MAY significantly increase message processing overhead) and by improving fairness between QoS 0 and QoS 1/2 under stress.

Today, QoS 0 is sent immediately while QoS 1/2 are constrained by inflight and may be queued. Under transport-send pressure this lets QoS 0 traffic both pile up in the process mailbox and starve already-queued QoS 1/2 messages.

This proposal removes the immediate-send fast path for QoS 0 on online sessions. **All deliveries — including QoS 0 — enter `mqueue`**. `emqx_mqueue` is extended with a dedicated internal FIFO for QoS 0, separate from the existing `emqx_pqueue` used for QoS 1/2. The session sees a single `in/2` / `out/1` API; the QoS-0 buffer is invisible from outside. Scheduling is strict: `out/1` drains the QoS 1/2 pqueue first and only returns a QoS 0 message when the pqueue is empty. Each buffer has its own length cap, so QoS 0 overflow can only evict other QoS 0 messages and never QoS 1/2. The existing topic-priority machinery (`mqueue.priorities`, `mqueue_default_priority`) is untouched and continues to apply to QoS 1/2 only. No runtime busy signal, no mailbox sampling, no new user-facing tuning knobs.

## Motivation

```
                publisher (PUBLISH at QoS 0)
                          │
                          ▼
                ┌────────────────────────┐
                │       EMQX broker      │
                │   do_dispatch_chans    │
                └────────────┬───────────┘
                             │  SubPid ! #deliver{Msg(qos=0)}
                             ▼
 ╔══ subscriber connection process ═══════════════════════════════════╗
 ║                                                                    ║
 ║   ┌─────────────────────────────────────────┐                      ║
 ║   │  Erlang process mailbox                 │  ◄── ⚠ QoS 0         ║
 ║   │  unbounded queue of #deliver{} records  │      overflow path   ║
 ║   │  cap: force_shutdown.max_mailbox_size   │      proc KILLED at  ║
 ║   │       = 1 000 000  →  KILL              │      max_mailbox_size║
 ║   └────────────────────┬────────────────────┘      (session reset) ║
 ║                        │ receive (one-by-one)                      ║
 ║                        ▼                                           ║
 ║   ┌─────────────────────────────────────────┐                      ║
 ║   │  emqx_session:enrich_message/4          │                      ║
 ║   │     if upgrade_qos: QoS := SubQoS       │                      ║
 ║   └────────────────────┬────────────────────┘                      ║
 ║                        │                                           ║
 ║                ┌───────┴────────┐                                  ║
 ║              QoS 0           QoS ≥ 1                               ║
 ║                │                │                                  ║
 ║                │                ▼                                  ║
 ║                │       ┌────────────────┐  full                    ║
 ║                │       │ inflight (≤32) ├──────────┐               ║
 ║                │       └────────┬───────┘          │               ║
 ║                │                │ room             ▼               ║
 ║                │                │         ┌────────────────┐       ║
 ║                │                │         │ mqueue (≤1000) │       ║
 ║                │                │         │                │  ◄── ⚠ QoS 1
 ║                │                │         │ overflow→drop  │      overflow
 ║                │                │         │  + counter     │      path
 ║                │                │         └────────┬───────┘      bounded,
 ║                │                │                  │drop          metered
 ║                │                │                  ▼              drop
 ║                │                │                ─ ✕ ─            (proc
 ║                │                ▼                                  survives)
 ║                └────► port_command / gen_tcp:send                  ║
 ║                              │  blocks on busy_port →              ║
 ║                              │  proc suspended waiting on socket   ║
 ║                              ▼                                     ║
 ╚══════════════════════════════│═════════════════════════════════════╝
                                ▼
                    kernel TCP send buffer
                                │
                                ▼  TCP / network
                          subscriber client
```

Primary goal:

- Prevent mailbox accumulation in connection/channel process under send pressure.

Secondary goal:

- Improve QoS fairness by reducing QoS 0 immediate-send bypass while pressure
  exists.

Why this approach:

1. It directly targets observed operational pain (mailbox growth) by giving every
   delivery a single bounded buffer (`mqueue`) instead of two unbounded ones
   (mailbox + immediate-send path).
2. It avoids adding any user-facing configuration knob and removes the need for
   any runtime busy/pressure signal.
3. It is transport-mode-agnostic (`tcp`, `ssl`, `socket(tcp)`) — the scheduling
   decision is made entirely inside the session, independent of the socket
   backend.
4. Fairness becomes a static property of `mqueue` priority ordering, not a
   sampled-state heuristic that can lag or oscillate.

## Design

### Scope

This EIP changes memory-session scheduling (`emqx_session_mem`) and the
`emqx_mqueue` data structure. It does not redesign transport send pipeline or
add a new writer process.

### Current behavior summary

In `deliver_msg/3`, QoS 0 has an immediate-send path. QoS 1/2 are constrained
by inflight and can enter `mqueue`.

`emqx_mqueue` today wraps a single `emqx_pqueue` (`#mqueue.q`) and supports
priorities selected per-topic via `mqueue.priorities` (`p_table` in code),
with `default_priority` for unmatched topics. There is no QoS-aware override.
Two facts about the existing primitive are load-bearing for this proposal:

- The topic-priority numbers configured by operators in `mqueue.priorities`
  are positioned relative to `default_priority`. Repurposing those numbers
  for QoS-vs-QoS ordering would silently change the meaning of every
  operator-set entry. The new QoS-0 buffer therefore must NOT live in the
  same priority space.
- Priority `0` in `emqx_pqueue` is an optimisation slot — when the queue
  only contains priority-`0` items it stays in the flat `{queue, _, _, _}`
  shape. We want to preserve this for the common "no priorities configured"
  case.

### Proposed fairness rule

For online sessions, deliveries are scheduled as follows:

- **QoS 1/2**: as today — try inflight; if inflight is full, enqueue into
  the existing pqueue inside `mqueue` (`#mqueue.q`). All existing
  topic-priority behaviour is preserved unchanged.
- **QoS 0**: **always** enqueue into a new internal FIFO inside `#mqueue{}`
  (`#mqueue.qos0_q`), a plain `queue:queue()`. The immediate-send fast path
  is removed.

Scheduling is strict priority across the two buffers:

- `emqx_mqueue:out/1` drains `#mqueue.q` (QoS 1/2) until empty, then drains
  `#mqueue.qos0_q` (QoS 0).
- Within each buffer, ordering is unchanged: pqueue scheduling for QoS 1/2,
  FIFO for QoS 0.

Strict priority is acceptable here — and intentional — because QoS 0 is
at-most-once. Dropping or deferring QoS 0 under sustained QoS 1/2 pressure
is MQTT-legal, and is the desired outcome of this EIP: the durable classes
take precedence over the best-effort class.

### `#mqueue{}` shape and overflow

The `emqx_mqueue` opaque record gains a small number of fields:

```
-record(mqueue, {
    ...                                   %% existing fields unchanged
    q          :: emqx_pqueue:q(),        %% existing — QoS 1/2 only
    qos0_q     :: queue:queue(),          %% new — QoS 0 only
    qos0_len   = 0  :: non_neg_integer(),
    qos0_max_len   :: non_neg_integer(),  %% bound for qos0_q
    qos0_dropped = 0 :: non_neg_integer()
}).
```

Each buffer has an independent length cap and drop counter:

- `qos0_q` overflow drops the oldest QoS 0 message (`queue:out/1` of the
  head), increments `qos0_dropped`, and enqueues the new one.
- `q` overflow keeps its existing semantics (per-priority `max_len`, drop
  oldest of the same priority).

The session-level `info/1` and `stats/1` outputs are extended with
`qos0_len`, `qos0_max_len`, and `qos0_dropped` so operators can observe the
QoS 0 buffer independently of the QoS 1/2 mqueue.

### Routing inside `emqx_mqueue:in/2`

`in/2` gains one extra clause for QoS 0 (placed AFTER the existing
`store_qos0 = false` drop clause so offline semantics are preserved):

- `#message{qos = 0}` with `store_qos0 = true`: enqueue to `qos0_q`, apply
  `qos0_max_len`, update counters.
- All other messages: existing path unchanged (pqueue, topic priorities,
  per-priority `max_len`).

### Configuration

A single new internal constant controls the QoS-0 buffer bound:

- `qos0_max_len` — same units as `max_len`. Default: same value as `max_len`
  unless tests show a different default is warranted. May be promoted to a
  user-facing config later if operators need to tune it independently; this
  EIP does not commit to that.

The existing `mqueue.priorities`, `mqueue_default_priority`,
`mqueue_store_qos0`, and `max_len` settings keep their current meaning and
scope (QoS 1/2 only for the priority-related ones; `store_qos0` continues to
gate whether QoS 0 is buffered at all).

### Takeover and rolling-upgrade compatibility

Session takeover serialises `#mqueue{}` between processes (and across nodes
during rolling upgrades). The new `qos0_q` and its counters are NOT included
in the takeover payload:

- The takeover encoder strips `qos0_q`, `qos0_len`, `qos0_dropped` before
  sending.
- The receiving side reconstructs them as an empty queue with the local
  `qos0_max_len`.

This is sound because QoS 0 is at-most-once: dropping the in-buffer QoS 0
backlog at takeover is MQTT-legal. The consequence for rolling upgrades is
that old nodes and new nodes can take over each other's sessions without
schema negotiation — old → new sees an empty `qos0_q`, new → old simply
omits it. No BPAPI version bump is required for this field.

### Offline behavior and `store_qos0`

Offline semantics are preserved at the user-visible level:

- If session is offline and `mqueue_store_qos0 = false`, QoS 0 is dropped
  on arrival (the existing first `in/2` clause).
- If session is offline and `mqueue_store_qos0 = true`, QoS 0 is enqueued
  into `qos0_q` and is subject to `qos0_max_len`. When the session
  reconnects, `qos0_q` is drained after `q` is empty.

### Why drop the busy signal

Earlier drafts gated QoS 0 on a sampled `mailbox_busy` flag. Moving the
gating into a separate QoS-0 buffer inside `mqueue` is strictly better:

- No sampling cadence to tune; no sampled-state lag or oscillation.
- One bounded buffer per traffic class — the connection-process mailbox
  cannot accumulate QoS 0 deliveries that the session has already accepted,
  because every delivery is taken into `mqueue` immediately rather than
  being dispatched through the send fast path.
- The QoS 1/2 path and its topic-priority semantics are untouched, so the
  change is local to a single module.

## Configuration Changes

No new user-facing configuration is introduced.

The existing `mqueue.max_len`, `mqueue.priorities`, `mqueue_default_priority`,
and `mqueue_store_qos0` settings keep their current meaning and continue to
apply to the QoS 1/2 pqueue only. The new `qos0_max_len` is an internal
constant (defaulted from `max_len`); it may be promoted to a user-facing
knob in a follow-up if operators need to tune it independently.

## Backwards Compatibility

Protocol compatibility is unchanged.

Behavior changes for online sessions:

- QoS 0 is always routed through `mqueue` (specifically its new `qos0_q`
  buffer) instead of being sent immediately. In a healthy, idle session
  this adds one enqueue/dequeue step per QoS 0 message but does not change
  observable ordering for a given publisher/subscriber pair (the QoS-0
  buffer is FIFO).
- Under backlog, QoS 0 may be deferred or dropped while QoS 1/2 drains.
  This is the intended fairness trade-off; it is MQTT-legal because QoS 0
  is at-most-once.

Offline QoS 0 behavior (`mqueue_store_qos0 = false` drops on arrival,
`= true` enqueues) is unchanged at the user-visible level; with `= true` the
stored QoS 0 messages now live in the dedicated `qos0_q` buffer rather than
the pqueue.

Takeover: rolling upgrades work without a BPAPI bump for this field. The
takeover encoder strips `qos0_q` / `qos0_len` / `qos0_dropped` before
sending, and the receiver reconstructs an empty QoS-0 buffer. Old ↔ new
node takeovers therefore see no schema mismatch; the cost is that the
in-buffer QoS 0 backlog (which is best-effort by definition) is dropped at
takeover.

## Document Changes

If accepted and implemented, update:

- Session scheduling docs to describe that all online deliveries enter
  `mqueue` and that QoS 0 lives in a dedicated FIFO inside `#mqueue{}`
  drained after the QoS 1/2 pqueue.
- `mqueue` overflow documentation: independent caps and drop counters for
  the QoS 1/2 pqueue and the QoS 0 FIFO.
- Release notes with operational effect: better stability/fairness under
  stress with possible QoS 0 throughput trade-off during pressure windows.

## Testing Suggestions

### Targeted tests

- `emqx_mqueue` unit tests:
  - `in/2` routes `#message{qos = 0}` to `qos0_q` and other QoS to `q`.
  - `store_qos0 = false` still drops QoS 0 on arrival.
  - `qos0_q` overflow drops the oldest QoS 0 message and bumps
    `qos0_dropped`; never touches `q`.
  - Filling `q` (existing per-priority `max_len`) never touches `qos0_q`.
  - `out/1` drains `q` completely before returning a message from
    `qos0_q`.
  - `info/1` and `stats/1` expose `qos0_len`, `qos0_max_len`,
    `qos0_dropped`.
- Session-level tests:
  - Under heavy QoS 1/2 backlog, QoS 0 is held back (strict priority) but
    QoS 1/2 ack latency is not regressed by the QoS 0 backlog.
  - Idle / no-backlog QoS 0 delivery still works end-to-end (latency budget
    increases by one enqueue/dequeue but ordering is preserved).
  - Offline behavior unchanged for `mqueue_store_qos0 = false` and `true`.
  - Topic-priority configuration in `mqueue.priorities` still orders QoS 1/2
    correctly and is not affected by QoS 0 traffic.
- Takeover tests:
  - QoS-0 buffer is dropped (becomes empty) after takeover, regardless of
    whether takeover crosses node versions.
  - QoS 1/2 mqueue contents are preserved across takeover as today.

### Regression tests

- Run `emqx_session_mem_SUITE`, `emqx_mqueue_SUITE`, and `emqx_channel_SUITE`.

### Manual/benchmark validation

- Mixed QoS benchmark under constrained client receive speed.
- Observe:
  - connection-process mailbox length distribution before/after,
  - QoS 1/2 ack latency under stress,
  - QoS 0 drop count vs QoS 1/2 drop count during pressure windows,
  - QoS 0 throughput impact in steady state (should be negligible) and
    under pressure (expected to drop).

## Alternative Approaches

### A. Dedicated QoS-0 FIFO inside `#mqueue{}` (this proposal)

Pros:

- No runtime busy signal, no sampling, no new user config.
- Topic-priority numbers in `mqueue.priorities` keep their original meaning
  — QoS-vs-QoS ordering does not share the priority-number space.
- Each buffer has its own bound, so QoS 0 overflow cannot evict QoS 1/2 and
  vice versa.
- No `emqx_pqueue` changes required; the change is local to `emqx_mqueue`.
- Rolling-upgrade safe with no BPAPI bump: QoS 0 is at-most-once, so the
  takeover encoder simply omits the new field and the receiver
  reconstructs an empty buffer.

Cons:

- Removes the QoS 0 immediate-send fast path; idle QoS 0 delivery pays one
  extra enqueue/dequeue per message.
- Worst-case `mqueue` memory grows by `qos0_max_len` (the new QoS-0
  buffer's cap).
- Strict-priority scheduling defers QoS 0 entirely under sustained QoS 1/2
  pressure. Acceptable because QoS 0 is at-most-once.

Reasoning:

- Best balance of operational stability, fairness, and implementation
  complexity, while leaving every existing `emqx_pqueue` and topic-priority
  invariant untouched. Chosen approach.

### A'. QoS 0 as a new `emqx_pqueue` priority band

Considered and rejected: putting QoS 0 in its own band (e.g. priority `-1`)
inside the existing pqueue collides semantically with operator-configured
topic priorities in `mqueue.priorities`, because those numbers are
positioned relative to the default. A separate FIFO sidesteps the conflict.

### B. Mailbox-based busy flag

Sample connection-process mailbox length every N sends; when above a
threshold, route QoS 0 into `mqueue` instead of immediate send.

Pros:

- Preserves the QoS 0 immediate-send fast path in the healthy case.
- No data-structure change in `mqueue`.

Cons:

- Mailbox length is an indirect proxy for transport pressure.
- Sampled state lags reality and can oscillate; thresholds need tuning.
- Still allows QoS 0 to bypass already-queued QoS 1/2 in the no-pressure
  window, so it does not fully solve fairness.

Reasoning:

- Superseded by approach A. Kept here for context — this was an earlier draft.

### C. Latency-based busy signal

Pros:

- Also transport-agnostic.

Cons:

- More state and tuning logic (EWMA, thresholds, counters).
- More likely to trigger "too much configuration" concerns.
- Latency can reflect scheduler/CPU noise, not just socket pressure.
- Latency is rarely constant and frequently varies due to the dynamic nature of network traffic.

Reasoning:

- Kept as fallback if mailbox signal proves insufficient.

### D. Queue-size polling (`port_info(queue_size)` / `getstat(send_pend)`)

Pros:

- More direct backlog metric when available.

Cons:

- Backend-specific behavior differences.
- `getstat` path adds synchronous control-call overhead.
- Per-send polling can increase CPU overhead.

Reasoning:

- Useful as optional enhancement later, not required in this draft.

### E. Full async writer redesign

Pros:

- Potentially best long-term backpressure architecture.

Cons:

- High implementation risk and large surface area.

Reasoning:

- Deferred; too large for first fairness/stability fix.

## Declined Alternatives

- Use send timeout as busy probe.
  Rejected because timeout on real send has ambiguous partial-progress
  semantics and is unsafe as a generic probe.

- Introduce multiple new user-facing fairness tuning knobs in this draft.
  Rejected to keep EMQX configuration surface simple.

