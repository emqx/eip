# System Overload Protection

## Changelog

* 2026-08-30: @zmstone Initial draft

## Abstract

EMQX has three independent, partly-overlapping mechanisms that watch node load
today: `lc` (vendored at `deps/lc`), which flags a high ERTS run queue and high
memory usage; `emqx_olp`, a thin facade that lets a few call sites defer or
reject work when `lc` says the node is loaded; and `emqx_broker_mon`, which
alarms on a growing `mnesia_tm` mailbox and a growing broker-pool mailbox, but
does not feed either alarm back into a decision. None of the three knows
anything about Mria or node role, none of them use hysteresis consistently, the
one decision they drive (`emqx_olp:is_overloaded/0`) is a single boolean built
from the run-queue flag only — high memory is measured but never checked, and
none of the resulting actions are applied uniformly across transports. Two
GitHub issues (emqx/emqx#11891, emqx/emqx#11187) describe operator-visible
failures that these gaps allow.

This EIP does not add a fourth mechanism. It closes the gaps in the three that
exist: it wires the already-measured memory flag into the decision; it gives
`mnesia_tm`-mailbox and Mria-replication backlog the same status as run queue
and memory, using signals a core or replicant node can already compute
locally, with no RPC; it replaces the single boolean with a small set of
severity levels so that reversible, no-data-loss actions can fire earlier than
actions that drop data; it makes new-connection throttling actually apply to
every listener instead of three out of five paths; and it turns
`overload_protection.enable` on by default, because after these changes the
default-on action set is provably safe to enable everywhere.

## Motivation

### The existing mechanism does not do what it looks like it does

`zone.overload_protection` (`apps/emqx/src/emqx_schema.erl:568-611`) reads as a
complete feature: `enable`, `backoff_delay`, `backoff_gc`,
`backoff_hibernation`, `backoff_new_conn`. Its doc string says the mechanism
"monitors the load of the system and temporarily disables some features (such
as accepting new connections) when the load is high"
(`apps/emqx/src/emqx_schema.erl:2459-2461`). In practice:

* `emqx_olp:is_overloaded/0` (`apps/emqx/src/emqx_olp.erl:38-40`) is defined as
  `load_ctl:is_overloaded()`, and nothing else. `load_ctl:is_overloaded/0`
  (`deps/lc/src/load_ctl.erl:42-44`) checks only whether the run-queue flag
  process is registered. `load_ctl:is_high_mem/0`
  (`deps/lc/src/load_ctl.erl:47-49`) exists, is measured continuously by
  `lc_mem`, and is fed a real threshold from EMQX's own memory config
  (`apps/emqx/src/emqx_os_mon.erl:239-241`) — but it has zero callers anywhere
  under `apps/` (confirmed by `grep -rn "is_high_mem" apps/`). A node can be at
  95% memory, with `lc_mem`'s own alarm active, and every `emqx_olp` action —
  including `backoff_new_conn`, the exact behavior emqx/emqx#11891 asks for —
  stays off, because the aggregate check never looks at memory.
* `backoff_new_conn/1` is wired as an esockd `tune_fun`
  (`apps/emqx/src/emqx_listeners.erl:745`), which only the two esockd-based
  listener paths receive: `emqx_socket_connection` and `emqx_connection`
  (`apps/emqx/src/emqx_listeners.erl:480-490`). WebSocket listeners are started
  through `cowboy:start_clear/3` / `cowboy:start_tls/3`
  (`apps/emqx/src/emqx_listeners.erl:492-498`), which never receives a
  `tune_fun`; `emqx_ws_connection.erl` has no reference to `emqx_olp` or
  `overload_protection` at all. QUIC reimplements the check inline
  (`apps/emqx/src/emqx_quic_connection.erl:121-129`) with its own
  `is_zone_olp_enabled/1` (`emqx_quic_connection.erl:347-354`) instead of
  calling `emqx_olp:backoff_new_conn/1`, so it never bumps the
  `overload_protection.new_conn` counter. Every gateway protocol
  (`apps/emqx_gateway*` — MQTT-SN, CoAP, LwM2M, STOMP) has no reference to
  `emqx_olp` or `overload_protection` anywhere in the tree (confirmed by
  `grep -rln`). So "throttle new connections" today means "throttle new plain
  TCP/TLS connections," silently.
