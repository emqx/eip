# Route Storage Schema v4

## Changelog

* 2026-11-10: @zmstone Initial draft

## Abstract

EMQX keeps each wildcard route as one row of a Mria `ordered_set` table. In
the current storage schema (v3) the row key is `{Words, {Dest}}`: the topic
filter as a list of level binaries, and the destination in a one-element tuple.

This EIP proposes storage schema v4 for EMQX 7.0. The key becomes
`{PackedFilter, Dest}`. The filter is one binary, where a level separator, `+`,
`#` and an empty level are reserved bytes. The packed binary sorts in the same
order as the word list, so the trie search algorithm does not change.

In a prototype, a wildcard route took 136 bytes instead of 255 on a table of
100,000 routes, and a route lookup used 28% to 35% less CPU on the same tables.
Exact-topic routes do not change.

A cluster that is upgraded from 6.x keeps v3 until a full cluster restart, the
same way 5.10.4 moved from v2 to v3.

## Motivation

### Every node holds every route

Routes are stored in Mria merge tables. A merge table holds the records of all
reachable peer nodes, so each node keeps a full copy of the cluster's wildcard
routes. The cost of one row is paid once per node.

For routes such as `devices/dev-N/+/cmd`, a v3 row takes 255 bytes of ETS
memory. At that rate, one million wildcard routes take about 255 MB on each
node. With v4 rows they take about 136 MB.

### Where the bytes of a v3 row go

A v3 row is `{routeidx, {[<<"devices">>, <<"dev-1">>, '+', <<"cmd">>], {Node}}, []}`.
On top of the fixed cost of an ETS row, it holds:

* one list cell (16 bytes) per level;
* one binary (at least 24 bytes) per literal level;
* a one-element tuple (16 bytes) around the destination.

A v4 row is `{routeidx, {<<"devices", 0, "dev-1", 0, 2, 0, "cmd">>, Node}, []}`.
It holds one binary for the whole filter. Of its 136 bytes, about 40 are the
ETS tree node, 56 are the two tuples, 16 are the binary header, and the rest
is the filter itself.

### Lookups copy and compare keys

The trie search calls `ets:next/2` many times per lookup. Each call copies the
key out of ETS to the process heap. A v3 key is a list of several terms. A v4
key is one binary and a destination. The lookup makes less garbage, and each
comparison of a filter level with a topic level is one binary match.

## Scope

This EIP covers:

* the row format of the wildcard route table;
* the search over that format, used by `emqx_router`;
* the selection of the schema at boot, and the upgrade from v3.

This EIP does not cover:

* the exact-topic route table, which keeps its v3 row format;
* the other users of `emqx_topic_index` and `emqx_trie_search`, such as the
  durable session router, the rule engine, the cluster link router and the
  schema validation registry;
* a native (NIF) route store. See Future Discussion.

This document names modules and functions. It does not give line numbers,
because line numbers change between branches.

## Design

### Row format

```erlang
-record(routeidx, {entry :: {PackedFilter :: binary(), dest()}, unused = []}).
```

The `unused` field stays. Mnesia requires at least one attribute besides the
key.

The destination is not wrapped. A destination is a node name (an atom), a
`{Group, Node}` tuple for a shared subscription, or an external destination
tuple. The search seeks with the key `{Prefix, ''}`. The atom `''` sorts before
every other atom and before every tuple, so it sorts before every destination.
A destination must never be a number.

### Packed filter

The filter levels are joined with a separator byte. Wildcards and the empty
level are single reserved bytes.

| Element | Bytes |
|---|---|
| Separator between levels | `0` |
| `#` | `1` |
| `+` | `2` |
| Empty level | `3` |
| Literal byte `0` to `4` | `4`, then the byte |
| Any other literal byte | The byte itself |

Examples:

| Filter | Key |
|---|---|
| `devices/+/cmd` | `{<<"devices", 0, 2, 0, "cmd">>, Node}` |
| `a/#` | `{<<"a", 0, 1>>, Node}` |
| `a//b` | `{<<"a", 0, 3, 0, "b">>, Node}` |
| `$share/g/+/x` | `{<<2, 0, "x">>, {<<"g">>, Node}}` |

The format has these properties:

* **Same order as v3.** In v3, `'#'` sorts before `'+'`, `'+'` sorts before
  the empty binary, and the empty binary sorts before any other literal level.
  The byte values keep that order, and the separator `0` keeps the order
  between a level and a longer level that starts with it. So the trie search
  algorithm of `emqx_trie_search` works unchanged.
