# Buit-in Message Transformation

## Changelog

* 2024-08-13: @zmstone Update to reflect the actual implementation.
* 2023-10-31: @zmstone Initial draft for message validation, filter and transformation (as a part of EIP-0024).
* 2022-12-19: @zmstone Limit the scope message filter and tranformation.

## Abstract

An extension of EMQX Enterprise to support action-less message filter and transformation.

## Motivation


Currently, if one wants to tranform a message before the message is published, the only option is to
make use of the Rule Engine's republish action.

This requires the clients to publish to one topic, and subscribe to another.

## Design

Each transfromation consists of

- A set of topic match patterns
- A list of operations for data mutation
- Payload decode/encode rules
- Error handling strategy

The transformation is done in below steps for each message.

- Match topic (filter). Only those messages of topic matching the configured topic (filter) are processed.
- Payload decode. When the transformation is about message payload, the payload has to be decoded first. e.g. from JSON, or avro.
- Mutation. Evaluate the expression to mutate the input data.
- Payload encode. When the transformation is about message payload, the payload has to be encoded back to the desired format of the subscribers.

We pre-define a set of keys (message attributes) which can be the subjects of data mutation.

- Topic
- Payload
- QoS
- Retain flag
- User properties

Each tranformation is a [varifom expression](https://docs.emqx.com/en/emqx/latest/configuration/configuration.html#variform-expressions)
which can be used to perform string operations.

## Configuration Changes

Add a `message_tranformation` config root.

```
message_transformation {
  transformations = [
    {
      name = trans1
      description = ""
      failure_action = ignore
      log_failure {level = warning}
      operations = [
        {
          key = topic
          ## prepend client ID to the publishing topic
          value = "concat([clientid,'/',topic])"
        }
      ]
      payload_decoder {type = none}
      payload_encoder {type = none}
      topics = [
        "#"
      ]
    }
  ]
}
```

### Expression Examples

- Add client ID as the prefix of publishing topics.

```
{
    key = topic
    value = "concat([clientid,'/',topic])"
}
```

- Add client TLS certificate's OU as a MQTT message user property

```
{
    key = "user_property.ou"
    # if client_attrs.cert_dn is initialized, extract the OU
    # otherwise user_property.ou is set as 'none'
    value = "coalesce(regex_extract(client_attrs.cert_dn,'OU=([a-zA-Z0-9_-]+)'), 'none')"
}
```

### Declined Alternatives

- Employee rule SQL expressions
- Message multiplication (transform one message to many)