* `mnesia_tm`'s mailbox is already watched — just not by any of the above.
  `apps/emqx/src/emqx_broker_mon.erl:167-175` samples
  `process_info(whereis(mnesia_tm), message_queue_len)` every 10 seconds
  (`emqx_broker_mon.erl:36-38`) and raises the
  `mnesia_transaction_manager_overload` alarm
  (`emqx_broker_mon.erl:116-127`) once it exceeds
  `sysmon.mnesia_tm_mailbox_size_alarm_threshold`, a fixed `pos_integer()`
  defaulting to `500` (`emqx_schema.erl:1710-1717`) that is used identically to
  raise and clear — no hysteresis. The same module also watches the broker
  dispatch pool's worst mailbox against a second, also-unhysteretic threshold
  of `500` (`emqx_broker_mon.erl:184-197`, `emqx_schema.erl:1718-1725`). Both
  alarms are pure observability: nothing in `emqx_olp` or `lc` reads either
  one.
* Mria itself has no local, RPC-free notion of "this node is overloaded" —
  `mria_status:get_shard_lag/1`, the obvious starting point, does an
  `erpc:call` to the upstream core on a replicant
  (`deps/mria/src/mria_status.erl:205-219`), and mria's own comment at
  `mria_status.erl:273-275` says exactly why that is the wrong function to
  poll: *"Almost identical to `get_shard_stats/1`, except that we avoid doing
  `erpc` calls and collect only what we can gather from local state. For
  example, on replicants, `get_shard_lag/1` performs an `erpc` call to a core
  node, so we avoid that."*

### Real incidents this gap allows

* emqx/emqx#11891 asks for exactly the memory-triggered connection shedding
  described above — "stop accepting new connections when a certain memory
  threshold is reached" — and cites Elasticsearch's low/high disk watermark
  pair as the model to follow. The detector (`lc_mem`) and the action
  (`backoff_new_conn`) both already exist in this codebase; they are simply
  never connected, and neither has the two-watermark shape the issue asks for.
* emqx/emqx#11187 reports a cluster (3 core, 21 replicants) that took roughly
  ten million connections, then had 200,000 of them disconnect in a burst; the
  dashboard showed connection count drop to 0 and never recover, with new
  connections staying unstable afterward. A disconnect storm drives the same
  `mnesia_tm`-serialized cleanup path (session/route/registry deletes) that a
  connect storm does, and `backoff_new_conn` — even where it is wired — only
  throttles *new* connections; nothing in the current design throttles or
  paces the cleanup work itself, or reflects a growing `mnesia_tm` backlog
  back into new-connection admission. A mailbox-based indicator that gates new
  connections would have let the node shed incoming load while it drained the
  backlog, instead of accepting more work while already behind.
* emqx/emqx#11571 describes a cluster where existing subscribers stopped
  receiving messages (`PUBACK` reason code 16, no matching subscribers) while
  the dashboard still listed those subscriptions, on a cluster that had been
  running for over 100 days. This is consistent with routing state that
  diverged between core and replicant under sustained load, with nothing in
  the system surfacing that a replicant's replicated view had fallen
  meaningfully behind. This EIP's replicant indicator does not fix routing
  divergence, but it gives the replicant a way to know, locally, when its own
  import path is falling behind — the condition under which such divergence
  becomes possible.

### What this EIP is and is not

This is not a proposal to build overload protection from nothing. Run queue
and memory already have a detector, a config surface, and a flagman process in
`lc`; `mnesia_tm`-mailbox already has a sampler and an alarm in
`emqx_broker_mon`; Mria already tracks local replay backlog. The gap is
integration: these signals do not feed one decision, that decision does not
gate every code path it claims to, and none of it is trusted enough to run by
default. Closing that gap is the content of this EIP.

## Design

### Reuse map — what this EIP keeps, extends, and adds

