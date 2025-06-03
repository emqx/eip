# Default security improvements

## Changelog

* 2025-06-30: @id Initial draft

## Abstract

This EIP proposes to improve the default security of EMQX.

## Motivation

The default security settings of EMQX can be improved to follow best practices and enhance the security of out-of-the-box installations.

## Design

1. Bind the Dashboard’s listener to 127.0.0.1 by default.

2. Bind MQTT and Websocket listeners to 127.0.0.1 by default.

3. Provision self-hosted certificates on startup.
   - Generate self-signed certificates for the Dashboard and MQTT/Websocket listeners.
   - Use these certificates to secure the connections by default.
   - Enable HTTPS on Dashboard listener by default.

4. Add built-in support for Let's Encrypt certificates and ACME protocol in general.

5. Change default ACL "no match" action to `deny` by default.

6. Change default password `public` to empty string in config schema

Do not allow login for admin user if its password is `""`,  and return below hint text to dashboard:

```
* Run command to change admin password: emqx ctl admins passwd admin a-very-string-pasword
* Configure dashboard.default_password="a-very-string-password"
```

## Configuration Changes

Default emqx.conf changes:

```
listeners {
  ssl {
    default {
      bind = "127.0.0.1:8883"
    }
  }
  tcp {
    default {
      bind = "127.0.0.1:1883"
    }
  }
  ws {
    default {
      bind = "127.0.0.1:8083"
    }
  }
  wss {
    default {
      bind = "127.0.0.1:8084"
    }
  }
}
dashboard {
  default_password = ""
  listeners {
    https {
      bind = "127.0.0.1:18083"
    }
  }
}
```

Default acl.conf changes:

```
%%-------------- Default ACL rules -------------------------------------------------------
{allow, {username, {re, "^dashboard$"}}, subscribe, ["$SYS/#"]}.
{allow, {ipaddr, "127.0.0.1"}, all, ["$SYS/#", "#"]}.
{deny, all, subscribe, ["$SYS/#", {eq, "#"}, {eq, "+/#"}]}.
{deny, all}.
```

## Backwards Compatibility

No backwards compatibility issues are expected with these changes. The new defaults will not affect existing configurations unless they are explicitly changed to match the new defaults.

## Document Changes

TODO

## Testing Suggestions

Test the new defaults in a fresh EMQX installation to ensure that:
- The Dashboard is accessible only from localhost.
- MQTT and Websocket connections are only allowed from localhost.
- Self-signed certificates are generated and used for secure connections.
- Let's Encrypt certificates can be provisioned and used.
- The ACL rules deny all unmatched actions by default.