* **No length prefix and no end marker.** A filter level equals a topic level
  `W` when the packed bytes continue with `W` followed by `0` or by the end of
  the binary.
* **Decodable.** A filter can be rebuilt from its packed form.
* **The escape is for safety only.** `emqx_topic:validate/2` rejects the byte
  `0`, but it accepts the control bytes `1` to `4`. MQTT 3.1.1 (1.5.3) and
  5.0 (1.5.4) only say that a sender SHOULD NOT send U+0001 to U+001F and that
  a receiver MAY reject them. So the format must keep them apart from the
  reserved bytes.

### Search

The search algorithm is the one of `emqx_trie_search`. The new module works
on packed keys:

* **The topic is split once.** The topic is split into level binaries the
  first time a filter needs its levels, and every later comparison reuses the
  list. When every filter the search visits starts with `#`, the topic is not
  split.
* **One binary match per level.** A filter level is compared with a topic level
  `W` as `<<W:Size/binary, 0, Rest/binary>>` or `<<W:Size/binary>>`. When
  neither matches, a binary comparison gives the order for the next seek.
* **Matched filters are rebuilt from the topic.** A literal level of a matching
  filter equals the topic level at the same position. So the result filter is
  built from the topic levels, not decoded from the packed bytes. It is built
  once per filter and shared by every destination of that filter.
* **`$` topics.** A topic that starts with `$` starts the search at its first
  level, as in v3, so `+` and `#` filters at the first level are skipped.
* **Topics with bytes `0` to `4`.** The split detects such a byte. In that rare
  case the topic levels are escaped before the comparison, and matched filters
  are decoded from the packed bytes. The common path pays one more test per
  7-byte step of the split loop.

The module offers the same functions as `emqx_trie_search` that `emqx_router`
uses: `make_key/2`, `make_pat/2`, `match/2`, `matches/3`, `get_id/1` and
`get_topic/1`, plus `match_routes/2`, which returns the routes directly.

### Tables

v4 adds a new Mria shard with two merge tables, both with `auto_clean`:

* an exact-topic table, with the same `#route{}` bag rows as v3;
* the wildcard table, with the v4 `#routeidx{}` rows in an `ordered_set`, with
  the same ETS options as v3.

The exact-topic table keeps its row format. It moves to the new shard only so
that one schema switch covers both tables.

The node pattern of the wildcard table is:

```erlang
{node_pattern, [
    #routeidx{entry = {'_', '$1'}, _ = '_'},
    #routeidx{entry = {'_', {'_', '$1'}}, _ = '_'}
]}
```

Mria uses this pattern to check that a node writes only its own rows, and to
remove the rows of a node that leaves. The destination must therefore stay an
Erlang term in the key. It cannot move into the packed binary.

### Router

`emqx_router` already selects its tables by schema version. v4 adds one more
branch:

* `match_routes/1`, `has_routes/1`: the v4 search;
* `lookup_routes/1`, `has_route/2`, add and delete: the key
  `{pack(Filter), Dest}`;
* `stream/1`, `topics/0`, `foldl_routes/2`, `foldr_routes/2`: decode the packed
  filter of each row;
* `cleanup_routes/1`: nothing to do, because Mria cleans the merge tables, as
  in v3.

### Schema selection at boot

The rules follow the v2 to v3 rules in `emqx_router:init_schema/0`:

1. A node asks its running peers for their schema version
   (`emqx_router_proto_v1:get_routing_schema_vsn/1`).
2. When a peer uses v3, the node uses v3.
3. When no peer answers with a version but the v3 tables exist in the cluster
   schema, the node uses v3.
4. Otherwise the node uses the configured version, which is v4 by default.
5. When the cluster has both v3 and v4 nodes, the node refuses to boot, and it
   prints the steps to resolve the conflict.

A node that runs v3 in a 7.0 cluster logs a warning that a full cluster restart
completes the upgrade, like the v2 warning today.

## Prototype Results