| Piece | Status today | This EIP |
|---|---|---|
| `lc_runq` (run-queue credit ladder) | Working, unchanged since EIP-0010 | Reused as-is |
| `lc_mem` (memory threshold) | Working, single threshold, no hysteresis | One narrow upstream patch: add a low-watermark |
| `load_ctl:is_overloaded/0` (runq only) | Sole input to `emqx_olp` | Kept; no longer the *only* input |
| `load_ctl:is_high_mem/0` | Computed, uncalled | Wired into the decision — the single highest-value fix in this EIP |
| `emqx_broker_mon` mnesia_tm/pool mailbox sampling | Alarm-only, no hysteresis, magic threshold `500` | Sampling code reused; decision layer added on top |
| `mria_status:get_local_shard_stats/1` | Exists, unused by any overload logic | Adopted as the replicant indicator's data source |
| `mria_status:get_shard_lag/1` | Exists, does `erpc` | Kept only as an opportunistic, already-flagged-only diagnostic; never gates an action |
| `emqx_olp:is_overloaded/0` | `boolean()`, runq only | Becomes a derived view (`level() >= 1`) of a graded, multi-signal aggregator |
| `backoff_new_conn/1` | Wired for TCP/SSL (esockd) only | Extended to WebSocket; QUIC's private reimplementation replaced with the shared call |
| Actions: `backoff_gc`, `backoff_hibernation` | Wired via `emqx_channel:2229`, shared by every transport that drives the channel FSM | Unchanged |
| Actions: bypass retained writes | Does not exist | Added, opt-in |
| Actions: defer audit-log writes | Does not exist | Added, opt-in |
| Gateway protocols (MQTT-SN, CoAP, LwM2M, STOMP) | No integration at all | Explicitly out of scope; called out as a follow-up (see Declined Alternatives) |

### Cooperating with `lc`

Three options were on the table.

**Extend `lc` with mnesia_tm/Mria-aware flagmen.** Declined. `lc` has no
mnesia or Mria dependency today — `grep -rniE 'mnesia|mria|replicant'
deps/lc/{src,include}` returns nothing, and its `.app.src` lists only
`kernel, stdlib, os_mon, sasl, runtime_tools`
(`deps/lc/src/lc.app.src:21-27`). It is a small, generic, node-agnostic
library; the `mnesia_tm` mailbox and Mria replay backlog are EMQX/Mria
concepts, and the code that already knows how to read them
(`emqx_broker_mon.erl`, `mria_status.erl`) lives outside `lc`. Teaching a
vendored, generically-scoped dependency about a specific downstream's
internals is the layering violation vendoring is supposed to prevent, and it
would put EMQX-specific logic one upstream sync away from being silently
dropped.

**Replace `lc`.** Declined, explicitly, so it is not revisited. `lc_runq`'s
credit-ladder debounce (`deps/lc/src/lc_runq.erl:68-102`) is a working
algorithm this codebase has run in production since EIP-0010; nothing in this
proposal's research found a defect in it, only a gap in what it observes (it
was never asked to know about `mnesia_tm` or Mria). Rewriting a validated
detector to fix an unrelated integration gap trades a known-good component for
risk with no offsetting benefit.

**Keep `lc` scoped to run-queue and memory; add the two new indicators as
EMQX-side detectors; make `emqx_olp` the single point where all signals are
combined.** This is the recommendation. `lc` keeps owning what it already
owns and does well. `emqx_olp` stops being a one-line passthrough to
`load_ctl:is_overloaded/0` and becomes an aggregator that reads: `lc`'s two
existing flags (`is_overloaded/0` for run queue, and — newly — `is_high_mem/0`
for memory), a new core-only detector built on `emqx_broker_mon`'s existing
`mnesia_tm`-mailbox sample, and a new replicant-only detector built on
`mria_status:get_local_shard_stats/1`. Node role selects which of the last two
runs, via `mria_config:role/0` (`deps/mria/src/mria_config.erl:116-118` —
`persistent_term:get({mria, node_role}, core)`, itself local and RPC-free), so
the operator-facing config and API surface (`emqx_olp`) does not need to know
about role at all.

One narrow exception to "don't touch `lc`": `lc_mem`'s single-threshold
raise/clear (`deps/lc/src/lc_mem.erl:52-60`) is a gap inside memory watching,
which is squarely `lc`'s own domain — not a new indicator type. This EIP
proposes a small upstream patch adding a `memory_low_watermark` config key
so memory gets the same kind of debounce run queue already has, rather than
adding that debounce logic outside `lc` where it would duplicate `lc_mem`'s
polling.

### Indicator 1: `mnesia_tm` mailbox (core nodes)

The sampling code is not new: `emqx_broker_mon:read_mnesia_tm_mailbox_size/0`
(`apps/emqx/src/emqx_broker_mon.erl:167-175`) already does
`process_info(whereis(mnesia_tm), message_queue_len)` on a 10-second timer.
What is new is turning that sample into a decision input instead of an
alarm-only side effect, and fixing its threshold.

