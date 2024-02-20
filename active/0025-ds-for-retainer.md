# Durable storage for MQTT retained messages

## Changelog

* 2024-01-18: @savonarola Initial draft
* 2024-01-22: @savonarola Add more optimizations for the "straightforward approach with optimizations"; declare it as the chosen one

## Abstract

We implement [reliable persistent storage](0023-rocksdb-message-persistence.md) for the messages participating in publish/subscribe operations. We want to have a similar storage for the retained messages.

## Motivation

Retained messages are an important feature of MQTT. For example, they may be used as a state or configuration storage for devices without persistent storage. The current implementation has significant limitations:
* Retained messages are stored in a mnesia table, so scalability is limited for such message insertions.
* To provide fast lookup, the message table is also stored in memory, so scalability is also limited from the memory consumption point of view.
* Current indexing capabilities have some limitations:
    * Appropriate indices should be manually specified for nonstandard topic schemes.
    * The reindex process is not automatic and quite complicated.
    * Indices consume a significant amount of memory.

We want to get rid of many of these limitations by reusing the durable storage (DS) concept and implementations from general message persistence:
* We want reliable and efficient off-memory storage for retained messages.
* We want a more effective mechanism for indexing retained messages, requiring less memory and being more automatic (like LTS).
* We want a more flexible mechanism for changing the storage schema and retention policies.
* We want to take advantage of any implemented DS backends for storing retained messages.

## Design

### Straightforward approach

The straightforward approach is to use just the same DS as for the regular message replay:
* have a different DB for retained messages;
* append (`store_batch`) retained messages into the DB;
* interpret empty bodies as tombstones;
* on message lookup, calculate streams and immediately fold them to reduce each topic to the last message.

#### Possible callback implementation

The retainer must provide the following callbacks:

```erlang
-callback delete_message(context(), topic()) -> ok.
%% strore_batch([tombstone_message()])

-callback store_retained(context(), message()) -> ok.
%% strore_batch([message()])

-callback read_message(context(), topic()) -> {ok, list()}.
%% get_streams for a concrete topic & fold over a concrete topic

-callback page_read(context(), topic(), non_neg_integer(), non_neg_integer()) ->
    {ok, list()}.
%% get_streams for a filter & fold over all topics matching filter (!!)

-callback match_messages(context(), topic(), cursor()) -> {ok, list(), cursor()}.
%% get_streams for a filter & fold over all topics matching filter (!!)

-callback clear_expired(context()) -> ok.
%% drop generations

-callback clean(context()) -> ok.
%% drop all generations

-callback size(context()) -> non_neg_integer().
%% get_streams over all topics & fold (!!)
```

#### Problems of the straightforward approach

* `page_read` is used from the dashboard and is often used with the `#` topic. Implementing the callback efficiently is impossible — we should fold over _all_ topics, sort somehow, and only then cut out the required page.
* The same is true for the `size` callback.
* The same is true for the `match_messages` callback. However, _currently_ we admit that the whole set of retained messages for a subscription is small enough to fit into memory.

### Straightforward approach with optimizations

An obvious optimization is to have slightly different key schemas for the LTS storage of retained messages storage implementation — not
```
ts_epoch | lts_index_bits | ts_rest | message_id => message
```

but just

```
lts_index_bits | topic => message
```

to have generation automatically "compacted".

Other optimizations:
* We do not use generations for retained messages.
* We implement alternative sharding based on the topic, not on the client id/node id.
* To simplify replay, we may encapsulate streams for different shards into a single iterator.

Thus each topic is stored uiquely in the storage, and we do not need to fold over all topics to implement `page_read` and `size` callbacks.

With this approach, we may implement `match_messages` callback without folding, in constant space.
We use iterator state as `context()`.

`page_read` may be implemented in the same manner, however, we need to "scroll" the iterator to the required page.

### Topic indexing approach

The alternative approach is that we use the DS only for _topic indexing_. That is, we store not
```
lts_index_bits | topic => message
```
but
```
lts_index_bits | topic => #message{}
```

At the same time, we have a separate storage for the messages themselves, and we store them by topic.
```
topic => message
```

The storage
* is an ordered key-value storage, where the key is a topic, and the value is the message.
* is not sharded/generational; only one message per topic is stored.

With this approach, the callbacks `page_read` and `size` are trivially implemented. Also, `read_message` is implemented by reading the message from the KV storage by a key.

#### Problems of the topic indexing approach

The topic indexing is more flexible (e.g., we may index messages in replicated RocksDB DS but keep them in FoundationDB KV), it has some problems:
* things get entangled. The storage implementation passed to DS should cooperate with "additional" KV storage
of the retainer.
* We need to tie many things together: DS, DS storage implementation, KV

### Other approaches

We may create completely standalone storage for retained messages, not using high-level DS at all, but using only low-level DS primitives, like LTS tries and bitfield mappers.

### Additional opportunities

In straightforward approaches, we may still keep the TS part in the storage but additionally introduce some kind of a "secondary index" where we keep timestamped key by topic/clientid/etc.

"Secondary index" will allow us still have storage "compacted" by topic/clientid/etc: we will delete the old timestamped key when we store a new one.

E.g., to have compaction by topic:

1. We want to insert a message `#message{topic="a/b/c", ts=TS1, ...} = message1`.
1. We insert the message into the storage `high_bits(TS1) | lts(topic) | low_bits(TS1) => message1`.
1. We insert the key `topic => high_bits(TS1) | lts(topic) | low_bits(TS1)` into the "secondary index".

Then, we want to insert the new message with the same topic:

1. We want to insert the mesage `#message{topic="a/b/c", ts=TS2, ...} = message2`.
1. We insert the message into the storage `high_bits(TS2) | lts(topic) | low_bits(TS2) => message2`.
1. We get the old key `high_bits(TS1) | lts(topic) | low_bits(TS1)` from the "secondary index" by `topic`.
1. We insert the key `topic => high_bits(TS2) | lts(topic) | low_bits(TS2)` into the "secondary index".
1. We delete `message1` by the fetched old key `high_bits(TS1) | lts(topic) | low_bits(TS1)` from the storage.

This will have the advantage of still being able to "subscribe" to any topic pattern with a regular DS replayer, with the semantics: "give me the actual message(data) and all the ongoing updates." In turn, it may be helpful for subscriptions to some kinds of events, like session registrations, takeovers, etc.

### Conclusion

We choose the straightforward approach with optimizations.
It allows us to reuse the existing DS implementations and abstractions. Also, with this approach, we may implement all the operations in constant space, which will be a significant improvement over the current implementation.

## Configuration Changes

Currently, we have only one type of storage for retained messages:

```
retainer {
    ...
    backend {
        type = built_in_database
        ...
    }
}
```

Like in message persistence, we will have:

```
retainer {
    ...
    backends {
        built_in_database {
            enabled = false
        }
        fdb {
            enabled = true
            ds {
                ...
                # options for emqx_ds:open/2
            }
            ... other options
        }
    }
}
```

## Backwards Compatibility

No backwards compatibility issues are expected. Retainer configs having old `backend` will use the old storage, and those having `backends` will use the new one.

## Testing Suggestions

## Declined Alternatives

* Straightforward approach (without optimizations).
* Topic-only indexing approach.

