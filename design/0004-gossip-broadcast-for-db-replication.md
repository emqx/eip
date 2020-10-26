# Gossip Broadcast for DB Replication

```
Author: Zaiming Shi <stone@emqx.io>
Status: Draft
Type: Design
Created: 2020-10-21
EMQ X Version: 5.0
Post-History:
```

## Abstract

Use gossip (plumtree) broadcast for database replication in EMQX cluster.
Targeting V5.0 release.

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

For key-value stores, one way to solve it is to shard the database, e.g.  Riak
and Cassandra, nodes form a hash ring, and only manage keys hashed to their
ranges. The DB entrypoint may also not have to be the leader, or there is simply
no leader at all, as soon as this happens, the consistency is no longer 'strong'
and there is a need to resolve conflicts. e.g. when two clients try to write the
same key concurrently and hitting two different nodes in the cluster which do
not sync with each other.

Is our data conflict free? The word ‘free’ here means programmatically
resolvable without transport layer protocol support.

While so far it is still not very clear if all our use cases are conflict free,
one thing seems to be quite commonly accepted is that the subscription
information (from which derives the trie tables) is conflict free.

Keyed by client-id, a subscriber should be globally unique, this allows us to
apply LWW (last write wins) strategy to resolve conflict.

### Broadcast change logs

Plumtree is an algorithm introduced in 2007 as the paper titled
"Epidemic Broadcast Trees"[1]. There are three most widely adopted
implementations in Erlang: riak_core[2], plumtree[3] and partisan[4], plumtree
and partisan are essentially forks of riak_core. Worth noting that Vernemq[5]
has a fork of plumtree.

riak_core’s wiki[6] page from github explained in detail which adjustments have
been made compared to the paper[1]. In short, instead of classic gossip which
picks random peers to forward messages, plumtree algorithm tries to form a
spanning tree for the clustered nodes, and the broadcasts are sent to neighbor
peers. Quote from [6]

> Plumtree was chosen, primarily, because of its efficiency in the stable case
  while maintaining reliability. When the graph of nodes is a proper spanning
  tree, each node will receive the payload exactly once. In failure cases,
  nodes may receive the payload more than once, but the act of doing so heals
  the tree and removes redundant links.

, we propse to write and replicate an appliction level level change
log using gossip broadcast. Here 'application level' means on top of Mnesia.

### Implentation

Our long term plan is to replace Mnesia with another database or storeage
engine, so it makes less sesnse to tap into Mnesia transaction internals
to extract table operations.

An overly simplified version of a transaction log could look like.

```
transaction(Fun, Args) ->
  Fun2 = fun() ->
    ok = Fun(Args),
    ok = write_and_replicate(Args)
  end,
  {atomic, ok} = mnesia:transaction(Fun2)
end.
```

Assuming that the logged `Args` are idempotent.

## References

[1] https://www.gsd.inesc-id.pt/~ler/reports/srds07.pdf
[2] https://github.com/basho/riak_core
[3] https://github.com/helium/plumtree
[4] https://github.com/lasp-lang/partisan
[5] https://github.com/vernemq/vernemq
[6] https://github.com/basho/riak_core/wiki/Riak-Core-Broadcast