The existing threshold (`sysmon.mnesia_tm_mailbox_size_alarm_threshold`,
default `500`, `emqx_schema.erl:1710-1717`) is a single fixed number used
identically to raise and clear. It cannot be right for every deployment: a
single-table edge node and a large multi-tenant core node do not share a
steady-state mailbox length, and a fixed threshold with no hysteresis flaps
around its own boundary. The fix keeps `500` — the existing, already-shipped
number, not a new one — as a floor, and adds a multiplier over a measured
baseline on top of it:

```
high_watermark = max(500, 10 * rolling_p99_baseline)
low_watermark  = high_watermark * 0.5
```

`rolling_p99_baseline` is the mailbox length's 99th percentile over a trailing
window sampled only while the flag is *not* raised, so a sustained overload
does not pull its own baseline upward. The `10x` multiplier mirrors the
existing precedent in this same codebase for "how much above steady state
counts as abnormal": `lc_runq` already treats run-queue length as overloaded
at `8x` the scheduler count (`deps/lc/include/lc.hrl:41`,
`lc_runq.erl:67`). The `0.5` low-watermark ratio mirrors the shape (not the
exact numbers, which are quota-percentage-based and not applicable here) of
the license connection watermark pair discussed below. A flag only flips state
after `3` consecutive polls agree — reusing `lc_runq`'s own debounce count,
`?RUNQ_MON_C1_DEFAULT = 3` (`deps/lc/include/lc.hrl:71-72`), rather than
inventing a new number — sampled every 3 seconds normally and every 1 second
while flagged, again mirroring `lc_runq`'s own `T1`/`T2` pair
(`lc.hrl:63-64,67-68`). None of these numbers are new inventions; each is
either the number already shipping for this exact metric, or a number this
codebase already uses for the equivalent purpose on a different metric.

An operator who already tuned `mnesia_tm_mailbox_size_alarm_threshold` away
from `500` keeps that value as their floor unchanged; the alarm itself is
untouched by this EIP and continues to exist purely for observability, at the
same threshold it uses today.

### Indicator 2: replicant backlog (replicant nodes)

The maintainer's caveat is correct and this design honors it: the primary
replicant signal must not be `get_shard_lag/1`, because it is an `erpc` to the
node that may itself be the overloaded one
(`mria_status.erl:273-275`, quoted above). `mria_status:get_local_shard_stats/1`
(`mria_status.erl:276-303`) already returns, with no RPC:

```erlang
#{ state               => get_stat(Shard, ?replicant_state)
 , last_imported_trans => get_stat(Shard, ?replicant_import)
 , replayq_len         => get_stat(Shard, ?replicant_replayq_len)
 , bootstrap_time      => get_bootstrap_time(Shard)
 , bootstrap_num_keys  => get_stat(Shard, ?replicant_bootstrap_import)
 , upstream            => Upstream
 , message_queue_len   => get_mql(Shard)
 }
```

Every field is backed by a local, `public` ETS table
(`get_stat/2`, `mria_status.erl:421-426`) that the replica process itself
writes to. Two of these fields are the replicant's direct analog of the core's
`mnesia_tm` mailbox:

* `replayq_len` — the depth of the `replayq` queue that
  `mria_rlog_replica` (a `gen_statem`, `deps/mria/src/mria_rlog_replica.erl:19-21`)
  buffers incoming transaction log entries into before applying them
  (`mria_rlog_replica.erl:284-292` opens the queue, `mria_rlog_replica.erl:337-338`
  pops and applies a batch, `mria_rlog_replica.erl:355` reports the depth via
  `mria_status:notify_replicant_replayq_len/2` right after each apply). A
  growing `replayq` means import is falling behind — the replicant's
  direct equivalent of a growing `mnesia_tm` mailbox.
* `message_queue_len` — the replica process's own Erlang mailbox, read via
  `get_mql/1` (`mria_status.erl:305-313`, `whereis/1` + `process_info/2`). The
  replica sets `process_flag(message_queue_data, off_heap)` at init
  (`mria_rlog_replica.erl:123`), which only matters if this mailbox is
  expected to grow — evidence the authors already anticipated this failure
  mode, even though nothing currently monitors it.

The same detector shape as indicator 1 applies here: an absolute floor (`500`,
reusing the same number for the same reason — consistency of operator mental
model, not a fresh guess), a `10x`-of-baseline multiplier, a `0.5` clear
ratio, and a `3`-poll debounce, applied to `max(replayq_len,
message_queue_len)`.

