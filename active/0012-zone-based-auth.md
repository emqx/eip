# Authentication based on Zone

## Changelog

## Abstract

It should be possible to define multiple zones with different authentication stacks.

## Motivation

We have two types of clients, one of them connects through an external network and needs to be authenticated by http,
but another group connects using an internal network and we need only jwt authentication for them.

## Design

## Configuration Changes

There should be zone specific list of authentications which has more priority than global rule and override them.

```
authz: {
    rules: [
       {
           type: redis
           config: {
              servers: "127.0.0.1:6379"
              database: 0
              pool_size: 1
              password: public
              auto_reconnect: true
              ssl: {enable: false}
           }
           cmd: "HGETALL mqtt_authz:%u"
       }
    ]
}

zone.x {
  authz: {
      rules: [
         {
             type: mysql
             config: {
                server: "127.0.0.1:3306"
                database: mqtt
                pool_size: 1
                username: root
                password: public
                auto_reconnect: true
                ssl: {
                  enable: true
                  cacertfile:  "etc/certs/cacert.pem"
                  certfile: "etc/certs/client-cert.pem"
                  keyfile: "etc/certs/client-key.pem"
                }
             }
             sql: "select ipaddress, username, clientid, action, permission, topic from mqtt_authz where ipaddr = '%a' or username = '%u' or clientid = '%c'"
         }
      ]
  }
}
```

## Backwards Compatibility

It can be backward compatible by providing authentication methods globally.

## Document Changes

It should be describe on documentation.

## Testing Suggestions

## Declined Alternatives
