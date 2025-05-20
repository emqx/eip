# Linear Session Registry (LSR)

## Changelog

* 2025-04-20: @qzhuyan First draft
* 2025-05-20: @qzhuyan rename to LSR, add more notes for the tests

## Abstract

For a new incoming MQTT connection, the node may look for an existing session matching the same clientid 
within the cluster for taking further actions such as taking over the session, discarding the session, 
or creating a new session.

This session registration info is a cluster wide global state maintained by the underlying database. 
It is replicated asynchronously (eventually consistent), and it leads to problems when replication is 
lagging or the old channel process is unresponsive.

In this EIP, we propose another session registration subsystem called LSR ("Linear Session Registry") that 
expands the channel prop with version (e.g., `transport_started_at` timestamp when transport connects) so that the 
young and old channels could be determined to minimize the issues caused by race conditions during session takeover
while the client is reconnecting, especially in a massive volume.

## Motivation

For the current implementation of channel registry (emqx_cm_registry), it has eventual consistency.

@NOTE: Term 'channel registry' is used in current EMQX code base as session binds to channels, one session may have multi channels
but now it is suggested to use the term 'session registry'.

In this doc, we mix use of both, `channel registry` means the old `emqx_cm_registry`, while `session registry` means the LSR.

The channel registration gets a dirty write on the core node from an RPC call.
The registration then gets replicated among the core nodes asynchronously (dirty).
The core nodes then replicate the registration to the replicant nodes.
When looking for existing channels while handling the new connection, EMQX do a lookup from the local copy.

This is a design for high availability and high performance, having the assumption that replication is finished 
before the next client connection. But when replication starts lagging due to various reasons, the following issues pop up:

- A node does not see that the session exists. It creates a new session instead of taking over the existing one.

- A new channel could take over a session from the wrong channel due to the wrong order of receiving replications.

- The older channel with an unresponsive connection kicks the latest channel, causing the client to get disconnected unexpectedly.

- Wrong Session Present flag in MQTT.CONNACK is returned to the client.

  If handling node doesn't know the existence of the session on the other node, it will open new session and return Session Present = false
  to the client. The client will get confused if it just disconnect from other node and reconnect to the handling node.
  
  further more it also forks the session into two, whether the next reconnect will takeover this session or the other session 
  becomes uncertain.
            
- The deregistration may overrun the registration, leaving a registration unreleased.

- When a channel process starts to take over or create a new session, it runs the operation in an ekka locker transaction which uses 
a cluster-wide, domain-specific fine lock, ekka_locker. By involving all the core nodes, it protects the operation from being executed 
in parallel but not the registration data is not 'thread safe', leading to unexpected behaviors.

- The ekka_locker is error-prone in that it is very easy to leave a lock unreleased in the cluster such that when the channel process gets 
killed in the middle of the processing of session takeover, the deadlock detection needs 30s to detect and then remove the lock. 
This means the broker will be unavailable to that client for that period, and the retries from the client will just create more 
load (TLS handshake, client AUTH) on the cluster.

We need to explore other option to ensure correctness for mission-critical use cases with some performance loss as a trade-off.

## Design

### Reasoning

Based on real-world scenarios, we have the following assumptions:

- Client-to-broker latency exceeds the time synchronization difference between EMQX nodes.

  Client-to-broker: 10ms+
  EMQX nodes time diff: < 2ms which requires NTP server in use is correctly configured.
  
- Clients do not reconnect within millisecond delays, so it is unlikely to have two channels race for the same clientid for session operations.

Therefore, we could use the transport connected timestamp (`transport_connected_at`) in ms as the version of the channel.

@NOTE, we could use other timestamp too such as client provided timestamps embeded in MQTT user props. 

Based on the current EMQX implementation, we have the following facts:

- Most of the time, replication is not lagging, so it is efficient to read from local to check if the self channel is the latest 
  or already outdated (there exists a newer one).

- Removing the ekka locker transaction enables more than one channel to begin takeover of the session ({takeover, 'begin'}), but still, 
  only one can finish ({takeover, 'end'}).

- It is no harm if the current channel finished the 'begin' phase for a non-latest channel.