`get_shard_lag/1` is not discarded — it is demoted to a slow-path
corroborator, polled only once the local flag is already raised, and at a
much lower frequency (every 10th local poll). At that point the node is
already shedding load locally, so one additional `erpc` is a bounded cost on
an already-degraded path, not new steady-state overhead; and it is used only
to enrich the alarm message with "how far behind the core" for diagnostics.
No action in this design is ever gated on it — the maintainer's framing (lag
as a corroborator, not a trigger) is adopted exactly as stated.

Every indicator this EIP relies on — existing (run queue, memory, `mnesia_tm`
mailbox) and new (replicant backlog) — is computed with no inter-node call in
its steady-state path. This is a design invariant worth stating explicitly: a
detector that can block on a call to the node it suspects is overloaded is
self-defeating, and this design has none.

### From boolean to severity levels

`emqx_olp:is_overloaded/0` returning `boolean()` forces every trigger into the
same response. That is wrong on two axes: severity (76% memory used and one
allocation from OOM are both "true") and consequence (skipping a hibernation
call and silently dropping a retained message are both currently gated by the
same flag). This EIP replaces the single flag with a small ordered set of
levels, computed entirely inside `emqx_olp` — `lc` and the new detectors stay
unaware of levels; they each still expose one boolean (or, for memory, one
numeric reading) and `emqx_olp` does the combining:

* **Level 0 — normal.** No action.
* **Level 1 — elevated.** Any of: run-queue flag (`lc`, unchanged), memory
  flag (`lc`, newly consulted), `mnesia_tm`-mailbox high watermark (core),
  replicant-backlog high watermark (replicant). Actions: throttle new
  connections, skip hibernation — the two actions that cost nothing but
  latency and are trivially reversible.
* **Level 2 — critical.** Any of: memory usage at or above a second,
  higher watermark (default `0.9`, independent of `lc_mem`'s existing `0.75`
  elevated threshold), or `mnesia_tm`-mailbox / replicant-backlog crossing a
  second watermark at twice the level-1 high watermark, sustained. Actions:
  everything from level 1, plus the opt-in, data-losing actions below.

`emqx_olp:is_overloaded/0` is preserved as `level() >= 1`, so every existing
caller — the CLI (`apps/emqx_management/src/emqx_mgmt_cli.erl:1401-1419`),
`emqx_channel:2229`'s `backoff/1` gate, Prometheus's counter gating — keeps
working with no code change. A new `emqx_olp:level/0` is added for callers
that need to distinguish level 1 from level 2, and QUIC's private
`is_zone_olp_enabled/1` (`emqx_quic_connection.erl:347-354`) is removed in
favor of calling the shared `emqx_olp:backoff_new_conn/1` directly, so QUIC
gets the same counters as every other transport.

### Making "throttle new connections" mean all listeners

`backoff_new_conn/1` stays the mechanism; the fix is coverage, not a new
mechanism:

* **TCP/TLS (esockd, both backends).** Already correct
  (`emqx_listeners.erl:480-490,745`); unchanged.
* **QUIC.** Replace the inline `emqx_olp:is_overloaded() andalso
  is_zone_olp_enabled(Zone)` check (`emqx_quic_connection.erl:121-129`) with a
  direct call to `emqx_olp:backoff_new_conn(Zone)`. This is strictly a bug fix
  for QUIC — the QUIC path today enforces new-connection shedding using stale
  logic (it checks only level-1-equivalent run-queue overload and never
  memory, `mnesia_tm`, or replicant backlog) and produces no metric, so an
  operator watching `overload_protection.new_conn` cannot tell QUIC is
  rejecting connections at all.
* **WebSocket.** Cowboy's listener start
  (`emqx_listeners.erl:492-498`) has no `tune_fun`-equivalent hook today. This
  EIP proposes adding the `backoff_new_conn/1` check at WebSocket upgrade time
  in `emqx_ws_connection`, the earliest point in the WS path that plays the
  same role esockd's `tune_fun` plays for TCP — before the MQTT `CONNECT`
  packet is processed, not after.
* **Gateway protocols.** Out of scope for this EIP. `apps/emqx_gateway*`
  protocols do not share `emqx_connection`, `emqx_ws_connection`, or
  `emqx_channel`, so none of the integration points above apply, and each
  protocol would need its own listener-level hook. See Declined Alternatives
  for why this is deferred rather than attempted here.

### Actions — beyond the two given, with evidence

The handover named two actions: throttle new connections (above), and bypass
retained-message writes. Both are grounded; two more are added, and several
candidates were investigated and rejected with reasons, because "go beyond the
two given" only has value if the rejections are as explicit as the additions.

