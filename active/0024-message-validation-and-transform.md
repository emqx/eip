# Message validation and transform

## Changelog

* 2023-10-31: @zmstone Initial draft
* 2022-12-19: @zmstone Update after review

## Abstract

A new feature for EMQX v5 to validate, transform, and filter MQTT messages.

## Motivation

### Data validation

EMQX has no native support for data validation.

Technically, by using EMQX rules engine, it is possible to validate the incoming
MQTT messages before sending the message off to data bridges.

For instance, one can write a rules engine SQL like below to
drop messages which are not avro encoded and also when the 'val' field is not greater than 10.

```
SELECT schema_decode(my_avro_schema, payload) as decoded from t/# where decoded.val > 10
```

However, currently rules are only used in data bridges, but they do not interfere
MQTT message pub/sub.
For example, if there is client subscribed to `t/#` it would still receive the avro encoded message.

If we also want to stop the message being published, then there would be a need for a message republish action,
and the publisher and subscriber will likely be forced to use different topics.
e.g. publisher publishes to `t1/...`, republish action send it to `t2/...` for subscribers to receive.

This can work, but not easy to use.

### Message transform

Same as data validation, if message is to be transformed using rules engine SQL,
it would require a republish action.

## Design

Develop a data processing feature which can support:

- Message validation
- Message transform
- Message filtering

This data processing step should happen after authorization and before rules engine.
Probably can make use of the 'message.publish' with a hook priority which
positions the callback after authorization, but before data bridges.

### High level design

* Introduce 2 different data processing types: `validation` and `tranform`.
* Make use of the rules engine SQL, but without the `FROM` clause as it's always the MQTT message being th input.

Each data processing rule should have a unique ID. And each rule should have a input topic-filter name which
can be used to build a topic index for quick look-up.

The common parts can be described as hocon config below:

```
{
    id = id1 # unique id assigned by user
    topic = 't/1' # input
    sql = "SELECT ....." # processing
    type = validation | transform
}

```

### Message Validation

```
{
    id = id1
    topic = 't/1'
    type = validation
    action_if_invalid = disconnect # or 'drop'
    sql = "SELECT schema_decode(my_avro_schema, payload) as decoded WHERE decoded != undefined"
}
```

### Message filter

Message filter is just a validation with 'drop' action.
So there is no need to create a new data process for it.

### Message transform

To support message transform, we would need to create a naming convention for MQTT message construction.

The proposed key word is `new`, by default, the message is copied to `new` then SQL language can
mutate the `new` in `SELECT` clause.

For example, a rule which can increment `payload.value`.

```
{
    id = id2
    topic = 't/2'
    type = transform
    sql = "SELECT payload.value + 1 as new.payload.value"
}
```

To make it easer for user, we should also consider:

- Support all the existing message properties binding, for example `topic`, `qos` `retain`.
- Use `new.user_properties` for user properties.
  This is because the user properties in MQTT message object quite deeply nested,
  so it was not quite easy to use.
  We are already using `user_properties` keyword in some data bridge actions.

To support message expansion (one transform to many),
the `new` will be copied as many times as a `FOREACH` statement has to loop.

```
sql = "FOREACH payload.myarray as element DO element as new.payload
```

## Configuration Changes

New config which may look like:

```
message_process = [
    {
        description = "drop message if it is not compabitble with my avro schema"
        topic = 't/1'
        type = validation
        action_if_invalid = disconnect
        sql = "SELECT schema_decode(my_avro_schema, payload) as decoded WHERE decoded != undefined"
    },
    {
        description = "increment payload.value"
        topic = 't/2'
        type = tranform
        sql = "SELECT * as new, payload.value + 1 as new.payload.value"
    }
]
```

## Backwards Compatibility

New feature.

## Document Changes

Docs should be created to guide users to use the new feature.

## Testing Suggestions

The significant part of this feature is pure functional, this makes the testing more suitable as unit tests.

Integration tests should be more focused on the management APIs.

## Declined Alternatives

- Extend authz to support SQL.
  This was declined because authz's principal is MQTT topcis, we do not want to introduce data to it.
- Add new actions to rules for 'deny' and 'disconnect' actions.
  This was declined because
  - Rules lack of ordering while validation and transform are to be chained.
  - We might implement as a part of the rule engine internally, but at least from user's perspective, it should be an independent feature (not like an extension of rules)
