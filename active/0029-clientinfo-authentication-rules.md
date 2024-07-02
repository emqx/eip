# Authenticate MQTT clients with composible rules against client info

## Changelog

* 2024-06-27: @zmstone Initial draft

## Abstract

Implement a new feature which can authenticate MQTT clients based on a set of composible rules against client properties and attributes.

## Motivation

EMQX has a set complehensive authentication chain, most of which requires out-of-band requests towards an external service such as HTTP server, or a database. However, there are some scenarios where the authentication decision can be made based on the client properties and attributes, such as client id, username, and TLS certificate.

For certain use cases, it is more efficient to authenticate clients based on the client properties and attributes. 
Some examples:

- Only allow clients with certain client ID prefix to connect.
- Username prefix much match the OU (Organizational Unit) in the TLS certificate.

Such rules can be added to the authentication chain (often to the head of it), to effectively fence off clients that do not meet the criteria. Or used standalone to authenticate clients if the rules are sufficient.

## Design

In addition to the current `Password Based`, `JWT` and `SCRAM`, we add a new authentication mechanism called `Client Info`.
The `Client Info` mechanism has no external dependencies, but should have a set of rules configurable.

The rules can be composed similar to the `ACL` rules, formatted externally it's a JSON array of objects, each object is a rule. The rules are evaluated in order, and the first rule that matches the client info will be used to authenticate the client.

Each rule should result in `allow`, `deny`, `break` or `continue`.

- `allow`: the client is authenticated.
- `deny`: the client is not authenticated.
- `continue`: the rule is matched, and the client is not authenticated, continue to the next rule.
- `break`: the rule is matched, and the client is not authenticated, no further rules are evaluated. This means the client should continue to other authentication mechanisms if configured.

NOTE: The last rule returning `continue` or `break` will have the same effect as the `ignore` result in other authentication mechanisms (continue to the next mechanism).

Each rule is a 'variform' expression which supports basic compare operations, regular expressions and conditions.

Here are some examples of the rules:
```
[
    {
        "description": "Client ID starting with 'v1-' is legacy clients, which cannot be authenticated using client info, break the loop",
        "expression": "iif(regex_match(clientid, '^v1-.*$'), 'break', 'continue')"
    },
    {
        "description": "Client ID starting with 'v2-' must have the usernmae matching certificate common name",
        "expression": "iif(regex_match(clientid, '^v2-.+$'), iif(str_eq(username, cert_common_name), 'allow', 'deny'), 'continue')"
    },
    {
        "description": "Client ID starting with 'v3-' must have the suffix matching certificate common name",
        "expression": "iif(str_eq(regex_extract(clientid, '^v3-(.+)$'), cert_common_name), 'allow', 'continue')"
    },
    {
        "description": "It's a good idea to put a catch-all rule at the end",
        "expression": "deny"
    }
]
```

## Configuration Changes

This section should list all the changes to the configuration files (if any).

## Backwards Compatibility

This is a new fature and should not affect any existing configurations.

## Document Changes

A new section should be added to the authentication documentation to describe the new `Client Info` authentication mechanism.

## Testing Suggestions

Test coverage should be added to cover the new `Client Info` authentication mechanism.

## Declined Alternatives
