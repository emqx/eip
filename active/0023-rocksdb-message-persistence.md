# MQTT message persistence with an embedded database (RocksDB)

## Changelog

* 2022-08-25: @ieQu1 Initial commit
* 2022-11-24: @ieQu1 Spit theoretical consideration and implementation details
* 2022-11-26: @ieQu1 Apply review remarks

## Abstract

MQTT standard specifies that the MQTT broker must store the messages of the clients that are offline.
EMQX community edition (up to version 4) fulfilled this promise as long as all broker nodes are online, since the offline messages were stored in RAM.
Enterprise edition allowed to store the offline messages in a external database.

## Motivation

This feature will improve message delivery guarantees of EMQX broker and make it ready for the new markets that require such guarantees.

## Theoretical considerations and open problems

### Replay ordering guarantees:

- Weak guarantees:

  - Ordering: messages published by the same client within the same topic must be replayed in order they were published by the client
  - Consistency: messages within data retention interval and session expiry interval seen by one subscriber must also be eventually seen by any other subscriber replaying the data even if one or several EMQX nodes are shut down permanently during replay

  This corresponds to PRAM consistency: http://jepsen.io/consistency/models/pram

- Strong guarantees:
  - messages published to the same topic by different clients are always be replayed in the same order

Initially it only makes sense to support weak guarantees, since EMQX doesn't follow the strong guarantees as of now.

It is helpful to introduce a concept of "logical FIFO" identified by `hash(publisher.clientid) ++ hash(topic)`.
Weak consistency guarantees hold for each logical FIFO.

### Subscriber-publisher throughput matching

Using a single subscriber to process all messages matching given topic filter has an inherent problem of using a single TCP connection per client.
This creates fundamental asymmetry between publishers and subscribers: while there may be multiple clients publishing to the topic, they all have to fan into a single TCP connection, forwarding data to a single subscriber.
In comparison, Kafka allows to subscribe to each topic-partition via separate TCP connection and to use multiple clients per consumer group.
Also each topic-partition can be served by a different broker instance.
This improves horizontal scalability of the whole system.

Thankfully, EMQX supports group subscriptions using `$share/<group>/<topic-filter>` subscription.
I would argue that supporting _shared_ replay of persistent messages (or at least factoring such feature into the initial design) is crucial to be competitive in the market,
as it will allow to match throughput of the subscribers with the amount of traffic in theory and in practice.

There always will be some degree of ambiguity as to how to handle group replays in a situation when clients in the same group request replay starting at a different time.
I propose to use "first client wins" approach, when the first subscriber to join the group sets the cursor for the entire group, and the following clients effectively steal the work from it.

Clients can communicate start time of the replay to the broker via MQTT user properties.
Same goes for the desirable properties of work stealing.

### Sharding

Sharding is absolutely necessary to achieve the throughput matching the competition.


There are several sharding strategies.

#### Sharding by topic index

Pros:

- Replication strategy is easier to reason about
- Replaying is easier to implement

Cons:
- Load may become unbalanced.
  Some topics may receive significantly more data than the others, particularly in fan-in scenario.

- More backplane network transfers will be involved, since the LB is not aware of the topics that the clients publish or subscribe to.
  Messages have to be forwarded through backplane network to the appropriate node.
  This disadvantage is a relatively insignificant when replication factor is high.

#### Sharding by publisher clientid

Pros:
- More even load distribution since the clientid's are unique and often random
- Load-balancer friendly.
  Clientid is known at the time of connection, so the LB can connect the client to the correct shard directly.
  Additionally the broker can ask client to reconnect to the broker handling the correct shard.

Cons:
- Replaying is more tricky, since the messages matching the topic filter can be found on any node in the cluster.
  Replaying the messages will require starting a "replay client" process on all nodes and developing a simple protocol for coordinating the clients.

### DB schema

There are two types of data stored persistently:
- Messages
- Sessions

The biggest challenge is developing a database schema for the messages that

- Enables fast inserts (in case of rocksdb it means minimizing GC/compaction times)
- Enables efficient replay of a single topic
- At the same time, enables efficient wildcard topic scans
- Enables fast (re)start of the replay from a given time or offset
- Doesn't introduce a lot of storage space overhead

Choosing a correct representation of the message key is crucial from correctness and performance perspectives.
Any strategy for choosing the key must guarantee uniqueness and possibility of fast replay of the messages matching the topic filter in the correct order,
as well as possibility to failover the leader for the shard.
RocksDB supports fast iteration over sorted keys, so naturally we want table keys to be adjacent in both space and time.

Messages published by the client have the following fields from the start:

- Topic
- ClientId

