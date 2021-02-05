# Async Mnesia transaction replication in EMQ X 5.0

```
Author: Zaiming Shi <zaiming.shi@emqx.io>
Status: Draft
Type: Design
Created: 2020-10-21
EMQ X Version: 5.0
Post-History:
```

## Abstract

Escape from Erlang distribution mesh netowrk, embrace gen_rpc.

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
    Ts = now(),
    ok = write_changes_in_another_table(Ts, Changes),
  end,
  {atomic, ok} = mnesia:transaction(Fun2)
end.
```

Where `Changes` is essentially a list of table operations like:

```
[ {{TalbeName, Key}, Record, write},
  {{TableName, Key}, Record, delete}
]
```

* Fetch change logs from non-clustered nodes

Nodes outside of the Mnesia can make use of `gen_rcp` to fetch changes from
the Mnesia cluster nodes.

### Bootstraping Empty Nodes

The Mnesia logs should have a limited retention, so it is impossible to keep
all the changes from the very beginning.

An empty node will have to fetch all the records from Mnesia before applying
the realtime change logs.

TODO: add implementation details.
