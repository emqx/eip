# Support Consul for cluster discovery

```
Author: <John Roesler> <johnrroesler@gmail.com>
Status: Draft
Created: 2021-03-05
```

## Abstract

Cluster discovery should support Consul as an option to store and lookup node details.

## Motivation

Consul is another popular key value storage system (similar to etcd). This will add another valuable clustering option to emqx.

## Design

Each emqx node would write a key on a give path that would be provided in the configuration and make an API call
to Consul, e.g. `PUT /kv/emqx/<node-name>` - [Consul key create API](https://www.consul.io/api-docs/kv#create-update-key).

Each emqx node would then be able to query Consul for other keys on that path, e.g. `GET /kv/emqx/?keys` - 
[Consul get multiple keys docs](https://www.consul.io/api-docs/kv#keys-response)

With the node information - clustering would proceed in the standard emqx fashion. 

## Configuration Changes

`consul` would be added to the list of clustering options and config values would look like:

```
cluster.discovery = consul
cluster.consul.server = http://127.0.0.1:8500
cluster.consul.prefix = emqcl
```

may want to look at adding support for consul authentication as well - 
[auth docs](https://www.consul.io/api-docs#authentication)

```
cluster.consul.token = <token value>
```

## Backwards Compatibility

There should be no issue with backwards compatibility as this is a new feature that would
not impact the performance of any previous features.

## Document Changes

Documentation will need to be updated to include the new clustering option.

## Testing Suggestions

Could be tested the same as etcd.

## Declined Alternatives

None
