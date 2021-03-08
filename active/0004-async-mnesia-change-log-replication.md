# Async Mnesia transaction replication in EMQ X 5.0

## Change log

* 2021-02-21: @zmstone Add more details
* 2021-03-01: @k32 Minor fixes
* 2021-03-05: @k32 Add more test scenarios and elaborate on the push model.

## Abstract

Escape from Erlang distribution mesh network, embrace `gen_rpc`.

## Motivation

The current replication (Mnesia) is based on full-mesh Erlang distribution which
does not scale well and has the risk of split-brain.

## Design

### Log-based replication for Mnesia

Log-based replication is the most commonly use approach in distributed
databases.

Typically when strong consistency is required, database operations or
transactions will have to be serialized by an elected leader which means all
nodes will have to delegate the operations through the leader.
The drawback of this approach is that the leader will easily become a bottleneck
when the cluster size grows.

For key-value stores, one way to solve it is to shard the database, e.g. Riak
and Cassandra, nodes form a hash ring, and only manage keys hashed to their
ranges. The DB entrypoint may also not have to be the leader, or there is simply
no leader at all, as soon as this happens, the consistency is no longer 'strong'
and there is a need to resolve conflicts. e.g. when two clients try to write the
same key concurrently and hitting two different nodes in the cluster which do
not sync with each other.

If the value is a primitive value set operation, typically last-write-wins is
good enough to resolve conflicts. If the writes update a small part of an
object, CRDT is for the rescue.

While we there is still a lack of full investigation on how much of the data
in EMQ X requires CRDT to get away from ACID transactions, below two types
of data seem to be of simple enough schema for last-write-wins.

* Routing tables `emqx_route`, `emqx_trie` and `emqx_trie_node`.
* Global channel registry table `emqx_channel_registry`.

After all, we use Mnesia dirty APIs to write some of the tables.

### Async-replication of Mnesia changes

TODO: check if dirty operations in transaction triggers activity logging

* Log Mnesia changes in the Mnesia cluster

A pseudo implementation of the transaction layer:

```
transaction(Fun, Args) ->
  Fun2 = fun() ->
    ok = Fun(Args),
    Changes = get_mnesia_activity(),
    Key = generate_key(erlang:timestamp(), node()),
    %% Note: Real code should avoid traversing Ops list multiple times:
    [ok = write_ops_to_another_table(Shard, Key, find_ops_for_shard(Ops, Shard)) || Shard <- shards()],
    ok
  end,
  {atomic, ok} = mnesia:transaction(Fun2)
end.
```

Where `Changes` is essentially a list of table operations like:

```
[ {{TableName, Key}, Record, write},
  {{TableName, Key}, Record, delete}
]
```

Note: transactions running on different nodes in the cluster can be recorded to the rlog table out-of-order.
Therefore traversing the rlog table twice can lead to different results.

* Non-clustered nodes fetch change logs from cluster.

Nodes outside of the Mnesia cluster can make use of `gen_rpc` to fetch changes from
the Mnesia cluster nodes.

There are two possible models of interaction between core and replicant:

- Push model:

  Replicant nodes issue a `watch` call to one of the core nodes.
  The core node creates an agent process that issues `gen_rpc` calls to the replicant nodes using data about transactions that were recorded to the rlog table.
  Once the replication is close to the end of the rlog table, the agent process subscribes to mnesia events to the rlog table and start feeding the replicant with realtime stream of OPs. 
  The time threshold to identify 'close to the end of rlog' should be configurable, and realtime stream should start after (with maybe a bit overlapping) the agent reaches the `$end_of_table`

- Pull model:

  Replicant nodes issue `gen_rpc` calls to one of the core nodes with the latest transaction key it has locally.
  The core node replies with the list of transactions that happened since.
  This model is simpler, but it introduces latency and it's more prone to missing transactions from different core nodes due to the reordering problem mentioned above.

### Bootstrapping Empty Nodes

The Mnesia logs should have a limited retention, so it is impossible to keep
all the changes from the very beginning.

An empty node will have to fetch all the records from Mnesia before applying
the real-time change logs.

## Configuration Changes

Two new configuration needs to be added to `emqx.conf`:

1. `node_role`: enum [`core`, `replicant`]
2. `core_nodes`: a list of core nodes for a `replicant` node to 'watch'
   and from which transaction logs are fetched.

## Backwards Compatibility

A `replicant` node should never originate data `write`s and `delete`s.
Due to the fact that the nodes are still all clustered using erlang
distribution. So some of the `rpc`s, (such cluster_call) should not be made
towards the replicant nodes if they are intended for writes.

## Document Changes

1. New clustering setup guide
2. Update configuration doc for new config entries

## Testing Suggestions

1. Regression: clustering test in github actions.
1. Functionality: generate data operations (write and delete),
   apply operations and compare data integrity between core and replicant nodes
1. Performance: benchmark throughput and latency
1. Regression: test clock skews.

   1. Create a cluster of two core nodes (A and B) and a replicant node C.
   1. Set time to the future on one of the core nodes, say A
   1. Restart the replicant node, make sure A node detects that first and removes the routes to C
   1. Immediately connect some clients to the replicant node
   1. Check that the replicant node didn't lose its own routes after replaying the transactions from the rlog

## Declined Alternatives

* `riak_core` was the original proposal, it's declined because the change is
  considered too radical for the next release. We may re-visit it in the future.
