# Buit-in Message Transformation

## Changelog

* 2023-10-31: @zmstone Initial draft for message validation, filter and transformation (as a part of EIP-0024).
* 2022-12-19: @zmstone Limit the scope message filter and tranformation.

## Abstract

An extension of EMQX Rule engine to support action-less message filter and transformation.

## Motivation


Currently, if one wants to tranform a message before the message is published, the only option is to
make use of the Rule Engine's republish action.

This requires the clients to publish to one topic, and subscribe to another.

## Design

To support message transform, we can create a naming convention for MQTT message construction.

The proposed key word is `new`, by default, the message is copied to `new` then SQL language can
mutate the `new` in `SELECT` clause.

To make it easer for user, we should also consider:

- Support all the existing message properties binding, for example `topic`, `qos` `retain`.
- Use `new.user_properties` for user properties.
  This is because the user properties in MQTT message object quite deeply nested,
  so it was not quite easy to use.
  We are already using `user_properties` keyword in some data bridge actions.
- To support message multiplication (one transform to many),
  the `new` will be copied as many times as a `FOREACH` statement has to loop.

### Examples

- Increment `payload.value`.

```
SELECT payload.value + 1 as new.payload.value FROM 't/#'
```

- Rewrite publishing topic based on value in the payload.

```
SELECT
  CASE WHEN payload.value < 0 THEN 't/negetive'
       ELSE 't/normal'
  END as new.topic
  FROM 't/raw'
  WHERE is_number(payload.value)
```

- Multiply message

```
FOREACH payload.myarray as element DO element as new.payload FROM 't/1', 't/2'
```
### Incorporated with the Rule Engine

Message transformation is essentially the current Rule Engine with below changes.

- There is no `actions`.
- Only zero or exactly one rule can be matched for each message.
  If there are more than one matched, the *last* matched topic-fitler in the
  [prefix matching order](#prefix-matching-order) order is picked.
- Such rules are executed before any other rules in rule engine.
  That is: the output of a transformation rule is the input of message pub/sub and other data integration rules.

## Configuration Changes

Add a `tranforms` config entry to `rule_engine`

```
rule_engine {
  transforms {
    rule_tranform1 {
      type = tranform
      description = "increment payload.value"
      metadata {created_at = 1703075101227}
      sql = "SELECT payload.value + 1 as new.payload.value FROM 't/#'"
    }
  }
  rules {
    ...
  }
}

```

## Prefix matching order

A MQTT topic consists of words joint by '/',
When sorting MQTT whildcard topics, the following rules apply:

```
'#' < '+' < ANY_WORD
```

As an example, `t/1` is sorted *after* `t/#`.


