# Built-in Message Validation

## Changelog

* 2023-10-31: @zmstone Initial draft message validation, filter and transformation.
* 2022-12-19: @zmstone Limit the scope to filter and validation.

## Abstract

A new feature for EMQX v5 to validate messages.

## Motivation

### Message Validation

Technically, by using EMQX rules engine, it is possible to validate the incoming
MQTT messages before sending the message off to data bridges.

For instance, one can write a rules engine SQL like below to
drop messages which are not avro encoded and also when the 'val' field is not greater than 10.

```
SELECT schema_decode(my_avro_schema, payload) as decoded from t/# where decoded.val > 10
```

However, currently rules are only used in data bridges, but they do not interfere MQTT message pub/sub.
For example, if there is client subscribed to `t/#` it would still receive the avro encoded message.

If we also want to stop the message being published, then there would be a need for a message republish action,
and the publisher and subscriber will likely be forced to use different topics.
e.g. publisher publishes to `t1/...`, republish action send it to `t2/...` for subscribers to receive.

This can work, but not easy to use.

### Message filter

Message filtering can be achieved by confugring message validation rule to drop invalid messages.

## Design

This data validation step should happen after authorization and before rules engine.
Probably can make use of the 'message.publish' with a hook priority which
positions the callback after authorization, but before data bridges.

### High level design

* Make use of the rules engine SQL, but without the `FROM` clause as it's always the MQTT message being th input.

Each data validation rule should have a unique ID. And each rule should have a input topic-filter name which
can be used to build a topic index for quick look-up.

The common parts can be described as hocon config below:

### Message Validation

```
validations = [
  {
    name = validation1
    tags = []
    description = ""
    enable = true # or 'false'
    type = validation
    description = "drop message if it is not compabitble with my avro schema or if payload.value is less tha 0"
    topics = "t/#" # or topics = ["t/1", "t/2"]
    strategy = any_pass # or all_pass
    failure_action = disconnect # (disconnect also implies 'dorp') or 'drop' to only drop the message
    log_failure_at = none # debug, notice, info, warning, error
    checks = [
        {
            # message payload payload to be validated against JSON schema
            type = json # can also be 'avro' or 'protobuf'
            schema = "my-json-schema-registration-id"
        }
        {
            # SQL evaluates to empty result indicates validation falure
            # in this example, if payload.value is less than 0, the message is considiered invalid
            type = sql
            sql = "SELECT * WHERE payload.value < 0"
        }
    ]
  }
]
```

If there are more than one validation matched for one message, all validations should be executed
in the configured order.
For example, if one is configured with `topics = "t/#"` and another with `topics = "t/1"`,
when a message is published to `t/1`, the both validations should be triggered.

## Configuration Changes

A new config root named `message_validation` is to be added.

```
message_validation {
    validations = [
        ...
    ]
}
```

## APIs

- GET /message_validations
  To list all the message validations

- GET /message_validations?topic=t/#&schema_name=jsonsch1&schema_type=json
  Fetch validations based on filter

- PUT /message_validations
  To update a validation

- POST /message_validations
  To create a new validation

## Observerbility

- There should be metrics created for each processor name.
- Opentelemetry tracing context in message properties should be preserved.
- Client disconnect and message drop events should be traceable in the EMQX builtin tracing.
- Emit a new event e.g. `message.validation_failure`.
  This allows users to handle the validation failures in Rule-Engine.
  For instance, publish the message to a different topic.

## Backwards Compatibility

New feature.

## Document Changes

- Docs should be created to guide users to use the new feature.
- New APIs in swagger spec
- New config schema for configuration manual doc

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
