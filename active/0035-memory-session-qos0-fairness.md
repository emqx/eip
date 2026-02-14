# Improve Memory Session Fairness for QoS 0 Under Mailbox Pressure

## Changelog

* 2026-02-14: @zmstone Initial draft.

## Abstract

This proposal improves memory-session behavior under send-path pressure by
preventing mailbox growth and reducing QoS 0 bypass under stress. Today, QoS 0
can still be sent immediately while QoS 1/2 are constrained by inflight and may
be queued, which can increase unfairness and contribute to mailbox buildup when
transport send is slow.

Instead of introducing multiple new configuration knobs, this proposal uses a
simple runtime signal: connection process mailbox length. Periodically, EMQX
samples mailbox length. If the queue is above a fixed threshold, QoS 0 will be
routed to `mqueue` (for online sessions) instead of immediate send. This keeps
the no-pressure fast path unchanged and focuses on the main operational risk:
mailbox explosion.

## Motivation

Primary goal:

- Prevent mailbox accumulation in connection/channel process under send pressure.

Secondary goal:

- Improve QoS fairness by reducing QoS 0 immediate-send bypass while pressure
  exists.

Why this approach:

1. It directly targets observed operational pain (mailbox growth).
2. It avoids adding more user-facing configuration complexity.
3. It is transport-mode-agnostic (`tcp`, `ssl`, `socket(tcp)`), because mailbox
   length is a BEAM-level signal independent of specific socket backend APIs.

## Design

### Scope

This EIP only changes memory-session scheduling (`emqx_session_mem`) and uses
existing connection/channel runtime state. It does not redesign transport send
pipeline or add a new writer process.

### Current behavior summary

In `deliver_msg/3`, QoS 0 has an immediate-send path. QoS 1/2 are constrained
by inflight and can enter `mqueue`.

### Proposed fairness rule

For online session QoS 0 (`#message{qos = 0}`):

- If inflight is full, queue QoS 0.
- If mailbox is busy, queue QoS 0.
- If `mqueue` is non-empty, queue QoS 0.
- Otherwise keep existing immediate-send fast path.

Equivalent gate:

- `need_queue_qos0 = inflight_full OR mailbox_busy OR mqueue_has_backlog`

### Mailbox busy signal

Introduce an internal `mailbox_busy` state derived from periodic sampling of
process mailbox length.

Sampling trigger (choose one, implementation detail):

- every `active_n` sends, or
- existing emit-stats timer cadence.

Signal rule (proposed):

- `mailbox_busy = true` when `message_queue_len > 10`
- `mailbox_busy = false` when `message_queue_len =< 10`

Optional micro-hysteresis (if needed after testing, still no user config):

- set busy at `> 10`, clear at `=< 5`

### Offline behavior and `store_qos0`

Offline semantics remain unchanged:

- If session is offline and `mqueue_store_qos0 = false`, do not enqueue QoS 0.
- If session is offline and `mqueue_store_qos0 = true`, keep existing enqueue
  behavior.

This EIP only changes online scheduling under pressure.

### Why mailbox signal over latency signal in this draft

- Fewer moving parts and no new tuning knobs.
- Directly aligned with the primary stability objective.
- Lower complexity for reviewers/operators.

## Configuration Changes

No new user-facing configuration is introduced in this draft.

Constants are internal implementation details (current candidates):

- `MAILBOX_BUSY_HIGH = 10`
- optional `MAILBOX_BUSY_LOW = 5` only if hysteresis is required by tests.

## Backwards Compatibility

Protocol compatibility is unchanged.

Behavior changes only under pressure for online sessions:

- QoS 0 may be queued instead of immediate-send when mailbox is busy,
  inflight is full, or backlog exists.

Offline QoS 0 and `mqueue_store_qos0` behavior remains unchanged.

## Document Changes

If accepted and implemented, update:

- Session scheduling docs to describe mailbox-based QoS 0 gating under pressure.
- Release notes with operational effect: better stability/fairness under stress
  with possible QoS 0 throughput trade-off during pressure windows.

## Testing Suggestions

### Targeted tests

- Add/update session-level tests:
  - QoS 0 does not bypass when inflight is full.
  - QoS 0 does not bypass when mailbox busy is true.
  - QoS 0 does not bypass when `mqueue` has backlog.
  - QoS 0 fast path remains for healthy/no-pressure case.
  - Offline behavior unchanged for `mqueue_store_qos0 = false` and `true`.

### Regression tests

- Run `emqx_session_mem_SUITE` and `emqx_channel_SUITE`.

### Manual/benchmark validation

- Mixed QoS benchmark under constrained client receive speed.
- Observe:
  - mailbox length distribution before/after,
  - QoS 1/2 ack latency under stress,
  - QoS 0 throughput impact only during pressure periods.

## Alternative Approaches (Pros and Cons)

### A. Mailbox-based busy flag (this proposal)

Pros:

- Directly addresses mailbox growth risk.
- No new user config complexity.
- Works across all transport modes.

Cons:

- Mailbox length is an indirect proxy for transport pressure.
- Threshold is static and may need internal tuning.

Reasoning:

- Best low-complexity path for the primary operational objective.

### B. Latency-based busy signal

Pros:

- Also transport-agnostic.

Cons:

- More state and tuning logic (EWMA, thresholds, counters).
- More likely to trigger "too much configuration" concerns.
- Latency can reflect scheduler/CPU noise, not just socket pressure.

Reasoning:

- Kept as fallback if mailbox signal proves insufficient.

### C. Queue-size polling (`port_info(queue_size)` / `getstat(send_pend)`)

Pros:

- More direct backlog metric when available.

Cons:

- Backend-specific behavior differences.
- `getstat` path adds synchronous control-call overhead.
- Per-send polling can increase CPU overhead.

Reasoning:

- Useful as optional enhancement later, not required in this draft.

### D. Full async writer redesign

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