| Action | Trigger level | Correctness or performance | Evidence |
|---|---|---|---|
| Throttle new connections | 1 | Performance/availability — a rejected client retries elsewhere; no data touched | `emqx_listeners.erl:745`, extended above |
| Skip hibernation / GC | 1 | Performance only — defers work, nothing lost | `emqx_channel.erl:2229`, `emqx_connection.erl:455,1220` |
| **Bypass retained-message writes** (new default: opt-in) | 2 | **Correctness-visible** — drops state a late subscriber is entitled to see | `apps/emqx_retainer/src/emqx_retainer_mnesia.erl:387` (`mria:dirty_write_sync`), `:501` (`dirty_delete_object`) |
| **Defer audit-log writes** (new, opt-in) | 2 | Operator-visible, not protocol-visible — no MQTT client ever observes this | `apps/emqx_audit/src/emqx_audit.erl:114-146`; already best-effort — write failures are caught and logged, never surfaced to the audited operation |

Bypassing retained writes has an in-tree precedent for "correctness-visible
but already accepted as sheddable": `emqx_retainer_publisher`'s token bucket
already silently drops a retained-message store when the configured rate
limit or `max_payload_size` is exceeded
(`apps/emqx_retainer/src/emqx_retainer_publisher.erl`, gated on
`retainer.max_payload_size`). This EIP's action adds a second trigger
(overload) to a drop path that already exists for a different trigger
(rate/size); it is not introducing a new class of data loss to the retained-
message path, only a new reason for one that already ships.

Audit-log deferral is added as a new action because it is close to free to
justify: the write path already tolerates failure by design
(`try_log_to_db/1`, `emqx_audit.erl:114-129`, catches and logs any write
error without failing the audited operation), so skipping the write under
level 2 is strictly less surprising than a write that silently fails today
for unrelated reasons (a full disk, a Mnesia hiccup). No MQTT client
observes an audit-log write either way.

Investigated and **declined** as overload-shedding targets:

* **Route/topic table writes** (`apps/emqx/src/emqx_router.erl:254-260`
  → `mria:dirty_write(route_table(), Route)`, `emqx_router.erl:409-410`).
  Correctness-visible, and — unlike retained messages — MQTT gives no
  "best-effort" cover for a missing route: the client already received a
  `SUBACK` and is entitled to matching messages from that point on. There is
  no in-tree precedent for silently dropping a subscription, and adding one
  here would create a class of message loss (subscribed-but-not-routed) with
  no existing operator-facing signal that it happened.
* **Session registration on connect.** The local bookkeeping
  (`apps/emqx/src/emqx_cm.erl:162-186`, plain `ets:insert/2`) is cheap enough
  that deferring it saves nothing meaningful and the calling process needs it
  immediately regardless. The cluster-wide registry write
  (`apps/emqx/src/emqx_cm_registry.erl:92,94`, gated behind
  `broker.enable_session_registry`) is correctness-visible for takeover and
  deduplication; skipping it risks duplicate sessions on reconnect, which is a
  worse operator experience than the overload it would be shedding.
* **Delayed-message scheduling** (`apps/emqx_modules/src/emqx_delayed.erl:413-423`).
  Correctness-visible — the write *is* the feature. It already has the right
  precedent for how EMQX should behave when this resource is under pressure:
  a hard cap (`max_delayed_messages`) that fails closed with an explicit
  `{error, max_delayed_messages_full}` (`emqx_delayed.erl:415-421`) rather
  than a silent drop. This is the model the two new opt-in actions above
  follow in spirit — an explicit, documented behavior change under load, not
  an invisible one — even though delayed-message scheduling itself is not
  touched.
* **Rule-engine dispatch** (`apps/emqx_rule_engine/src/emqx_rule_runtime.erl:440-450`).
  Declined because the rule engine already owns its own backpressure policy
  through buffer-worker resources; layering an independent overload-shedding
  decision on top of a system that already has one would give an operator two
  different, uncoordinated reasons a rule's side effect might not happen.
* **Metrics collection** (`apps/emqx/src/emqx_metrics.erl:233-239,298`).
  Not a candidate — it is already a lock-free `counters:add/3` through a
  `persistent_term`-cached reference, with no lock or transaction to shed.
  It is closer to the pattern the other actions should imitate than to a
  problem needing a fix.

## Configuration Changes

`zone.overload_protection` keeps its current shape and field names
(`apps/emqx/src/emqx_schema.erl:568-611`); only its default changes:

