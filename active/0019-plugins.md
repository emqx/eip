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
1. More clear ordering of all hook callbacks under one certain hook point, for example, internal hooks use priority 1000, and force external plugins to provide a priority number. If they wish to have it ordered before internal plugins they can choose to use a number smaller than 1000.
1. All built-in features such as authentication and authorisation are not presented as plugins except for
    1. LDAP authentication
    1. PSK authentication

### Plugin types

There are two different kinds of plugsins, 'prebuilt' and 'external'.
Pre-built plugins are released as a part of the EMQ X (CE or EE) official release package.
External plugins are developed and release independently.

### External plugin security concerns

An external plugins is loaded and executed as any other EMQ X component without any
access restriction, or scope confinement.

EMQ X team's long term plan is to introduce a code review & build platform
(like an app market place) so EMQ X CE users and EE customers can have a trusted
source to download the packages.

Before the review & build process is in place,
EMQ X's users and customers are only adviced to take
extra care when loading a plugin developed by thirdy party.

### Basic steps to install an external plugin

- Download compiled zip package
- Upload to a specific dir
- Execute a command to validate & install & enable & uninstall the plugin

### Manage plugins from Dashboard UI

- Manage installation from Dashboard GUI
    - upload (and extract, but not persist it)
    - install
    - uninstall
- Manage a list of installed plugins, supported actions:
    - List view
    - Show running status: "running" or "stopped".
      Status should be presented per-node. e.g. `"status": "running"` for the current node (serving the API), or `"node_status": [{"node": "node1", "status": "running"}i, ...]` for a summary view of all nodes in the cluster.
    - support actions: "start" or "stop"

## Plugin package

A plugin package is a zip file made of two files inside:

* A tar file for the compiled beams (and maybe source code too),
* A metadata file in JSON format

### Plugin tar

The tar should be of layout

```
├── emqx_extplug1
│   ├── LICENSE
│   ├── Makefile
│   ├── README.md
│   ├── ebin
│   │   ├── emqx_extplug1.app
│   │   └── emqx_extplug1.beam
│   ├── etc
│   │   └── emqx_extplug1.conf
│   ├── priv
│   │   └── .. # maybe
│   ├── rebar.config
│   └── src
│       └── ... # maybe
├── extplug1_dep1
│   ├── LICENSE
...
```

### Plugin metadata

Inside the plugin zip-package, there should be a JSON file to help describe, identify and validate the package.

- Name (same as the Erlang application name, it has to be globally unique)
- Version
- Build-datetime
- sha256-checksum-for-tar
- Authors
    - Free text Name & Contact information such as email or website
- Builder
    - Name
    - Contact
    - Optional: Builder's website (to find e.g. public key)
    - Optional: Builder's signning signature for the package
- URL to source code
- What functionalities (one or more of below)
    - authentication
    - authorisation
    - data_persistence
    - rule_engine_extension
- Compatibility
    - Compatible with EMQ X version(s), implicit low boundary of supported versions range is `5.0.0`, also to support version compares: `~>`, `>=`, `>`, `<=`, `<`, `==`
      ref: https://github.com/erlang/rebar3/blob/c102379385013896711bba3969f280f851c67cc7/src/rebar_packages.erl#L376-L392
    - Supported OTP releases (has to be the same as EMQ X's supported OTP versions)

We will perhaps need a rebar3 plugin for to help generate the metadata file.

## User Interface

### Management **APIs**

- List plugins

```
/plugins
[{"metadata":
    { "name": "emqx_foobar",
      "description": "EMQ X plugin to implement foobar feature",
      "version": "0.1.0",
      ...
    },
  "status": "running" // disabled | running | stopped
  "node_status": [...]
},..]
```

The `disabled` state is recognised when the plugin is installed (unziped), but not configured to be loaded.

- Get one plugin

```
GET /plugins/{name}
{"metadata":
    { "name": "emqx_foobar",
      "description": "EMQ X plugin to implement foobar feature",
      "version": "0.1.0",
      ...
    }
 "status": "running"
 "node_status": [...]
}
```

- Upload a package

This API uploads and extracts a package

```
POST /plugins/upload
request: binary data
response: OK | error
```

- Enable / Start / Stop a plugin

```
PUT /plugins/{name}
{
    "status": running | stopped | disabled
}

PUT /nodes/{node}/plugins/{name}
{
    "status": running | stopped | disabled
}
```

- Delete a plugin

```
DELETE /plugins/{name}
DELETE /nodes/{node}/plugins/{name}
```
