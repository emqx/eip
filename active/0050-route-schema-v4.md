# Route Storage Schema v4

## Changelog

* 2026-11-10: @zmstone Initial draft
* 2026-11-10: @zmstone Review schema selection and repeat the rebased prototype benchmarks

## Abstract

EMQX keeps each wildcard route as one row of a Mria `ordered_set` table. In
the current storage schema (v3) the row key is `{Words, {Dest}}`: the topic
filter as a list of level binaries, and the destination in a one-element tuple.

This EIP proposes storage schema v4 for EMQX 7.0. The key becomes
`{PackedFilter, Dest}`. The filter is one binary, where a level separator, `+`,
`#` and an empty level are reserved bytes. The packed binary sorts in the same
order as the word list, so the trie search algorithm does not change.

In a prototype, a wildcard route took 136 bytes instead of 255 on a table of
100,000 routes, and a route lookup took 25% to 32% less elapsed time on the
same tables. Exact-topic routes do not change.

A cluster that is upgraded from 6.x keeps v3 during the rolling upgrade.
A full cluster restart with v4 configured (the default) completes the switch,
the same way 5.10.4 moved from v2 to v3.

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
The seek sentinel `''` and numbers must never be stored as destinations.

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
  are decoded from the packed bytes. The common path must check for reserved
  bytes while splitting. This cost has not been measured.

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

The rules extend the v2 to v3 rules in `emqx_router:init_schema/0`:

1. A node asks its running peers for their schema version
   (`emqx_router_proto_v1:get_routing_schema_vsn/1`).
2. A v1 or v2 peer, or v2 table metadata in the live Mria schema, prevents
   boot. The operator must first complete the upgrade to v3 on 6.x.
3. When peers or live table metadata indicate both v3 and v4, or a peer
   reports an unsupported schema version, the node refuses to boot and prints
   the steps to resolve the conflict. A peer that is still starting or cannot
   be reached has not reported a version.
4. When responding peers all use v3 or all use v4, the joining node uses that
   version. This takes precedence over its local default or configuration.
5. When no peer answers with a version, the node uses the version of the
   route tables registered in the live Mria schema.
6. With no peer version and no route table metadata, the node uses the
   configured version, which is v4 by default.

The metadata check is against the live `mria_schema` table, as in
`emqx_router:has_v2_tables/0`. That table uses `ram_copies`; old route table
names in the on-disk Mnesia schema alone must not force v3 after a full
cluster restart.

A node that runs v3 in a 7.0 cluster logs a warning with the upgrade steps:
remove any explicit `broker.routing.storage_schema = v3` setting, or set it to
v4 on every node; then stop all nodes and restart them one by one. Changing
the setting alone does not switch a running v3 cluster. A full restart with an
explicit v3 setting still selects v3.

## Prototype Results

