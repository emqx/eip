# Unified Authorization in EMQ X 5.0

## Change log

* 2021-05: @Rory-Z
* 2021-10-29: @zmstone Sync the doc from draft in internal wiki
* 2022-08-10: @savonarola Update and move to implemented

## Abstract


In EMQ X 4.x, authorization (ACL) is provided by the `emqx_auth_xxx` applications as small Erlang applications,
while it was nice having the flexibility, the pain-points are:

- Scattered configuration management for EMQ X users
- Repeated (copy-paste) work for EMQ X developers
- Non-deterministic ordering of the hook callback registration leading to non-deterministic ordering of the ACL rules

This proposal introduces a new design for EMQ X 5.0 authorization (ACL), which aims to provide:

- For EMQ X users, a better user experience with more configurable interfaces
- For EMQ X developers, a better development framework without repeating themselves

## Terms

* ACL: Access Control List which defines a set of 'rules' for message publish and topic subscribe requests from MQTT clients;
* Authorization: another word for ACL;
* Source: an ACL rule data provider, such as 'file', 'http', 'mongo' and 'mysql' etc.
* Chain: an ordered list of Sources

## High level requirements

* Multiple sources for ACL rule persistence
  - File
  - MySQL
  - PostgreSQ
  - Redis
  - MongoDB
  - Mnesia (built-in-database)
  - WebServer (http)

* Fallback action if no rule matches a request (publish or subscribe)
  - deny
  - allow
  - disconnect

* Rule cache
  In 4.x series, the rules are cached in client's process dictionary.
  There is no intention to change such behaviour in 5.0

* Allow more than one source to form the chain
  - The chain should have a determined order. Unlike the situation in 4.x the ACL check order depends on the plugin start/restart order
  - Only one instance is allowed for each type of source, e.g. one should not be allowed to configure more than one `file` type source or `http` type source
  - Provide APIs to adjust the ordering of the chained sources

* ACL for gateways, CoAP, MQTT-SN, exproto, Stomp (but not LwM2M)

* Management API to upload rules for `file` type ACL source


## Design

Config proposal

```
authorization {
  no_match = allow | deny
  deny_action = disconnect | ignore

  cache {
    enable = true
    max_size = 32
    ttl = 30m
  }
  sources: [
    {
      type = file
      enable = true
      path = "etc/example.conf"
    },
    {
      type = mysql
      enable = true
      database = mqtt
      username = root
      password = xxx
      pool_size = 8
      query = "select * from table1 where clientid = xxx"
    }
  ]
}
```

### File

#### config
```
{
  type = file
  enable = true
  path = "/path/to/example.conf"
}
```

### File content example (same as in 4.x)

```
{allow, {username, "^dashboard?"}, subscribe, ["$SYS/#"]}.
{allow, {ipaddr, "127.0.0.1"}, pubsub, ["$SYS/#", "#"]}.
```

### MySQL
```
{
  type = mysql
  enable = true
  server = "127.0.0.1:3306"
  database = mqtt
  pool_size = 1
  username = root
  password = public
  auto_reconnect = true
  ssl = {
    enable = true
    cacertfile = xxx.ca
    certfile = xxx.cert
    keyfile = xxx.key
  }
  query: "select ipaddress, username, clientid, action, permission, topic from mqtt_authz where ipaddr = '${peerhost}' or   username = '${username}' or clientid = '${clientid}'"
}
```

### PostgresSQL
```
{
  type = postgresql
  enable = true
  server = "127.0.0.1:5432"
  database = mqtt
  pool_size = 1
  username = root
  password = public
  auto_reconnect = true
  ssl = {
    enable = true
    cacertfile = xxx.ca
    certfile = xxx.cert
    keyfile = xxx.key
  }
  query: "select ipaddress, username, clientid, action, permission, topic from mqtt_authz where ipaddr = '${peerhost}' or username = '${username}' or clientid = '${clientid}'"

}
```

### Redis
```
{
  type = redis
  enable = true
  redis_type = single
  server = "127.0.0.1:6379"
  database = 0
  pool_size = 1
  password = public
  auto_reconnect = true
  ssl = {enable = false}
  cmd = "HGETALL mqtt_authz:${username}"
}
```

### MongoDB
```
{
  type = mongodb
  enable = true
  mongo_type = single
  server = "127.0.0.1:27017"
  pool_size = 1
  database = mqtt
  ssl = {enable = false}
  collection = mqtt_authz
  selector: { "$or": [ { "username": "${username}" }, { "clientid": "${clientid}" } ] }
}
```

### Management APIs

#### Get root level settings

```
GET /authorization/settings
RESP:
{
  "no_match": "allow" | "deny",
  "deny_action": "disconnect" | "ignore",
  "cache" {
    "enable": true,
    "max_size": 32,
    "ttl": "30m"
  }
}
```

#### Update root level settings
```
PUT /authorization/settings
BODY:
{
  "no_match": "allow" | "deny",
  "deny_action": "disconnect" | "ignore",
  "cache": {
    "enable": true,
    "max_size": 32,
    "ttl": "30m"
  }
}
```

#### Create ACL data sources
```
POST /authorization/sources
BODY:
{ "type": xxx, ... }
```

#### Get ACL data sources
```
GET /authorization/sources
RESP:
[{ "type": xxx }, { "type": xxx }]
```

#### Get detailed source config per type

```
GET /authorization/sources/{type} # mysql,redis,mongodb,postgresql,http....
RESP:
{"type": "mysql", ...}
```

#### Update (reload) source config per type

When needed, the underlying resource such as MySQL connection pool should be restarted when handing such update requests.

```
PUT /authorization/sources/{type} # mysql,redis,mongodb,postgresql,http....
BODY:
{"type": "mysql", ...}
```

#### Delete a source cofnig per type

```
DELETE /authorization/sources/{type} # mysql,redis,mongodb,postgresql,http....
```

#### Adjust source's position in the chain

```
POST /authorization/sources/{type}/move # mysql,redis,mongodb,postgresql,http....
{ "position": "top" | "bottom" | "after:{type}" | "before:{type}" }
```

#### APIs to manage `file` type source

```
GET /authorization/sources/file
RESP:
{ "type": "file", "rules": "...", "path": "..." }
```

```
PUT /authorization/sources/file
BODY:
{ "type": "file", "rules": "...", "path": "..." }
```