```hocon
zone.default.overload_protection {
  enable = true            # was: false
  backoff_delay = 1         # unchanged
  backoff_gc = false        # unchanged
  backoff_hibernation = true  # unchanged
  backoff_new_conn = true   # unchanged
}
```

A new node-scoped section is added alongside the existing `sysmon.*` mailbox
alarm thresholds it builds on:

```hocon
sysmon {
  mnesia_tm_mailbox_size_alarm_threshold = 500   # unchanged; alarm only

  overload_protection {
    mnesia_tm_mailbox {                # core nodes only
      enable = true
      high_watermark_multiplier = 10   # x rolling p99 baseline; floor = mnesia_tm_mailbox_size_alarm_threshold above
      low_watermark_ratio = 0.5
      sustained_polls = 3
    }
    replicant_backlog {                # replicant nodes only
      enable = true
      high_watermark_floor = 500
      high_watermark_multiplier = 10
      low_watermark_ratio = 0.5
      sustained_polls = 3
      lag_corroboration = true         # opportunistic erpc, diagnostics only, never gates an action
    }
    memory {
      critical_watermark = 0.9         # level-2 threshold; independent of lc_mem's existing 0.75
    }
    bypass_retained = false            # level-2 action, opt-in
    defer_audit_log = false            # level-2 action, opt-in
  }
}
```

`lc`'s own config gains one new key, added upstream in `deps/lc`:

```erlang
%% deps/lc/include/lc.hrl
-define(MEM_MON_LOW_WATERMARK, memory_low_watermark).
-define(MEM_MON_LOW_WATERMARK_DEFAULT, 0.65).   % clears the flag; existing 0.75 remains the raise threshold
```

## Backwards Compatibility

* **`zone.overload_protection.enable` changes default from `false` to `true`.**
  This is a behavior-changing default on upgrade, and it is called out here as
  one. It is judged safe because, at level 1 (the only level that fires under
  the previous single-boolean design plus the newly-wired memory flag), the
  only actions that change are throttling new connections and skipping
  hibernation — both fully reversible, and neither touches data already
  accepted. On a node that is not overloaded, nothing observable changes.
  An operator who already set `enable = false` explicitly keeps that value —
  HOCON's explicit-value-wins-over-default rule is untouched by this EIP.
* **`emqx_olp:is_overloaded/0`** keeps its existing `boolean()` signature and
  semantics (now `level() >= 1`); every existing internal and external
  consumer — CLI, Prometheus, `emqx_channel:2229` — continues to work
  unchanged. `emqx_olp:level/0` is additive.
* **The five existing `overload_protection.*` counters keep their names and
  meaning.** New counters (for the two new opt-in actions) are additive.
* **The existing `mnesia_transaction_manager_overload` and
  `broker_pool_overload` alarms are untouched** — they keep alarming at their
  current, unchanged thresholds. This EIP adds a decision layer that reads the
  same underlying sample; it does not change what the alarms do.
* **Mixed-version clusters.** Every indicator this design relies on is
  computed and acted on locally, with no inter-node coordination — the same
  property `load_ctl:is_overloaded/0` already has today. A node running old
  code simply does not run the new detectors and does not gate the two new
  actions; it does not need the rest of the cluster to agree on anything, and
  no negotiation or feature-gate is required for a rolling upgrade.
* **QUIC's `is_zone_olp_enabled/1`** is a private, unexported function
  (`emqx_quic_connection.erl:347-354`); removing it has no external compat
  impact.

## Document Changes

* Update the `overload_protection` reference doc to describe the new default
  (`enable = true`), the severity-level model, and the two new opt-in
  data-losing actions.
* Document the new `sysmon.overload_protection.*` config block.
* Document `emqx_olp:level/0` and the CLI's `olp status` output gaining a
  level field (in addition to the existing overloaded/not-overloaded text,
  `apps/emqx_management/src/emqx_mgmt_cli.erl:1403-1409`).
* Note in the operations guide that `mnesia_tm_mailbox_size_alarm_threshold`
  now also serves as the floor for the connection-shedding decision, not only
  the alarm.

## Testing Suggestions

* Hysteresis state machine for the `mnesia_tm`-mailbox and replicant-backlog
  detectors: raise only after `sustained_polls` consecutive high samples,
  no-op inside the band, clear only after `sustained_polls` consecutive low
  samples — extending the existing test style in
  `apps/emqx/test/emqx_broker_mon_SUITE.erl:81-105`.