A throw-away prototype is on branch
[`zmstone/emqx:261029-route-v4-experiment`](https://github.com/zmstone/emqx/tree/261029-route-v4-experiment).
It is rebased onto `dev-63` at `65480039c4`. It changes the existing v2/v3
table layouts directly, so it must use fresh, isolated data directories. It
does not implement the proposed v4 shard, schema negotiation or the escape of
bytes `0` to `4`. Its correctness and performance results apply only to
filters and topics without the unescaped reserved bytes `0` to `3`.

### Method

* Measured on 2026-11-10 after rebasing the prototype onto `dev-63` at
  `65480039c4`. The tested prototype code is `65b8d128eb`.
* Each lookup does what `emqx_router:match_routes/1` does for wildcard routes:
  the search, then one `{route, Filter, Dest}` per match.
* The table is an ETS `ordered_set` with the router's options
  (`read_concurrency`, `write_concurrency`, `decentralized_counters`) and rows
  `{routeidx, Key, []}`.
* EMQX OTP 28.4.1-10 with `+S 1:1 +sbt db`, on an AMD Ryzen 9 9950X
  (16 physical cores, 32 logical CPUs, 59 GiB RAM). Frequency boost was
  enabled and the CPU governor was `powersave`.
* No other BEAM, Common Test or build process was active before the run.
  The host had 54 GiB available. The one-minute load average was 0.73 at the
  start and 0.99 at the end.
* Elapsed time uses `erlang:monotonic_time(nanosecond)`, not a CPU-time
  counter. The value is the median of 3 interleaved round medians. Each round
  is the median of 7 batches, calibrated to about 20 ms for v3. Brackets show
  the lowest and highest round median. Times are rounded to 0.01 µs.
* Memory and garbage were measured in 3 full repetitions. ETS bytes were
  identical; reclaimed words agreed at the integer precision shown. Garbage
  uses 20,000 lookups per variant and workload, and an Erlang word is 8 bytes.
* Ten workloads come from the saved implementation of emqx/emqx#19558. Three
  more use tables of 100,000 routes. Destinations include node-name atoms and,
  in the mixed table, shared-subscription tuples. `v4words` is the v4 variant
  used by the router in this prototype.

The [raw results](https://github.com/zmstone/emqx/blob/b480825fcd10e8e5c750373af591bd2fb62fb6ee/scripts/route-v4-bench/results-261110.txt)
and [benchmark harness](https://github.com/zmstone/emqx/blob/65b8d128eb93a7cac78772a74e4c4700288eb135/scripts/route-v4-bench/v4bench.erl)
are pinned to the measured code. From that prototype checkout, with a quiet
host and the matching toolchain:

```sh
make test-compile
scripts/route-v4-bench/run.sh check
for round in 1 2 3; do
    scripts/route-v4-bench/run.sh mem
    scripts/route-v4-bench/run.sh garbage
done
scripts/route-v4-bench/run.sh time
```

### Results

Lower ETS memory, reclaimed words and elapsed time are better. The bytes per
route of the small tables include a large fixed table cost.

| Workload (route count; matches per lookup) | Build | ETS (bytes/route; identical in 3 runs) | Garbage (words/lookup; equal rounded values in 3 runs) | Elapsed (µs/lookup; 3-round median [range]) |
|---|---|---:|---:|---:|
| 100k `devices/dev-N/+/cmd`; 1 match | v3 / dev-63 @ `65480039c4` | 255.2 | 226 | 1.09 [1.06–1.09] |
| 100k `devices/dev-N/+/cmd`; 1 match | v4 prototype @ `65b8d128eb` | 136.0 | 177 | 0.78 [0.76–0.78] |
| 100k `devices/dev-N/+/cmd`; no match | v3 / dev-63 @ `65480039c4` | 255.2 | 216 | 1.27 [1.27–1.27] |
| 100k `devices/dev-N/+/cmd`; no match | v4 prototype @ `65b8d128eb` | 136.0 | 155 | 0.86 [0.85–0.86] |
| 50k `tenant-T/site-S/+/+/#` + 50k shared fleet routes; 1 match | v3 / dev-63 @ `65480039c4` | 284.0 | 290 | 1.30 [1.29–1.30] |
| 50k `tenant-T/site-S/+/+/#` + 50k shared fleet routes; 1 match | v4 prototype @ `65b8d128eb` | 163.2 | 214 | 0.97 [0.96–0.99] |
| 1 `#` route; 1 match | v3 / dev-63 @ `65480039c4` | 1248.0 | 169 | 0.30 [0.29–0.30] |
| 1 `#` route; 1 match | v4 prototype @ `65b8d128eb` | 1240.0 | 44 | 0.15 [0.14–0.15] |
| 3 filters; 2 matches | v3 / dev-63 @ `65480039c4` | 589.3 | 260 | 0.66 [0.62–0.69] |
| 3 filters; 2 matches | v4 prototype @ `65b8d128eb` | 504.0 | 201 | 0.55 [0.55–0.55] |
| 16 filters; 16 matches | v3 / dev-63 @ `65480039c4` | 310.0 | 900 | 2.73 [2.65–2.77] |
| 16 filters; 16 matches | v4 prototype @ `65b8d128eb` | 204.0 | 1017 | 2.68 [2.68–2.68] |
| 1 filter, 64 destinations; 64 matches | v3 / dev-63 @ `65480039c4` | 233.5 | 2712 | 9.53 [9.53–9.70] |
| 1 filter, 64 destinations; 64 matches | v4 prototype @ `65b8d128eb` | 145.5 | 1239 | 3.64 [3.64–3.69] |
| `+/+/+/+`, 16 destinations, 100-byte levels; 16 matches | v3 / dev-63 @ `65480039c4` | 246.0 | 644 | 2.73 [2.71–2.73] |
| `+/+/+/+`, 16 destinations, 100-byte levels; 16 matches | v4 prototype @ `65b8d128eb` | 190.0 | 353 | 1.18 [1.17–1.18] |
| 16 filters, 100-byte levels; 16 matches | v3 / dev-63 @ `65480039c4` | 390.0 | 1122 | 4.33 [4.30–4.41] |
| 16 filters, 100-byte levels; 16 matches | v4 prototype @ `65b8d128eb` | 228.0 | 1185 | 4.08 [3.94–4.08] |
| 1 filter, 100-byte levels; 1 match | v3 / dev-63 @ `65480039c4` | 1488.0 | 193 | 0.96 [0.96–0.97] |
| 1 filter, 100-byte levels; 1 match | v4 prototype @ `65b8d128eb` | 1280.0 | 121 | 0.47 [0.47–0.48] |
| 1,000 filters; 1 match | v3 / dev-63 @ `65480039c4` | 209.1 | 172 | 0.70 [0.70–0.71] |
| 1,000 filters; 1 match | v4 prototype @ `65b8d128eb` | 129.0 | 151 | 0.53 [0.52–0.53] |
| 4 filters with empty levels; 4 matches | v3 / dev-63 @ `65480039c4` | 470.0 | 268 | 0.60 [0.59–0.61] |
| 4 filters with empty levels; 4 matches | v4 prototype @ `65b8d128eb` | 406.0 | 249 | 0.63 [0.63–0.63] |
| `$SYS` topic, 3 filters; 1 match | v3 / dev-63 @ `65480039c4` | 538.7 | 161 | 0.34 [0.33–0.34] |
| `$SYS` topic, 3 filters; 1 match | v4 prototype @ `65b8d128eb` | 496.0 | 109 | 0.32 [0.32–0.33] |

On the 100,000-route workloads, v4 uses 42% to 47% less ETS memory and takes
25% to 32% less elapsed lookup time than v3. The empty-level workload takes
6% longer. The round ranges overlap on the 16-matching-filter workload, so
this run does not establish a timing improvement for it. v4 reclaims 13% and
6% more words in the two workloads with 16 distinct matching filters; it
builds a new binary for each matched filter.

### Correctness checks on the prototype

* A differential check compared the v3 search, the v4 search and
  `emqx_topic:match/2` on each route: 3,000 random tables with 20 topics each,
  with no mismatch. Levels included empty levels, `$SYS`, UTF-8 and `+`/`#`.
* The existing PropEr tests passed 2,000 codec/order cases and 3,000 search
  cases. They cover all three topic strategies and both result reconstruction
  strategies. They do not cover reserved control bytes.
* With v4 keys in the router, the rebased prototype passed 154 Common Test
  cases, with 0 failures and 0 skips: `emqx_router_SUITE` (8),
  `emqx_routing_SUITE` (20), `emqx_broker_SUITE` (60),
  `emqx_shared_sub_SUITE` (36) and `emqx_topic_index_SUITE` (30).
* The repository pre-push sanity checks passed against `dev-63`.

### Not measured

* A broker-level benchmark. The numbers above are router lookups only.
* Several schedulers. A packed filter longer than 64 bytes is a reference
  counted binary, so `ets:next/2` updates a shared counter for it. Contention
  on that counter was not measured.
* The extra test for bytes `0` to `4` in the split loop.

## Configuration Changes

`broker.routing.storage_schema` accepts `v3` and `v4` in 7.0, and the default
becomes `v4`. The field stays hidden. v2 must be retired before the upgrade.

## Backwards Compatibility

* **No data migration.** Route tables are `ram_copies`. Each node rebuilds its
  routes from its sessions when it starts.
* **Legacy v2.** A 6.x cluster can still use v2. Before upgrading to 7.0,
  switch it to v3 with a full cluster restart while all nodes still run 6.x.
  A 7.0 node refuses to join a cluster that still uses v2.
* **Rolling upgrade from 6.x.** 7.0 nodes that join a 6.x cluster use v3. They
  log a warning. Once every node is configured to use v4 (the default), a full
  cluster restart switches the cluster to v4.
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

* the minimum 6.x version to upgrade from, and that the cluster must use v3;
* how to remove an explicit v3 setting and perform a full cluster restart
  after the rolling upgrade to enable the smaller route rows;
* what the v3 warning at boot means.

## Testing Suggestions

* PropEr tests for the packed format: the same order as v3 word lists, decode,
  and the escape of bytes `0` to `4`.
* A differential test of the v4 search against `emqx_topic:match/2` on random
  tables and topics, including topics with bytes `1` to `4`.
* The router, routing, broker and shared subscription suites with v4.
* Cluster tests of the schema selection: a new cluster uses v4; a joining
  node follows v3 or v4 peers despite a different local setting; v2,
  unsupported reported versions and conflicting v3/v4 peers or table metadata
  prevent boot; a full restart enables v4 despite old Mnesia table
  definitions; an explicit v3 setting keeps v3 after a full restart; Mria
  removes the rows of a node that leaves, on a core node and on a replicant
  node.
* A broker-level publish benchmark with a large wildcard route table, on
  several schedulers.

## Declined Alternatives

The first two alternatives were repeated in the 2026-11-10 run. The other
measurements below are earlier prototype observations and were not repeated
on this host.

* **Keep v3 keys and change only the search.** The saved implementation of
  emqx/emqx#19558 matches a binary topic without a split. It does not change
  the row size. In the new run its elapsed lookup times on the 100k tables
  were within 3% of v3: 1.06, 1.31 and 1.28 µs/lookup against 1.09, 1.27 and
  1.30 for v3. These are the device hit, device miss and mixed workloads,
  respectively; the raw results include the timing ranges.
* **A topic index of level positions or level lengths.** The topic stays one
  binary, and each comparison walks the topic and the filter together. The
  Erlang compiler keeps a match context for only one binary in such a loop, so
  each step allocates a sub-binary for the other. In the new run these variants
  reclaimed up to 6.8 times as many words and took up to 3.2 times as long as
  v3 per lookup.
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
  would all need the same check. For a topic without those bytes, the
  reserved-byte check still adds work to the split. Its cost has not been
  measured.

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
