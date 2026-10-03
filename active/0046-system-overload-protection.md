# System Overload Protection

## Changelog

* 2026-08-30: @zmstone Initial draft
* 2026-10-03: @zmstone Narrowed the scope after review. Removed the proposal to
  change defaults. Removed the memory and transport-coverage work, which is now
  emqx/emqx#19280. Moved the other load mitigations to Future Discussion.

## Abstract

EMQX does not react when its transaction path falls behind. On a core node the
`mnesia_tm` process mailbox grows. On a replicant node the Mria replication
backlog grows. EMQX measures both values today and raises an alarm for one of
them, but no component uses either value to make a decision.

This EIP adds one new indicator for this condition and two optional actions
that an operator can enable. The indicator is local to each node and makes no
call to another node. Both actions are off by default. This EIP does not change
any existing default.

## Motivation

### Current state

EMQX has three components that watch node load.

* `lc` flags a high run queue and a high memory usage. It is a generic library
  and it knows nothing about EMQX, Mnesia, or Mria.
* `emqx_olp` reads one flag from `lc` and exposes one boolean. A small number of
  call sites use that boolean to defer work or to reject a new connection.
* `emqx_broker_mon` samples the `mnesia_tm` mailbox and the broker pool mailbox.
  It raises an alarm when a sample is above a fixed threshold. No component
  reads these samples to make a decision.

Three gaps follow from this.

1. No component measures how far the transaction path is behind. The
   `mnesia_tm` mailbox sample exists, but it only drives an alarm.
2. A replicant node has no local measure of its own replication backlog. The
   Mria function that reports the distance to the core node makes an `erpc`
   call to that core node, so a replicant must not poll it.
3. Both existing mailbox thresholds are fixed numbers. The same number raises
   and clears the alarm, so the alarm flaps at the boundary.

The run queue flag and the memory flag measure different resources, and
`emqx_olp` reports the run queue flag only. That separation is intentional. This
EIP keeps it. The memory signal is the subject of emqx/emqx#19280 and is out of
scope here.

### Reported problems

* emqx/emqx#11187 reports a cluster of 3 core nodes and 21 replicant nodes. The
  cluster held about ten million connections. Then 200,000 connections dropped
  in a burst. The connection count fell to zero and did not recover. A
  disconnect burst drives the same `mnesia_tm` work that a connect burst drives.
  Nothing in EMQX today reflects that backlog back into connection admission.
* emqx/emqx#11571 reports a cluster where subscribers stopped receiving
  messages while the dashboard still listed their subscriptions. This is
  consistent with replicated state that fell behind on a replicant node. Nothing
  in EMQX today tells a replicant node that its own import path is behind. This
  EIP does not fix divergence. It makes the condition visible to the node.

## Scope

This EIP covers one indicator and two actions.

The indicator is the transaction backlog of the local node.

The actions are:

* reject new connections;
* skip retained message writes.

This EIP does not cover:

* the memory signal and the transport coverage of `backoff_new_conn`, which are
  the subject of emqx/emqx#19280;
* the run queue flag in `lc`, which stays unchanged;
* severity levels in `emqx_olp`;
* any change to an existing default value;
* gateway protocols.

See Future Discussion for the mitigations that were in the first draft and are
now deferred.

This document names modules and functions. It does not give line numbers,
because line numbers change between branches.

## Design

### The indicator

The indicator is named transaction backlog. It is a boolean. Each node computes
it from local data only. No sample makes a call to another node.

A core node and a replicant node use different sources, because the work is in
a different place on each.

**Core node.** The source is the `mnesia_tm` process mailbox length.
`emqx_broker_mon` already samples this value on a timer. This EIP reuses the
sample. It does not add a second sampler and it does not change the existing
alarm.

**Replicant node.** The source is `mria_status:get_local_shard_stats/1`. This
function reads local ETS tables that the replica process writes. It makes no
`erpc` call. Two of its fields show the backlog:

* `replayq_len` is the depth of the queue that holds transaction log entries
  before the replica applies them;
* `message_queue_len` is the mailbox length of the replica process itself.

The indicator uses the larger of the two values.

`mria_status:get_shard_lag/1` reports the distance to the core node. It makes an
`erpc` call to that core node. A detector must not call the node that it
suspects is overloaded. This EIP does not use `get_shard_lag/1` to set the
indicator. An operator can enable it as a diagnostic. When enabled, EMQX calls
it only while the indicator is already set, and at a lower rate than the local
sample. Its value goes into the log message. It never changes a decision.

`mria_config:role/0` selects the source. This function reads a persistent term
and makes no call to another node.

### Watermarks and debounce

