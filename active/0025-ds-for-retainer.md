# Durable storage for MQTT retained messages

## Changelog

* 2024-01-18: @savonarola Initial draft

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

An obvious optimization is to have slightly different key schemas for the LTS storage of retained messages storage implementation — not
```
ts_epoch | lts_index_bits | ts_rest | message_id => message
```

but just

```
lts_index_bits | topic => message
```
to have generation automatically "compacted".

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

### Problems of any approach using DS

* Since we need to "compact" or "fold" the messages, sending only the last one to the client, we need an additional component — "stream replayer", which is currently private to the message persistence core.
* Unlike usual replay, it seems there is no way to replay retained messages in constant memory since we need to reduce by topic, and the number of topics is not limited.

### Conclusion

We need to choose the approach, either between the proposed ones or some other one.

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

