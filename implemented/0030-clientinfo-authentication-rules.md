# Authenticate MQTT clients with composible rules against client info

## Changelog

* 2024-06-27: @zmstone Initial draft
* 2024-09-20: @zmstone Update to reflect the latest design

## Abstract

Implement a new feature which can authenticate MQTT clients based on a set of composible rules against client properties and attributes.

## Motivation

EMQX has a set comprehensive authentication chain, most of which requires out-of-band requests towards an external service such as HTTP server, or a database. However, there are some scenarios where the authentication decision can be made based on the client properties and attributes, such as client ID, username, and TLS certificate.

For certain use cases, it is more efficient to authenticate clients based on the client properties and attributes.
Some examples:

- Quick deny clients which have no username.
- Only allow clients with certain client ID prefix to connect.
- Username prefix must match the OU (Organizational Unit) in the TLS certificate.
- Password is a hash of the client ID and a secret key defined in a environment variable.

Such rules can be added to the authentication chain (often to the head of it), to effectively fence off clients that do not meet the criteria. Or used standalone to authenticate clients if the checks are sufficient.

## Design

In addition to the current `Password Based`, `JWT` and `SCRAM`, we add a new authentication mechanism called `Client Info`.
The `Client Info` mechanism has no external dependencies, but should have a set of configurable checks.

The checks can be composed similar to the `ACL` rules, formatted externally it's a HOCON array of objects, each object is a check.
The checks are evaluated in order, and the first check that matches the client info will be used to authenticate the client.

Here is an example of the configuration:

```
checks = [
    # Allow clients with username starts with 'super-'
    {
        is_match = "regex_match(username, '^super-.+$')"
        result = allow
    },
    # deny clients with empty username and client ID starts with 'v1-'
    {
        # When is_match is an array, it yields 'true' if all individual checks yield 'true'
        is_match = ["str_eq(username, '')", "str_eq(nth(1,tokens(clientid,'-')), 'v1')"]
        result = deny
    }
    # If all checks are exhausted without an 'allow' or a 'deny' result
    # this authenticator results in `ignore` so to continue to the next authenticator in the chain
]
```

Each check object has two fields:

- `is_match`: One or more boolean expressions that evaluates to `true` or any other string value as `false`.
- `result`: either `allow`,`deny` or `ignore`.

### Logical Operators

There is no explicit logical `AND` or `OR` operator support for checks and match conditions, but the following rules apply:

- Since each `check` can yield a `result`, one may consider the `checks` arrary are connected by a logical `||` (`OR`) operator.
- When `is_match` is an array, it yields `true` if all individual checks yield `true`, one may consider the `is_match` array are connected by a logical `&&` (`AND`) operator.

### Functions

The `is_match` expressions are Variform expressions used in other parts of EMQX, they are evaluated in the context of the client info.

Find more information about the Variform expressions in the [Variform documentation](https://docs.emqx.com/en/emqx/v5.8/configuration/configuration.html#variform-expressions)

### Predefined Variables

- `username`: the username of the client.
- `clientid`: the client ID of the client.
- `peerhost`: the IP address of the client.
- `cert_subject`: the subject of the TLS certificate.
- `cert_common_name`: the issuer of the TLS certificate.
- `client_attrs.*`: the client attributes of the client. See more in the [Client Attributes documentation](https://docs.emqx.com/en/emqx/v5.8/client-attributes/client-attributes.html#mqtt-client-attributes)

## Configuration Changes

This section should list all the changes to the configuration files (if any).

## Backwards Compatibility

This is a new fature and should not affect any existing configurations.

## Document Changes

A new section should be added to the authentication documentation to describe the new `Client Info` authentication mechanism.

## Testing Suggestions

Test coverage should be added to cover the new `Client Info` authentication mechanism.

## Declined Alternatives