Each source has a high watermark and a low watermark. EMQX sets the indicator
when a sample is above the high watermark. EMQX clears the indicator when a
sample is below the low watermark. A sample between the two watermarks does not
change the indicator.

A fixed threshold cannot be correct for every deployment. A small node and a
large multi-tenant node do not have the same steady-state mailbox length. The
high watermark is therefore relative to a measured baseline, with a floor:

```
high_watermark = max(floor, multiplier * baseline)
low_watermark  = high_watermark * ratio
```

The baseline is the 99th percentile of the samples taken while the indicator is
clear. EMQX does not update the baseline while the indicator is set, so a long
overload does not raise its own baseline.

The indicator changes state only after a configured number of consecutive
samples agree.

The default values come from values that EMQX already uses for the same
purpose:

| Value | Default | Source of the default |
|---|---|---|
| floor | 500 | the current `mnesia_tm` mailbox alarm threshold |
| multiplier | 10 | `lc` treats the run queue as high at 8 times the scheduler count |
| ratio | 0.5 | gives the same shape of gap that the run queue ladder has |
| consecutive samples | 3 | the debounce count that `lc` uses for the run queue |

An operator who already changed the `mnesia_tm` mailbox alarm threshold keeps
that value as the floor. The alarm itself does not change.

### Action 1: reject new connections

When the indicator is set, EMQX rejects a new connection on a listener whose
zone enables this action.

EMQX already has this action. `emqx_olp:backoff_new_conn/1` rejects a new
connection and increases the `overload_protection.new_conn` counter. This EIP
adds a second trigger for it. It does not change the mechanism.

The transports on which this action runs today, and the work to make that set
complete, belong to emqx/emqx#19280.

The QUIC stack applies its own back pressure when memory is under pressure.
That back pressure is inside msquic and it is not related to the transaction
backlog. The two do not conflict. An operator who enables this action on a QUIC
listener gets both.

### Action 2: skip retained message writes

When the indicator is set, EMQX does not write a retained message on a zone
that enables this action. The client receives its normal acknowledgement. A
later subscriber does not receive the skipped message.

This action loses data that a client sent. It is off by default and it must stay
off by default. An operator enables it only after the operator accepts the
effect.

EMQX already drops a retained message write in one case: the retainer drops the
write when the message is above `retainer.max_payload_size` or above the
configured rate. This action adds a second reason to a path that already drops.
It does not add a new kind of data loss.

### How an action reads the indicator

`emqx_olp` gains one function that reports the indicator. The function is
separate from `emqx_olp:is_overloaded/0`.

`emqx_olp:is_overloaded/0` reports the run queue. The transaction backlog is a
different resource. Each resource keeps its own flag, and each action reads the
flag that applies to it. `emqx_olp:is_overloaded/0` does not change its meaning,
its value, or its callers.

## Configuration Changes

No existing default value changes.

Two new fields go in `zone.overload_protection`, next to the existing action
fields. Both are off by default:

```hocon
zone.default.overload_protection {
  enable = false                  # unchanged
  backoff_delay = 1               # unchanged
  backoff_gc = false              # unchanged
  backoff_hibernation = true      # unchanged
  backoff_new_conn = true         # unchanged

  backoff_new_conn_on_tx_backlog = false   # new
  bypass_retained_on_tx_backlog = false    # new
}
```

A new node-scoped section configures the indicator:

```hocon
sysmon {
  mnesia_tm_mailbox_size_alarm_threshold = 500   # unchanged, alarm only

  tx_backlog {
    enable = false                 # the node does not sample unless this is true
    high_watermark_floor = 500
    high_watermark_multiplier = 10
    low_watermark_ratio = 0.5
    sustained_samples = 3
    lag_diagnostic = false         # replicant only, erpc, log only, never decides
  }
}
```

The indicator is node-scoped because every input is a node property. A node has
one `mnesia_tm` process and one replica process for a shard, whatever the number
of zones its listeners use. The actions stay zone-scoped, because an operator
can reasonably protect one zone and not another.

## Backwards Compatibility

* No existing default value changes. A node that does not set the new fields
  behaves as it does today.
* `emqx_olp:is_overloaded/0` keeps its signature, its meaning, and its value.
  Every existing caller works without a change.
* The `mnesia_transaction_manager_overload` and `broker_pool_overload` alarms do
  not change. This EIP reads the same sample. It does not change what the alarms
  report or when they report it.
* The existing `overload_protection.*` counters keep their names and their
  meaning.
* A node computes and applies the indicator locally. A node that runs older code
  does not run the detector and does not apply the new actions. A rolling
  upgrade needs no agreement between nodes and no feature gate.

