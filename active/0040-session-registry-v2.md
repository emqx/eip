# Improved Channel Registry

## Changelog

* 2026-07-03: @ieQu1 Initial version

## Abstract

This EIP aims to improve performance and safety of the global session registry,
lower RAM consumption on the replicant nodes and save Mria replication bandwidth.

## Motivation

Currently channel registry is a regular Mria table that has replicas on all nodes.
However, normally registry information is not needed by the clients operating normally,
except for the cases when they connect, disconnect or take over.
Nonetheless, Mria replicates channel data to all replicant nodes,
even if it's not being actively read.

1. This wastes the RAM on the replicant nodes on the table they don't actively read and limits scalability of the cluster
2. Information about any channel getting added or removed is broadcast to the entire,
   even if it is only relevant to at most one process involved in the takeover.
   This wastes network bandwidth.

This covers the performance problems with the current implementation.
But there are also safety and consistency problems:
ownership model for the channels has holes.

Normally, each node owns its own channels.
However, when a node goes down, other nodes take care of deleting the channels that were located on the node.
This model falls apart if we take into consideration network partitions:
in case of a partition,
nodes start to delete each others' channels,
leading to inconsistent state.

Currently this problem is mitigated using a reconciliation protocol activating when the nodes re-connect to each other.
They try to reconstruct the global registry using a locally available information.
This procedure, however, is not perfect:
there's a period of time when the table is in inconsistent state,
and any client that connected during the reconciliation is not guaranteed to properly take over.
Moreover, reconciliation may lead the table with multiple channels existing simultaneously.

## Design

### New Mria feature: core-only tables

First, to address the performance problems,
we propose a new type of Mria tables: core_only.

Core only tables are created by passing `{core_only, true}` attribute to `mria:create_table` function.
This attribute disables much of mria RLOG functionality,
preventing replicants from attempts to create local replicas of the table.
Note that mria already has a functionality related to forwarding write table operations
(`transaction`, `async_dirty`, `dirty_write`, counter update) to the core nodes.
It also can forward read-only operations to the core node when the local replica is considered inconsistent:
operations like `ro_transaction` and `dirty_read` may become RPC to the core node.

`core_only` tables may piggyback on that functionality.

### EMQX registry table

An entirely new `core_only` `emqx_cm_registry_v2` table of type `set` will be created,
storing records like this:

```erlang
#reg{ clientid :: emqx_types:clientid()
      channels :: [#chan_reg{}]
    }
```

where

```erlang
#chan_reg{ pid :: pid()
         , n_restarts :: non_neg_integer()
         , time_of_birth :: integer()
         }
```

(Note: this nested structure is used to avoid taking whole-table locks used by `mnesia:match`)

`n_restarts` field is used for cleanup on behalf of nodes that went down,
as a way to delimit clients that connected to the node before and after a restart.

This mitigates the problem of network partitions,
as classy advances `n_restarts` counter in two cases:

1. When the node goes down normally,
   it sets its own state to `down`.

2. When a node disconnects from the cluster (due to netsplit or abrupt stop),
   then its liveness state is set to `down` by consensus of core nodes.

   Since liveness data (including `n_restarts`) is replicated via the classy membership CRDT,
   a node that reconnects notices that its liveness state was changed,
   and restarts itself, thus increasing `n_restarts`.

   This guarantees two things:
   - Clients that were connected before the netsplit get disconnected
   - Cleanup only affects the clients that were connected before the restart.

`birth_time` can be used to sequence channels.

### Channel registration

All registry updates should be done atomically inside a mria transaction.

Client does all updates to the registry using a single function:

```erlang
{ok, NRestarts} = classy:n_restarts(),
emqx_cm_registry_v2:try_register(ClientId, self(), NRestarts, erlang:monotonic_time())
```

This function has the following logic.

First, the client uses `mnesia:wread` to look up the existing channels for the client ID,
while taking a Mnesia write lock on the key.

Depending on the return value:

1. If there is no records, transaction inserts a fresh `#reg{}` record into the table, containing with a single `#chan_reg{}`.
   Then it returns `new` to the client.
   The channel proceeds to create a fresh session.

2. If there is a record with a single `#chan_reg`, then transaction adds the new channel to the record.
   Then it returns `{takeover, pid()}` to the client.
   The channel proceeds to takeover the session.

3. If `#reg{}` record contains > 1 channels, the transaction leaves it as is and returns
   `{error, takeover_in_progress}` message.
   The channel disconnects with the appropriate reason code.

### Registry clean up

#### Cleanup by a live node

TBD

#### Cleanup by a third party

TBD

## Configuration Changes

TBD

## Backwards Compatibility

In order to maintain backward compatibility,
the nodes should maintain two version of code and only switch to registry v2 when all nodes in the cluster support it.

## Document Changes

TBD

## Testing Suggestions

TBD

## Declined Alternatives
