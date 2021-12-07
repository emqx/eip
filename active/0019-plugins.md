# EMQ X 5.0 plugins

## Change log

* 2021-11: Guowei Li
* 2021-12-07: @zmstone move it to GitHub

## Abstract

This EIP documents the implementation proposal EMQ X 5.0 plugins.

## Background

Prior to EMQ X 5.0, most of the features are implemented as plugins. A plugin is an Erlang application which registers a set of call back APIs at certain pre-defined hook points.

The applications are configured and loaded separately after the node is booted.

In 5.0, although most of the features such as authentication, authorisation, and rule-engine are still implemented by registering hooks, the management of the features are no longer as the old plugins. 

Prior to 4.3, most of the plugins are hosted in their own Git repos. This was changed in 4.3 as an umbrella project.

All these changes we have made in the past are to provide better user experience as well as development experiences. But the flexibility of plugin applications and how they can be hosted in separate git repos still have their advantages and we should continue supporting it.

The challenges ahead are

- We want to continue supporting old plugins, but how to minimise the effort to migrate to 5.0.
Although the hook points are still there, the config format is slightly different, and the schema is also different. (cuttlefish → HOCON)
- How to provide a better management interfaces for external plugins e.g. management API or even UI.
- Callbacks under the same hook point are ordered by their priority, however most of the plugins (internal plugins included) today are using the default value 0, meaning it's ordered by luck.

Worth mentioning, since 4.3.2, EMQ X for the first supported drop-in installation of external plugins. That is, plugins can be compiled and packaged separately (instead of being released as a part of EMQ X package), see [Develop and deploy EMQ X plugin for Enterprise 4.3](https://emqx.atlassian.net/wiki/spaces/EMQX/blog/2021/05/23/168591472)

## References

- RabbitMQ: [Plugin Development Basics — RabbitMQ](https://www.rabbitmq.com/plugin-development.html)
- Grafana: [Pie Chart](https://grafana.com/grafana/plugins/grafana-piechart-panel/)
- WordPress: [WordPress Plugins](https://wordpress.org/plugins/)
- RabbitMQ Plugin release packages: [Releases · rabbitmq/rabbitmq-management-exchange](https://github.com/rabbitmq/rabbitmq-management-exchange/releases)

### High level requirements

1. Hook points should be compatible with 4.x
2. More clear ordering of all hook callbacks under one certain hook point, for example, internal hooks use priority 1000, and force external plugins to provide a priority number. If they wish to have it ordered before internal plugins they can choose to use a number smaller than 1000.
3. All built-in features such as authentication and authorisation are not presented as plugins except for
    1. LDAP auth

### Basic steps to install an external plugin

- Download compiled zip package
- Upload to a specific dir
- Execute a command to validate & install & enable the plugin

### Manage plugins from Dashboard UI

- Manage installation from Dashboard GUI
    - upload
    - install
    - uninstall
- Manage a list of installed plugins, supported actions:
    - List view
    - Show running status: running | stopped
    - support actions: start | stop

## Plugin metadata

The plugin package should include metadata (in JSON format) to help identify, validate, or describe the package.

- Name (same as the Erlang application name, it has to be globally unique)
- Version
- License (checked against a white list: apache2, mit, ...)
- Author
    - Name
    - Contact
- URL to source code
- What functionalities (one or more of below)
    - authentication
    - authorisation
    - data_persistence
    - rule_engine_extension
- Compatibility
    - Compiled with EMQ X version (from 5.0)
    - Supported OTP releases (has to be the same as EMQ's supported OTP versions)

## User Interface

### Management **APIs**

- List plugins

```json
/plugins
[{"metadata":
    { "name": "emqx_foobar",
      "description": "EMQ X plugin to implement foobar feature",
      "version": "0.1.0",
      ...
    },
  "status": "running" // not_initialized | running | stopped
},..]
```

The `not_initialized` state is recognised when the plugin is installed (unziped), but not configured to be loaded.

- Upload a package

This API uploads and extracts a package

```json
POST /plugins/upload
request: binary data
response: OK | error
```

- Start or stop a plugin

```json
PUT /plugins/{name}
PUT /nodes/{node}/plugins/{name}
```

- Delete a plugin

```json
DELETE /plugins/{name}
DELETE /nodes/{node}/plugins/{name}
```