* Regression for emqx/emqx#11187's shape: connect a large number of sessions,
  disconnect a large fraction in a burst, and assert the node keeps accepting
  and serving connections rather than dropping to zero and staying there.
* Replicant detector correctness under a paused or slow upstream core: assert
  the local flag raises based on `replayq_len`/`message_queue_len` alone,
  with no dependency on `get_shard_lag/1` succeeding, and assert the check
  never blocks even if the corroborating `erpc` to the core times out.
* False-positive gate: `zone.overload_protection.enable = true` on an idle,
  healthy node must reject nothing — a regression test asserting no connection
  is throttled and no level rises above 0 at rest, run against the new
  default.
* Uniformity regression: under the same synthetic overload condition, TCP,
  WebSocket, and QUIC listeners all reject new connections and all bump
  `overload_protection.new_conn`; verify QUIC's counter increments (it does
  not today).
* `emqx_olp:is_overloaded/0` remains `true` iff `emqx_olp:level/0 >= 1` across
  every combination of raised/cleared indicator flags.
* Memory wiring: with `load_ctl:is_high_mem/0` forced `true` and run queue
  normal, assert level reaches at least 1 and `backoff_new_conn` rejects new
  connections — this is the case that is silently broken today.
* Explicit `zone.overload_protection.enable = false` keeps a node fully
  passive even while node-level detectors are flagged, confirming the
  per-zone override is honored against the new global default.
* `lc_mem` low-watermark: raise at `0.75`, confirm it does not clear until
  usage drops below the new `memory_low_watermark` (default `0.65`), not
  merely back below `0.75`.

## Declined Alternatives

**Extend `lc` with new mnesia_tm/Mria-aware flagmen.** See Design — declined
because `lc` has no mnesia or Mria dependency today and adding one would put
EMQX-specific logic inside a vendored, generically-scoped library, one
upstream sync away from being lost.

**Replace `lc` entirely.** See Design — declined because `lc_runq`'s
credit-ladder algorithm is a working, previously-validated mechanism with no
demonstrated defect; the gap this EIP closes is coverage, not correctness of
what `lc` already does.

**Keep a single `is_overloaded/0` boolean.** Declined in favor of severity
levels. A single flag cannot distinguish "76% memory, throttle new
connections" from "one allocation from OOM, drop retained writes too," and
forces every trigger to fire the same response regardless of how much it
actually costs to fire it.

**Use `mria_status:get_shard_lag/1` as the primary or only replicant
signal.** Declined per Mria's own comment
(`mria_status.erl:273-275`): an overload detector that can block on an
`erpc` to the node it suspects is overloaded is self-defeating. Kept only as
an opportunistic, already-flagged-only corroborator, never as a trigger.

**Bypass route/topic table writes, cluster session-registry writes, or
rule-engine dispatch under overload.** See Actions — each was investigated
and declined with a specific reason: route writes have no MQTT-level
best-effort cover the way retained messages do; registry writes risk
duplicate sessions, a worse outcome than the overload being shed; rule-engine
dispatch already has its own backpressure policy, and a second, uncoordinated
one would confuse rather than help.

**Reuse the raw `sysmon.mnesia_tm_mailbox_size_alarm_threshold = 500` as the
sole decision threshold, with no baseline scaling.** Declined — a fixed
absolute number cannot be correct for both a small single-table node and a
large multi-tenant core node. Kept only as a floor beneath the derived,
baseline-relative watermark.

**Model the new detectors as per-zone config, inside
`zone.overload_protection`.** Declined — run queue, memory, `mnesia_tm`
mailbox, and replicant backlog are node properties: a node has exactly one
`mnesia_tm` process and one memory total regardless of how many zones its
listeners are configured with. Modeling detection at zone granularity would
let a single node report contradictory overload state depending on which
zone's config happened to be consulted. Node-scoped config
(`sysmon.overload_protection.*`) matches the actual scope of every signal;
only the *actions* (which already vary sensibly by zone) stay per-zone.

**Extend gateway protocols (MQTT-SN, CoAP, LwM2M, STOMP) to honor
`backoff_new_conn` in this EIP.** Declined for scope, not principle — each
protocol has its own listener and channel implementation that does not share
`emqx_connection`, `emqx_ws_connection`, or `emqx_channel`, so each would need
its own integration point, individually surveyed and tested. This is real,
identified follow-up work, not a design decision to leave gateway protocols
unprotected indefinitely; it is out of scope for this EIP because folding it
in would multiply the review surface of an already broad change without
touching the indicators this EIP exists to add.