- For correctness, it should be okay to retry 'begin' takeover of another newly discovered latest channel.

- Combined with local dirty reads and transactional updates, we could balance correctness and performance.

- The channel of the latest connection from the client is preferred to wait and retry takeover of the session instead of getting a 
  negative MQTT.CONNACK immediately.

- Session registration is a bag table; multiple channels of the same client could co-exist. New design could follow this.

Based on the above, with versioning, channels from the same client become comparable, and EMQX could find the most recent channel, check if the current connection it is processing is outdated
that it communicate with the client with latest view.

We use three versions during the processing:

- `ver_LocalMax`

  Max version of existing `channel`s from **local async dirty read**.
  
  Value is `undefined` if and only if no matching channel is found.

- `ver_RealMax`

  Max version of existing `channel`s from **transactional read** from the cluster.
  
  Value is `undefined` if and only if no matching channel is found.

- `ver_curr`
  
  `channel` Version from the execution process stack.
  
With actions below:

IF `ver_curr` < `ver_LocalMax`, drops the processing early, returns negative CONNACK. __HAPPY FAIL__

ELSEIF `ver_curr` < `ver_RealMax`, drops the processing late, returns negative CONNACK. __EXPENSIVE FAIL__

ELSEIF `ver_RealMax` > `ver_LocalMax`, restart the processing with `ver_RealMax` with limited number of retries. __MOST EXPENSIVE PATH__

ELSEIF `ver_RealMax` == `ver_LocalMax`, write with `ver_curr` and continue with the processing. __HAPPY ENDING__

It is very unlikely to happen that `ver_curr` > `ver_RealMax` AND `ver_RealMax` < `ver_LocalMax`, but for correctness, it should abort the transaction 
and then return MQTT.CONNACK with a negative reason code then log with INFO message.


```mermaid
---
config:
      theme: redux
---
flowchart TD
    NewConn-->ReadLocalMax
    ReadLocalMax-->C0{LocalMax>Curr?}
    C0--TRUE-->Fail
    C0--FALSE-->C1{CleanStart}
    VsnDirty --->Takeover
    C1 --FALSE--> VsnDirty@{shape=input}

    Takeover--Fail-->NewSession

    C1 --TRUE--> NewSession

    ReadRealMax-->C2{RealMax>Curr?}

    Takeover--Success---->Transaction
    NewSession-->Transaction


    C2--FALSE-->C3{LocalMax==RealMax}
    C2--TRUE-->Abort

    C3--True-->Commit
    C3--False-->Abort

    
    Abort-->C4{Retryable?};
    C4--YES-->VsnDirty
    C4--NO-->Fail

    Commit-->TakeoverContinue

    Fail-->NegtiveConnack
    TakeoverContinue-..->PositiveConnack

    subgraph LocalAsyncDirty
        direction TB
        ReadLocalMax
        C0
        C1
        VsnDirty
        Takeover
        NewSession
    end
    subgraph Transaction
        direction TB
        ReadRealMax
        C2
        C3
        Abort
        Commit
    end
```

The transaction to run is micro and abortive, it only reads and writes the same key, only one lock is taken so it is unlikely to get restarted by mria/mnesia.

### record #lsr_channel{}

`lsr_channel` of LSR represents the EMQX channels that provides a global view and maintain a global state within the cluster.

``` Erlang
-record(lsr_channel, {
    id :: lsr_session_id(),
    pid :: pid() | undefined,
    vsn :: integer() | undefined
}).
```

`lsr_channel` is bag table using the value of sessionid/clientid as the key (id).

`#lsr_channel.pid` is the channel process pid, global unique, and contains embedded info of the node.
`#lsr_channel.vsn` is used to compare or sort the channels.

For write, it is done transactionally. A Mria transaction with sharding is executed on one of the core nodes (strong consistency among core nodes), 
and it will get replicated to the replicant nodes asynchronously (eventual consistency).

For read, a node reads from local storage.

For delete, it is done asynchronously (dirty), but it will never overrun the writes.

There is no need for updates in core or replicant. @TODO Do we need to prove that it is written once?

### #chan_conn{}

The `#chan_conn{}` in node local ets table `CHAN_CONN_TAB` will be expanded with new field `vsn` for local vsn trackings.