A throw-away prototype is on branch
[`zmstone/emqx:261029-route-v4-experiment`](https://github.com/zmstone/emqx/tree/261029-route-v4-experiment).
It is based on 6.3 and has no compatibility with existing tables. It does not
implement the escape of bytes `0` to `4`.

### Method

* Each lookup does what `emqx_router:match_routes/1` does for wildcard routes:
  the search, then one `{route, Filter, Dest}` per match.
* The table is an ETS `ordered_set` with the router's options
  (`read_concurrency`, `write_concurrency`, `decentralized_counters`) and rows
  `{routeidx, Key, []}`.
* OTP 28.4.1 with `+S 1:1 +sbt db`, on a shared 20-core host with a load
  average of 1.44 at the start and 1.45 at the end.
* CPU is the median of 3 interleaved rounds. Each round is the median of 7 runs
  of about 20 ms. The range in brackets is the lowest and highest round median.
* Garbage is the words reclaimed by garbage collection per lookup.
* Ten workloads come from emqx/emqx#19558. Three more use tables of 100,000
  routes. Destinations are node-name atoms.

### Results

| Workload | ETS v3 (B/route) | ETS v4 (B/route) | Garbage v3 (words/lookup) | Garbage v4 (words/lookup) | CPU v3 (ns/lookup) | CPU v4 (ns/lookup) |
|---|---:|---:|---:|---:|---:|---:|
| 100k `devices/dev-N/+/cmd`, 1 match | 255 | 136 | 226 | 177 | 4929 (4877–5050) | 3307 (3239–3315) |
| same table, no match | 255 | 136 | 216 | 155 | 5881 (5868–5917) | 3824 (3819–3834) |
| 50k `tenant/site/+/+/#` + 50k shared, 1 match | 284 | 163 | 290 | 214 | 5654 (5616–5755) | 4077 (4050–4080) |
| `#` only | 1248 | 1240 | 169 | 44 | 1131 (1121–1161) | 594 (594–595) |
| 3 filters, 2 match | 589 | 504 | 260 | 201 | 2698 (2650–2712) | 2550 (2541–2555) |
| 16 filters, all match | 310 | 204 | 900 | 1017 | 11676 (11658–12376) | 11980 (11960–12007) |
| 1 filter, 64 destinations | 234 | 146 | 2712 | 1239 | 38427 (37619–38493) | 15367 (15340–15448) |
| `+/+/+/+`, 16 destinations, 100-byte levels | 246 | 190 | 644 | 353 | 11228 (11176–11436) | 4729 (4729–4766) |
| 16 filters, 100-byte levels | 390 | 228 | 1122 | 1185 | 20786 (20658–20898) | 18448 (18428–18491) |
| 1 filter, 100-byte levels | 1488 | 1280 | 193 | 121 | 4694 (4664–4728) | 2041 (2020–2057) |
| 1000 filters, 1 match | 209 | 129 | 172 | 151 | 3159 (3131–3166) | 2227 (2214–2248) |
| 4 filters with empty levels, all match | 470 | 406 | 268 | 249 | 2409 (2401–2431) | 2568 (2552–2586) |
| `$SYS` topic, 3 filters, 1 match | 539 | 496 | 161 | 109 | 1416 (1354–1423) | 1509 (1479–1514) |

The bytes per route of the small tables are mostly the fixed cost of the
table.

v4 is slower in three small cases: 16 matching filters (+3%), empty levels
(+7%) and the `$SYS` topic (+7%). It makes more garbage in two cases where 16
different filters match (+13% and +6%), because each matched filter is built
as a new binary.

### Correctness checks on the prototype

* A differential check compared the v3 search, the v4 search and
  `emqx_topic:match/2` on each route: 3,000 random tables with 20 topics each,
  with no mismatch. Levels included empty levels, `$SYS`, UTF-8 and `+`/`#`.
* A PropEr test checked that packed filters sort like v3 word lists and decode
  back to the filter.
* A separate check of the escape, on 17,000 random filters that contain the
  bytes `1` to `5`, found the same order as v3, a correct decode, and no two
  filters with the same packed form.
* With v4 keys in the router, these suites passed: `emqx_router_SUITE`,
  `emqx_routing_SUITE`, `emqx_broker_SUITE`, `emqx_shared_sub_SUITE` and
  `emqx_topic_index_SUITE`.

### Not measured

* A broker-level benchmark. The numbers above are router lookups only.
* Several schedulers. A packed filter longer than 64 bytes is a reference
  counted binary, so `ets:next/2` updates a shared counter for it. Contention
  on that counter was not measured.
* The extra test for bytes `0` to `4` in the split loop.

## Configuration Changes

`broker.routing.storage_schema` accepts `v4`, and the default becomes `v4`.
The field stays hidden.

## Backwards Compatibility

* **No data migration.** Route tables are `ram_copies`. Each node rebuilds its
  routes from its sessions when it starts.
* **Rolling upgrade from 6.x.** 7.0 nodes that join a 6.x cluster use v3. They
  log a warning. A full cluster restart switches the cluster to v4.
* **A 6.x node in a v4 cluster.** A 6.x node does not know v4. It must not join
  a v4 cluster, because it would write v3 rows that the v4 nodes never read.
  A 6.x patch release must refuse to boot when a peer reports a schema version
  it does not know, and the 7.0 upgrade guide must name that patch release as
  the minimum version to upgrade from. This is the same approach as "Upgrade
  all nodes to 5.10.4 or newer" for v3.
* **Rollback.** A cluster that runs v4 can return to 6.x only with a full
  cluster restart.
* **BPAPI.** No new RPC. `get_routing_schema_vsn` returns a new value, `v4`.
* **API.** The functions of `emqx_router` keep their arguments and results.
  Code that reads the route tables directly breaks.

## Document Changes

The 7.0 upgrade guide must state:

* the minimum 6.x version to upgrade from;
* that a full cluster restart after the rolling upgrade enables the smaller
  route rows;
* what the v3 warning at boot means.

## Testing Suggestions

* PropEr tests for the packed format: the same order as v3 word lists, decode,
  and the escape of bytes `0` to `4`.
* A differential test of the v4 search against `emqx_topic:match/2` on random
  tables and topics, including topics with bytes `1` to `4`.
* The router, routing, broker and shared subscription suites with v4.
* Cluster tests of the schema selection: a new cluster uses v4; a 7.0 node
  that joins a v3 cluster uses v3; a cluster with both v3 and v4 nodes refuses
  to boot the new node; Mria removes the rows of a node that leaves, on a core
  node and on a replicant node.
* A broker-level publish benchmark with a large wildcard route table, on
  several schedulers.

## Declined Alternatives

* **Keep v3 keys and change only the search.** emqx/emqx#19558 matches a binary
  topic without a split. It does not change the row size. On the 100k tables
  its CPU was the same as v3 or higher: 4954, 6194 and 5800 ns/lookup against
  4929, 5881 and 5654 for v3.
* **A topic index of level positions or level lengths.** The topic stays one
  binary, and each comparison walks the topic and the filter together. The
  Erlang compiler keeps a match context for only one binary in such a loop, so
  each step allocates a sub-binary for the other. In the prototype this made up
  to 6.8 times the garbage of v3 and was up to 2.7 times slower.
* **Split the topic one level at a time.** A match must reach the last level of
  the topic, unless the filter ends with `#`, and a `+` must still find where
  its level ends. A lazy split would save nothing in 12 of the 13 workloads.
  It would save about 250 ns, and only on a miss that stops early.
* **The level count as the first part of the key.** On tables with filters of
  mixed depth the lookups were 4% to 18% slower. On tables with filters of one
  depth they made one more `ets:next/2` call per lookup, and were up to 2 times
  slower.
* **No separator next to a wildcard.** With other byte values (`#` 0, `+` 1,
  empty level 2, separator 3 only between two literal levels) the order stays
  the same as v3. It saved 0% of ETS memory on the 100k device table, 2% on the
  mixed table, and 4% at most. The gain does not pay for a more complex
  comparison.
* **The destination inside the packed binary, or a node index.** A row would
  take 128 or 119 bytes on the 100k device table. Mria merge tables need the
  node as a term in the record, and a node index needs a cluster-wide mapping.
* **No `unused` field.** Mnesia rejects a table with one attribute.
* **Caches.** A per-process cache of split topics, or a cache from topic to
  routes, would save CPU at the cost of memory per process or per topic.
* **Reject the bytes `1` to `4` in topics.** MQTT allows a server to treat
  these control characters as a malformed packet. But it is a visible change,
  and topics also come from rules, bridges, gateways and the REST API, which
  would all need the same check. For a topic without those bytes, the escape
  costs one more test per 7-byte step of the split.

## Future Discussion

* **A native route store.** Most of a v4 row is the fixed cost of an ETS row:
  the tree node, two tuples and a binary header. A compact store in C, for
  example a radix tree or blocks of front-coded keys, might take 15 to 60 bytes
  per route. This is an estimate, not a measurement. It needs a Mria storage
  backend, and replicant support was not checked.
* **Other topic indexes.** The durable session router, the rule engine, the
  cluster link router and the registries of schema validation, message
  transformation, message queues, streams and topic metrics use
  `emqx_topic_index` or `emqx_trie_search`. They can move to the packed format
  separately.