## Document Changes

* Document the two new `zone.overload_protection` fields and state that the
  retained message action loses data.
* Document the new `sysmon.tx_backlog` section.
* State in the operations guide that `mnesia_tm_mailbox_size_alarm_threshold`
  also sets the floor of the high watermark when the indicator is enabled.

## Testing Suggestions

* Watermark state machine: the indicator sets only after the configured number
  of consecutive high samples, does not change inside the band, and clears only
  after the same number of consecutive low samples.
* Baseline: the baseline does not move while the indicator is set.
* Replicant source: the indicator sets from `replayq_len` and
  `message_queue_len` alone. The indicator still works when the call to the core
  node fails or times out.
* Default off: on a node that does not set the new fields, no connection is
  rejected and no retained message write is skipped, under any value of the
  indicator.
* Core and replicant: a core node uses the `mnesia_tm` source and a replicant
  node uses the Mria source, selected by `mria_config:role/0`.
* `emqx_olp:is_overloaded/0` keeps its current value when the indicator is set
  and the run queue is normal.
* Burst shape from emqx/emqx#11187: connect many sessions, disconnect a large
  part of them in a burst, and check that the node continues to accept and to
  serve connections.

## Future Discussion

The first draft of this EIP proposed more. These items are out of scope here.
Each one needs its own discussion.

* **Severity levels in `emqx_olp`.** The first draft replaced the single boolean
  with ordered levels, so that a reversible action fires before an action that
  loses data. With two actions and one indicator, two independent switches give
  the operator the same control and are simpler to reason about. Levels become
  useful only when the number of actions grows.
* **Change `zone.overload_protection.enable` to `true` by default.** Declined.
  See Declined Alternatives.
* **Skip hibernation and garbage collection under memory pressure.** Hibernation
  and garbage collection release memory. Skipping them under memory pressure
  works against the goal. This needs a separate analysis per trigger.
* **Defer audit log writes.** The audit log write path already tolerates a
  failure, so skipping it is a small change. No MQTT client observes it. It is
  not related to the transaction backlog and it belongs to its own proposal.
* **Gateway protocols.** MQTT-SN, CoAP, LwM2M, and STOMP do not share
  `emqx_connection`, `emqx_ws_connection`, or `emqx_channel`. Each protocol
  needs its own integration point. This is identified work, not a decision to
  leave these protocols without protection.
* **Pace the cleanup work itself.** emqx/emqx#11187 shows a disconnect burst.
  Rejecting new connections does not slow the cleanup that the burst already
  started. A mechanism that paces session and route deletion would address the
  cause. It is a larger change than this EIP.

## Declined Alternatives

**Add Mnesia and Mria flags to `lc`.** Declined. `lc` has no Mnesia or Mria
dependency and it does not know what EMQX is. The `mnesia_tm` mailbox and the
Mria backlog are EMQX and Mria concepts. The code that reads them already lives
in EMQX and in Mria. EMQX vendors `lc`, so EMQX-specific code inside it is one
upstream sync away from loss.

**Replace `lc`.** Declined. The run queue ladder in `lc` works and EMQX has run
it in production since EIP-0010. This EIP found no defect in it. It observes a
set of signals that does not include the transaction path, which is a gap in
coverage and not a defect.

**Fold the indicator into `emqx_olp:is_overloaded/0`.** Declined. That function
reports the run queue. The run queue, the memory usage, and the transaction
backlog are different resources. A caller that wants one of them must not get
the union of all three.

**Use `mria_status:get_shard_lag/1` as the replicant source.** Declined. The
function makes an `erpc` call to the core node. A detector must not block on a
call to the node that it suspects is overloaded.

**Use the fixed threshold 500 as the only watermark.** Declined. One absolute
number cannot be correct for a small node and for a large multi-tenant node.
The number stays as the floor of a watermark that scales with the measured
baseline.

**Configure the indicator per zone.** Declined. Every input is a node property.
A node has one `mnesia_tm` process. Per-zone detection would let one node report
different states depending on which zone a caller asked about.

**Change `zone.overload_protection.enable` to `true` by default.** Declined. The
correct value depends on the deployment and on the workload. An operator must
enable overload protection after the operator understands the effect and tests
it. EMQX must not make that decision for the operator.

**Add a general overload protection layer across EMQX.** Declined. Overload
protection of this kind fits a service that performs one task. EMQX performs
many. A general layer risks protection where none is needed, uneven back
pressure between paths, and hidden faults. Correct resource planning and a test
in a staging environment remain the first answer. This EIP therefore stays
narrow: one indicator, two actions, both off by default.
