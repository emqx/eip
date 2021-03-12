# An Example of EMQ X Improvement Proposal

## Change log

* 2020-03-12: @terry-xiaoyu first draft

## Abstract

Introduce [JQ](https://stedolan.github.io/jq/) syntax to the SQL of emqx rule
engine.

## Motivation

The emqx rule engine now supports a subset of SQL syntax for creating rules. We
also provide a set of of SQL functions for manipulating the data structures.

A common use case is to transform JSON strings from MQTT messages.
The solution now is that first decode the JSON string to Erlang terms using
the sql function `json_decode/1`, assign it to a temporary variable, and then
do the transformations. As a handy way for decoding JSON Object and get the
value of a key, we could use the dot syntax like `payload.x`.

The problem is that the sql functions we provided are too limited to transform
complex JSON strings. For instance if we want to run a lambda for each of the
element of an array, we need the `map/2` or `reduce/3` function, and a sql
syntax for defining a lambda to do the transformation. JQ has done a great work
on this, in a concise syntax. Because JQ has been so widely used it has become
the de facto standard for processing JSON strings, it would be nice if we
introduced it to the emqx rule engine.

## Design

The SQL syntax of emqx rule engine now support a very limited set of operators
to retrieve and set the JSON values.

For example the following code snippet retrieves the value from an MQTT message
recursively:

```
        SELECT payload.a.b[1].c
 Input: {"a": {"b": [{"c": 1}]}}
Output: 1
```

And for updating an JSON object, we override the `AS` operator of SQL syntax.

The following example update a value with key `c` from `1` to `0`:

```
        SELECT 0 as payload.a.b[1].c
 Input: {"a": {"b": [{"c": 1}]}}
Output: {"a": {"b": [{"c": 0}]}}
```

This is straightforward but far from "enough" for processing JSON strings.
And also the syntax is not well designed, for example if we what to get the
value of key that contains the dot character, such as `a.b` from `{"a.b": c}`,
then we need to support `payload.'a.b'`.

## Configuration Changes

No configuration changes.

## Backwards Compatibility

This sections should shows how to make the feature is backwards compatible.
If it can not be compatible with the previous emqx versions, explain how do you
propose to deal with the incompatibilities.

## Document Changes

If there is any document change, give a brief description of it here.

## Testing Suggestions

The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Declined Alternatives

Here goes which alternatives were discussed but considered worse than the current.
It's to help people understand how we reached the current state and also to
prevent going through the discussion again when an old alternative is brought
up again in the future.

