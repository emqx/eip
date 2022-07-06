# EMQX Auto Subscribe

## Changelog

* 2022-07-06: @DDD

## Abstract

With Auto Subscription enabled, after a client is successfully connected to EMQX, it may not need to send SUBSCRIBE requests to EMQX, because EMQX will complete the pre-defined subscriptions for the client.

Prior to version 5, this feature is also known as "proxy subscription".

## Motivation

1. Missing subscription option (rh rap nl) for MQTT v5 version in table structure.
2. Lack of support for HTTP services.
3. Relies on the rules engine, which essentially acts as a hook.
4. Does not support placeholders, does not support variables, that is, the database is stored topics only.
5. The table structure is fixed and immutable. Only `clientid` is supported as primary key.

## Require

1. Support MQTT v5 sub options.
2. Get subscription from HTTP service.
3. Detach from the rule engine and provide service capability separately.
4. Add support for placeholders, i.e. subscription rules can be stored in the database.
5. Support using username as query condition, analogous to authz authn (need to discuss).

## Design

1. Open source version of the subscription rules as a benchmark, the enterprise version of more than one way to get all the subscription rules. That is, the information obtained can be mapped one by one to the open source proxy subscription rules.
2. Auto-subscription rules and device behavior consistent. There is no different between auto-subscription behavior and the device's own subscribe behavior. Business such as Retain, ACL, comply with the constraints of themselves.
3. Only one way to get the subscription is supported, that is, including the open source version of the subscription rules, there can only be one way to get the subscription. Configure more than one, only the first one in the configuration file takes effect, and the rest are not available in the log. That is, there is no chain, the only one resource.
4. Compatible with the 4.x version of the data structure. The user only need to migrate the business from the rules engine to the auto-subscribe, without changing the original database structure. 4.x, the data missing MQTT v5 subscription options information, using the default value in the open source auto-subscribe rules.
5. Database storage of topics support placeholders. Which means they are auto-subscribe rules. Device business is generally abstracted, may be classified according to the device. And topics may need to carry device information. For example: `service/1/${clientid}` `service/2/${username}` 
6. Support using device information query, username & clientid (need to discuss).
7. Use HTTP service to get the subscription, push the device information, the response value is the json structure data which conforms to the auto-subscribe rules.

### Configuration files

#### emqx.conf

EMQX auto-subscribe conf:

```bash
auto_subscribe {
  topics  =  []
 }
```

EMQX Enterprise conf:

```bash
## SQL is fake code.
auto_subscribe {
  type = mysql
  host = 192.168.1.1
  sql = "SELECT topic, qos, rap, rh, nl FROM some_table WHERE clientid = ${clientid} or username = ${username}"
 }
```

### HTTP API design

TODO

## Configuration Changes

This section should list all the changes to the configuration files (if any).

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
