# An Example of EMQX Improvement Proposal

## Changelog

* 2026-02-18: @ieQu1 Initial version

## Abstract

Currently, meta-information about shards, sites and the Raft cluster is stored in Mnesia.
This was a temporary design decision made at the early development stages of DS.

This EIP describes a new metadata layer for the builtin Raft durable storage backend, that is meant to replace Mnesia.

## Motivation

Mnesia and DS use very different strategy in regard to clustering and data persistence.
With rare exception of `local_data` tables, Mnesia replicas contain full copy of all data.
This makes each individual node disposable: many cluster management and recovery operations involve dropping data on individual node(s), under the assumption that this operation doesn't compromise the global state.
Generally speaking, Mnesia is much more forgiving, but also less reliable as a long-term storage.

On the contrary, the durable storage
1. Is meant as a long-term reliable storage for valuable customers' data.
2. It is sharded, so each node in the cluster may store a portion of valuable data

Because of such incompatible designs, Mnesia can't be used as a foundation for the durable storage.
However, it doesn't exclude its use in the secondary roles, for example as a distributed cache.

## Design

The general idea of the EIP is about splitting Ra metadata management into tree logical components:

1. Local metadata inventory based on `emqx_dsch` module.
   Each node fully owns information about its shard replicas:
   - The node is able to read and modify its metadata inventory even in case of complete network isolation
   - These changes aren't lost in case of cluster joining or leaving
   - Other nodes are unable to make direct changes to the nodes' inventories.

2. Backplane protocol letting nodes make coordinated changes to their inventories.

3. Change planners.
   Coordinating major changes involving multiple shards or DBs, such as original shard allocation, cluster re-balancing or disaster recovery should be done via "planners".

### Goals and constraints

We expect that shard rebalancing and other complex metadata changes may be required as part of disaster recovery,
in order to heal the cluster that had lost some nodes.
As such, we cannot assume that all nodes will be healthy and operational during such operations.
This adds a great deal of complexity to the design.

### Background: plan-execute pattern

I suggest to embrace "plan-execute" pattern for this task.
It implies splitting the problem into three steps:

1. Gathering the data (I/O is required, subject to network errors)
2. Planning the changes (pure functional code, no I/O).
   Planning stage produces a list of operations that each node should perform to converge to the desired end state.
3. Execution stage where each node independently executes the actions planned at stage 2. (I/O is required)

This approach is beneficial for several reasons:

- The most complex parts of the algorithm can be moved to the planning stage, which is a pure function that can be tested extensively.

- Flexibility.
  There could be multiple planning functions for different situations, be it load rebalancing during normal operation or disaster recovery.

- Fault tolerance.
  With properly designed plan primitives, partial loss of nodes or communication between them doesn't threaten eventual convergence to the expected outcome.
  Since "plan" is a materialized list of CRUD actions stored on the node, it is possible to track its execution or safely cancel it in its entirety.

Constraints:

1. Only one plan involving the DB can be executed at the same time on the site.
2. Plans for different DBs can run in parallel

### Plan primitives

1. `{schedule, DB, PID, Prio, [plan_primitive()]}`.
   Accept a new plan with identifier `PID` for `DB`.

   If there's already a plan in execution, and its priority is greater or equal to `Prio` then the schedule command is ignored.
   If `Prio` is greater then priority of the existing plan, then the command overrides it.

   Plans created by the operator, as a result of CLI command or REST API call should take higher priority than any automation.

2. `{add_replica, DB, Shard, Sites}`.
   Add a local replica of the shard, using `Sites` as the upstream.

3. `{handover_replica, DB, Shard, Site}`.
   Delete a local replica of the shard as soon as `Site` has the replica.

   This operation is meant to safely delete a replica without compromising the replication factor.

4. `{remove_replica, DB, Shard}`.
   Unconditionally remove a local replica.

### Planners

This section lists possible scenarios where creation and execution of the plan can be triggered.

1. Opening of the new DB.
   This use case is possibly the most complex scenario, since in a new cluster nodes may attempt to execute this function simultaneously.

2. Nodes joining or leaving the cluster.

3. Operator commands

Planner functions can take any information from the nodes into account.
They are free to use any method of synchronization.

### Plan execution

`emqx_dsch` pending mechanism will be used for plan execution:

```erlang
Plan = [Cmd1, Cmd2, ...],
emqx_dsch:add_pending({db, DB}, execute_plan, Plan)
```

The entire scheduled plan should be mapped to a single pending action.
Advancing steps of the plan involve removing the existing action and inserting back its tail (if present).

`emqx_dsch` module should support the following new operations for managing the plans:

1. Atomic swap of the existing pending plan with the new one, depending on the priorities.
2. Atomic advancement of plan steps (swapping the list of planned actions with its tail upon completion of a step)

Internally, these actions will be mapped to the existing schema operation primitives,
but their execution will be serialized by the gen server.

Proposed new `emqx_dsch` APIs:

```erlang
emqx_dsch:maybe_execute_plan(DB, Prio, [Action1, Action2, ...]).
```

```erlang
emqx_dsch:replace_pending(pending_id(), Command, Data).
```

### Cache

Since in the new design every node owns its own schema,
CLI and REST API (as well as, possibly, planner functions) need a new way of getting the full cluster view.
For this purpose it is acceptable to use Mnesia.

## Configuration Changes

TODO: There may be CLI and Rest API changes.

## Backwards Compatibility

There should be a migration procedure for importing old data from Mnesia to `dsch`.

## Document Changes

If there is any document change, give a brief description of it here.

## Testing Suggestions

TODO:
The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Declined Alternatives

### Use Raft as a storage for metadata

That design implies creation of a replicated state machine to hold the metadata of DBs and shards.
While this design brings a commonly used replication algorithm to the table and reuses the components that are already in place,
in other aspects (such as disaster recovery and cluster membership changes) it creates more problems than it solves.

### CRDTs