Topic can be represented as a tuple of topic layers: `{Layer1, Layer2, Layer3, ...}` or topic layer hashes.
Additionally, we can introduce sequence numbers (for example per publisher's clientid or per shard) or use wall clock or Lamport clock.

The key can be constructed from any combination of these parameters.

It is helpful to introduce the notions of space and time when reasoning about the keys:

- Topic represents space
- Unique timestamp or sequence number represents time

Data retention:
- RocksDB provides "Compaction Filter" callback that allows to drop entries older then TTL.

### Key format

We use the following key format

```
<time_epoch>-<topic_index>-<time_offset>-<message-id>
```

This partitions the key space into "epochs", making it easy to jump to a rough timestamp.

Where `topic_index` is composed of hashes of each topic levels (pseudocode):

```erlang
index("foo/bar/baz" ++ Rest) ->
  combine([hash("foo"), hash("bar"), hash("baz"), hash(Rest)]).
```

Let `N_l` is the maximum number of topic levels that make up the topic index.
Topic levels deeper than `N_l` should be joined with `/` into a single token before hashing.
Special care also must be taken for calculating indices of topics with the number of levels less than `N_l`: missing levels should be replaced with values that can't be a part of the topic level, for example character `/`.

In the simplest case `combine` function can just shift bits of each topic level on each iteration, producing a constant-size integer.
More sophisticated implementations of `combine` function can exist too, for example [Z-order curve](https://en.wikipedia.org/wiki/Z-order_curve) can be used to optimize replaying of topics filters with multiple wildcards following each other (e.g. `foo/+/+`).

With this type of key prefix replaying the topic filters with wildcards can be solved rather elegantly.
Consider topic filter `foo/+/bar`.
For the sake of simplicity we assume that `combine` function is a simple bitshift, but it should be noted that any other strategy will work mostly the same.
Suppose every topic level takes two bits in the resulting hash and `N_l` equals 3.
Suppose topic index of this topic filter is `101001`.
We can create a the bitmask corresponding to this topic filter by setting bits corresponding to the wildcard levels to zeros: `110011`.

Therefore iterating the database can be done using the following pseudocode:

```erlang
replay(TopicFilter) ->
  Bitmask = gen_bitmask(TopicFilter),
  Query = gen_topic_index(TopicFilter) band Bitmask,
  It = db:seek(Query),
  replay(TopicFilter, Query, Bitmask, It).

replay(TopicFilter, Query, Bitmask, It) ->
  {Key, NextIt} = db.next(It),
  {TopicIndex, KTimestamp} = parse_key(Key),
  if (TopicIndex band Bitmask) =:= Query ->
       Message = db.get(Key),
       case topic_matches(TopicFilter, Message#msg.topic) of
         true ->
             handle_message(Message);
         false ->
             %% Hash collision
             ok
       end,
       replay(TopicFilter, Query, Bitmask, NextId);
     true ->
       %% Reached the end
       ok
  end.
```

Cons:
- This schema is optimized for fast access to the topics, but it's not very efficient jumping to a particular timestamp, since time is in the suffix of the key.
- This approach can handle queries containing only one wildcard: either containing adjacent `+`s or a single `#`.
  Queries with multiple wildcards interleaved with concrete topic layers should be scanned separately.


### Combining realtime messages with the historical message replay

In the database schema section we proposed to sort keys by topic.
While this is ideal for optimizing DB access while reading historical data, it leaves a significant problem:
realtime data is not added to the DB in historical order.
So the client replaying messages that match topics `foo/1` and `foo/2` will no longer see any messages added to `foo/1`, once it starts replaying the keys corresponding to `foo/2`.

Below is the sketch of the solution (thorough testing and modelling is needed):

1. Client connects with clean start =:= `false`.
1. A client handler process is started.
1. The client handler process initiates message replay for the topic filters from the saved session in separate processes.
1. Once the replay reaches a next topic index (i.e. when it finishes replaying messages for index `101010` and starts replaying `101011`), it sends a message to the client handler with the last key that has `101010` prefix.
1. Client handler process subscribes to the realtime flow of the messages in the topics matching this index, the messages are buffered
1. It then iterates through the database to find any remaining messages
1. It then sends all the buffered messages and switches to the realtime flow

### Potential for future optimizations: keyspace based on the learned topic patterns

Let's outline a few key problems with this kind of schema:

- Key length is fixed, and it's not adjusted for entropy.
  This is not ideal when some topics receive a lot of traffic consisting of small messages (e.g. metrics).
  Each message may contain merely 2 bytes of payload, but its key may take several bytes.

- It's optimized for traversal over topics only in certain directions.

- Topic hashing with fixed entropy per level uses keyspace inefficiently

On the surface, these problems seem almost impossible to tackle, since the number of topics may be huge (we can serve hundreds of millions of clients, each one of them can publish to its own topic), topics can have however many levels, and the topic filters can be arbitrary.
However, we can assume that even if the number of *topics* is huge, the *structure* of these topics follows fixed number of patterns.
This is a very realistic assumption, since the code running on the client devices is the same, so each device publishes only to a handful of topics, perhaps containing client id.

So it makes sense to design schema around **learned topic patterns** rather than topics, since their number is expected to be in hundreds at most, rather than hundreds of millions.

It opens up a question of how to learn the topic patterns.
We may start from a trie that contains statistics about the number of topic levels.
Nodes with abnormally high number of children are good predictors for the wildcard subscriptions with "+", and also require the most entropy per key.

Trie statistics are constantly updated as new data is written to the storage.
Every once in a while an asynchronous "optimizer" process takes a look at the trie and derives a new optimal pattern for the data.
If this pattern is different from the existing one, a new generation is created.

For example, consider a topic "device/data/adfgfsdf/temperature".
From the trie analysis the algorithm knows that the 3rd level of the topic under "device/data" has high very entropy.

So it rearranges the topic layers like this, based on entropy:

Prefix = "device/data/../temperature",
Suffix = "adfgfsdf".

And the resulting key is composed like this: "PP|SSSSSSS|", where P - bit of the prefix hash, and S - bit of the suffix hash.

As a downside, now it's impossible to implement "#" replays without having to look into the trie.

Structure of the trie:

```erlang
%% Key of the trie node:
-type key() :: { updated_ts()    %% Perhaps it makes sense to prefix keys with
                                 %% the creation timestamp to make sure the
                                 %% existing iterators don't skip over the
                                 %% newly created topics

               , binary() | '+'  %% Once the number of child nodes in the trie
                                 %% passes some threshold the children get
                                 %% replaced with a single child with the key '+'
                                 %% It contains the merged subtrees of all
                                 %% previously recorded children
                                 %%
                                 %% This is how we build a predictor for the
                                 %% wildcard queries: '+' nodes are likely to be
                                 %% selected by topic filters with '+'!
               }.

-type node() :: {key(), _Children :: node()}.
```

Let's say clients publish messages to the topics "devices/%clientid/temperature", "devices/%clientid/pressure" and "other_topic/heartbeat".

After recording data from 100 clients we did trie compaction and arrived to the following structure:

```erlang
%% Example of a trie with a learned topic structure:
[{{0, <<"devices">>},
    [ {{0, '+'},
        [{{0, <<"temperature">>}, []},
         {{0, <<"pressure">>}, []}
        ]}
    ]}
 {{0, <<"other_topic">>},
    [ {{0, <<"heartbeat">>},
        []}
    ]}
]
```

It's likely that a subscriber will collect temperature from the devices using "devices/+/temperature" filter.
Thankfully, the trie already contains a structure that reflects this.
It can be used to rewrite the topic into the prefix and suffix part as shown above, and make use of data locality.

### Message replay

How to deal with the timestamps with presence of clock skews in the cluster?

### Replication

TBD.

## Design

The design must be split into several layers:

- *Storage layer* for storing messages on a single node/shard and iterating through them
- *Replication layer* for assuring redundancy and failovers of a shard, mapping physical EMQX nodes to vnodes, etc.
- *Logical layer* for hiding the implementation details related to the local storage, sharding and replication layers
- *Connectivity layer* that integrates MQTT broker functionality with the logical layer

Each layer can be tested separately.

### Storage layer

At the very least it must provide the following APIs:

```erlang
-opaque iterator() :: _.

-spec store(#message{}) -> ok.

-spec start_replay(TopicFilter, StartTime) -> iterator().

-spec next(iterator()) ->
    {end, iterator()}
  | {next, #message{}, iterator()}
  | {next_topic, #message{}, iterator()}.
```

as well as callbacks for the replication layer.

### Replication layer

TBD

### Logical layer

Logical layer hides the distributed and sharded nature of the message storage.
It also maintains and persists session information.

### Connectivity layer

TBD

## Configuration Changes

- Zone configuration must be extended with the persistence layer configuration
- A consistency check must be implemented to make sure mount points of different zones don't overlap.
  It is necessary to make sure each topic is always associated with one and only one set of persistence configuration parameters.

## Backwards Compatibility

This feature is backward-compatible, as long as the previous experimental version of persistent sessions was not enabled.

## Document Changes

- Document how to enable and configure the feature.
- This feature will change EMQX from a rather stateless service to a very much stateful one, which requires provisioning of storage.
  Describe changes to the deployment.
- Performance considerations


## Testing Suggestions

- Use [snabbkaffe](https://github.com/kafka4beam/snabbkaffe) for integration tests
- Use [concuerror](https://github.com/parapluu/Concuerror/) to check replication and replay algorithms

## Declined Alternatives

### Interleaving time and topic: topic layer hashes + time, partition by time

One possibility is to use the following key format:

```
topic_index-timestamp-clientid
```

There are two approaches to these problems:

1. Time and topic index can be interleaved using Z-order curve, essentially organizing keys into a quadtree in `{topic_index, time}` space.
2. Every N seconds we can create a new rocksdb column family, that holds data only for a particular time interval.
   This approach will also make garbage collection easier, since it's possible to simply drop column families once they become outdated.
   Also it allows to tune storage properties in the runtime more easily, since the new settings can be applied to the new partition without reindexing or modifying the old ones.

However finding the best solution can only be done through experimentation.