### lsr_channel lifecycle

`lsr_channel` is written when:

1. the session is created AND after updating the local ETS for other tables of the channel.

1. the session takeover 'begin' is finished AND after updating the local ETS for other tables of the channel. 

`lsr_channel` can be read at any time.


For deletion, there are the following triggers:

1. the channel process exits gracefully, where in the terminating phase, it deregisters itself from LSR in dirty async context.
   triggers:
   - transport close
   - taken over (`{takeover, 'end'}`)
   - discarded
   - kicked

1. node down/Mnesia down event: 
   
   One living node may remove the channel belonging to the down node. It must be done only once within 
   the cluster successfully.
   
   For replicant node down, a phashed core node will be assigned to clean the channels of the down node.
   
   For core node down, channels should be cleaned up while core is started or cleaned up via maintaincence API/CLI if user is
   not able to get that core node back to online. 
   
### Drawbacks

- Compare to the `ekka_locker`, using transaction will stress the `mnesia_locker` which is single point of bottleneck.

  But `mnesia_locker` is more robust than `ekka_locker`.

- "registration history function" will not be supported as we don't want large data set.

  It must be reimplemented for LSR.
  
### Other dependencies

- `Mria` may offer a transaction API with a restricted number of retries.
   
## Backwards Compatibility

`LSR` should be disabled by default with a feature switch.

### LSR Disabled

When `LSR` is disabled, there should be no backwards compatibility issue, and the EMQX cluster should work as it does in the old version.

### LSR Enabled within the cluster

Once `LSR` is enabled, `LSR` can co-exist with `emqx_cm_registry` with a feature switch.

READs from `LSR` storage only. WRITES go to both if `emqx_cm_registry` is also enabled (global), but DO NOT use `ekka_locker:trans`.


### LSR 'Partially Enabled' within the cluster

During a rolling upgrade, the EMQX cluster could run with `LSR` partially enabled due to the mixed versions of EMQX nodes.

To be compatible with old bpapi calls from the old version of EMQX,

For newer EMQX, all registrations (`emqx_cm:register_channel/1`) will be updated to the `LSR` table only.

and there are two problems to solve:

1.  In the RPC call, channel version is missing.
2.  `emqx_cm_registry` is the only provider, and it has no channel vsn.

Thus, we define the fallback method here for Node evacuation and rolling upgrade:

For newer EMQX handling the call from older EMQX, the channel version uses the value of the timestamp: `disconnected_at`.

Newer EMQX MUST NOT disable the `emqx_cm_registry`; as part of the standard implementation, the writes will go to both storage.

For newer EMQX calling the older EMQX, the newer EMQX should write to the `LSR` once the bpapi call is successful. 
The newer EMQX MUST not update the `emqx_cm_registry` storage as it is part of the call handling on the older EMQX.


### LSR runtime enabling

UNSUPPORTED for now.

### LSR runtime disabling

Supported, but we don't know the side effects. Leave it as @TODO.


## Document Changes

If there is any document change, give a brief description of it here.

## Testing Suggestions

### Functional test

1.  The existing common test suites should be expanded with a new group `lsr_on`, `lsr_off`

    -   takeover suite
    -   cm suite

    Add a new cluster test suite for testing core + replicant roles covering known issues in previous chapters
    
2.  Rolling upgrade should be tested with the `LSR` switch on.

## Performance test

Performance tests should be performed against a 3 cores + 3 replicants cluster.

Compare the performance with `LSR` on/off with the following scenarios:

1.  Initial connections
1.  Disconnect and leaves no persistent session.
1.  Disconnect and leave persistent session.
1.  Session takeover with existing connection
1.  Session takeover without existing connection
1.  Session discard with existing connection
1.  Session discard without existing connection
1.  While having a large number of persistent session, kill replicants see if core stands.
1.  Realword reconnect: two groups of clients takeover/discard each other's sessions with auto reconnect on.

## Declined Alternatives
    
Here goes which alternatives were discussed but considered worse than the current.
It's to help people understand how we reached the current state and also to
prevent going through the discussion again when an old alternative is brought
up again in the future.

