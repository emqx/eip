# Unified Authentication in EMQ X 5.0

## Change log

*             @tigercl Initial draft
* 2021-10-04: @zmstone Moved the doc from internal share

## Abstract

This proposal introduces a new design for EMQ X 5.0 authentication,
which aims to provide: for EMQ X users, a better user experience with more configurable interfaces,
and for EMQ X developers, a better development framework without repeating themselves.

## Motivation

EMQ X authentication is implemented by the hook-callback for hook-point `client.authenticate`.
Up to v4.3, EMQ X supported 8 different authentication plugins, namely:

```
emqx_auth_http
emqx_auth_jwt
emqx_auth_ldap
emqx_auth_mnesia
emqx_auth_mongo
emqx_auth_mysql
emqx_auth_pgsql
emqx_auth_redis
```

Some of the pain points in the old implementation

1. The authentication plugins are implemented more or less the same,
   and works more or less the same too. There is a lack of abstraction for the common parts,
   causing developers to repeat themselves when adding new features or fixing issues.
1. There is a lack of a nice re-configure interface, the only way to configure a plugin
   is to update the config file, and reload (stop, start) the plugin.
1. If there are more than one auth plugin enabled, there is no deterministic order for
   how the different backends are checked.
1. Enabled authentication plugins are collectively considered one global instance,
   there is a lack of granularity for scoped control levels. e.g. per-zone, or per-listener.

To address the pain-points in 5.0, we propose below enhancements.

## Design

### One app for all

One `emqx_authn` app to unify the management of all different backends (except for ldap being postponed for now).

### The same hook-point

In this design, there is no intention to change how EMQ X hooks work,
the new app `emqx_authn` will continue to make use of the `client.authenticate` hook-point,
only to dispatch auth requests to the underlying backends inside one single hook call.

### Composable authn "chain"

We should allow users to compose (configure) a "chain" of backends with a defined order in which the
checks are performed one after another. Each check against the backend in the chain may yield 3 different
results for one-request authentication:

- `ignore` is to indicate there is no auth information found hence should
   continue validate the client against the rest of the backends in the chain.
- `{ok, Info}` as a login accepted, hence to terminate the auth calls from here,
   where `Info` may contain additional information such as to indicate if the user is a super-user.
- `{error, Reason}` to indicate that client's login should be denied.

NOTE: for temporary errors, such as database connection issue, the error is logged,
      and the auth result is `ignore` so to move forward to the next node in the chain.

NOTE: if there is no `ok` (accepted) result after a full chain exhaustion, the login is rejected.

For enhanced authentication, such as `scram` there can be messages after the first request,
hence the backend may return `{continue, Data}`,
where `Data` is to be kept by the connection process as handling context for the following messages.

### Fine-grained configuration levels

By default, EMQ X user can configure one global chain which applies to all MQTT listeners,
we should however also allow a per-listener configuration to override the global chain.
Together with firewall rules, this will allow users to have different auth solution for
MQTT service facing different group of clients coming from their designated network.

### Reconfigurable on the fly

The changes in the auth chain or the backends should be applied on-the-fly
i.e. without having to restart the `eqmx_authn` application.


## Configuration

- Example config for built-in-database (mnesia) username/password based global auth

```
authentication {
  backend: 'built-in-database',
  mechanism: "password-based",
  ...
  user_id_type: clientid
}
```

- Example 'chain' config

```
authentication = [
  {
    backend: 'built-in-database',
    mechanism: "password-based",
    ...
    user_id_type: clientid
  },
  {
    algorithm = "hmac-based"
    mechanism = "jwt"
    secret = "emqxsecret"
    "secret_base64_encoded" = false
    use_jwks = false
    verify_claims {}
  },
]
```

```

- Example config for built-in-database (mnesia) username/password based per-listener auth

```
listener.tcp.default {
  ...
  authentication: {
    backend: "built-in-database",
    type: "password-based",
    user_id_type: username
  }
  ...
}
```

## APIs


### Global auth chain APIs

- Get global auth chain

```
GET /authentication
GET /authentication/:id
```

Where `id` is of format `<Mechanism>:<Backend>`. e.g. `password-based:built-in-database`.

- Delete global auth chain

```
DELETE /authentication/:id
```

Update global auth chain

```
PUT /authentication/password-based:built-in-database
{
      ...
}
```

The `PUT` body should be constructed according to the config schemak

### Per-listener auth chain APIs

For per-listener authentication chains, the APIs are mostly the same,
as the ones for global instances, only the path is prefixed with `listener/listener_id`.

```
POST /listeners/:listener_id/authentication
GET /listeners/:listener_id/authentication
GET /listeners/:listener_id/authentication/:id
DELETE /listeners/:listener_id/authentication/:id
PUT /listeners/:listener_id/authentication/:id
PATCH /listeners/:listener_id/authentication/:id
```

A listener name is of format `protocol:id` which is assigend in the config file, e.g.

```
listeners.tcp.default {
    bind = ...
}
```

The name of this listener is `tcp:default`

### Re-positioning APIs

```
POST /:id/move
```

With a JSON body to indicate where the authenticator is to be re-positioned.
The positions can be `top` (front of the list), `bottom` (the rear of the list),
or `before` / `after` another ID.

for example:
```
curl -X 'POST' \
  'http://localhost:18083/api/v5/authentication/jwt/move' \
  -H 'accept: */*' \
  -H 'Content-Type: application/json' \
  -d '{
  "position": "before:password-based:built-in-database"
}'
```

### User management APIs

We should also support CRUD APIs for user management, with below endpoints.

```
/:id/users
/listeners/:listener_id/authentication/:id/users
```

The authenticator ID is made generic although 5.0,
only the built-in database (Mnesia) is supported.
That is, only `password-based:built-in-database` is valid for `:id` so far.

## Testing suggestions

There should three levels of tests.

* Unit tests for module level tests
* Regular common tests (maybe with mocks if necessary) to test full flows
* Integrated common tests verify the code against external auth providers running in docker container
