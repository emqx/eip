# New Config Files for EMQ X v5.0

## Change log

* 2020-10-19: @terry-xiaoyu first draft created
* 2021-04-13: @terry-xiaoyu refine the design for configuration file syntax and hot-loading


## Abstract

The configuration files of EMQ X is to be changed significantly in EMQ X 5.0, both in its syntax and
its architecture.

This proposal explains the rationale behind its design and describing the changes in detail.

## Motivation

The config files and the config entries need to have the following properties:

- The config files should be more readable and editable to users.

- The configs should be able to updated at runtime.

- The config files should be able to upgraded in a backward compatible manner during release hot
  upgrade.

## Design

### New Config Syntax

A new config syntax/language will be introduced into EMQ X, it uses the `HOCON` format.

Despite the config syntax, the internal config syntax used by emqx should be erlang terms:
It can be an erlang map or a key-word list.

### Structure of Config Files

The emqx.conf before version 5.0 is self-explained as the comments are very detailed, but is too
verbose for editing.

The solution here is to give user a clean (and short) `emqx.conf` with only necessary configs in it,
without any comments.

And provide an `emqx_config_sample.conf` file together with the emqx installation package, which is
verbose and fully documented. The `emqx_config_sample.conf` can be used as a documentation. The user
can also do a little change to the file and then replace the `emqx.conf` with it.

We generate the `emqx_config_sample.conf` from the schema files automatically when building a emqx
package.

> **To include a `emqx_base.conf` file or not:**
>
> Another way is to include a base file from the `emqx.conf`, this has the benefit of declaring the
> "from" file explicitly. So the user can easily know where the "missing" configs in the `emqx.conf`
> can be found, and what the default values are.
> But this way we have to keep a `emqx_base.conf` file in the etc/ dir.

If a config is not found in `emqx.conf`, then the default value of the config will be used.
If the config is mandatory then it prints an error messages and the emqx will not get started.

There should not be too many config files, otherwise the user may have a problem locating the
correct place to change a config entry. Also the config file names should be clear so that the user
can speculate what the file is for.

We suggested 2 config files (`emqx.conf` and `emqx_overrides.conf`) here:

```
etc/
├── emqx.conf
├── emqx_overrides.conf
```

The `emqx_overrides.conf` is used to store changes from API, and configs in it overrides the configs
with the same name in `emqx.conf`.

### Configuration file loading

All configs are read from the config files and translated to `sys.config` (the erlang system config
file) by applying the config schema.

```
                                  [Application Controller]
          (schema)                     +----------+
  HOCON ----------> [sys.config]---->  | AppConf  |
                                       |    [emqx]|
[*.conf]                               +-------|--+
                                               |
                                        +------v--+
                                        | ConfMap |
                                        +---------+
                                      [Persistent Term]
```

The config entries are then loaded to the Erlang's application controller, which is stored in a ETS
table. Hereafter this text we call it `AppConf`.

After the node is stared, emqx application will read all the configs from `AppConf` under the key
`emqx`, converting it to a map and then load it to a config registry in the local node. I'd like to
call this config registry as `ConfMap`. The `ConfMap` is basically a erlang map stored in persistent
term. We choose the erlang map as the data structure mainly for constant time reading operations.

The schema files is the same as the cuttlefish schema files we used in emqx before 5.0. We keep
using schema files because it separates the work of translation and validation out of emqx
application. It is good for the extensibility of our system. And also some of the application
depended by emqx such as the OTP logger requires configurations in `sys.config` format, so we
need to convert the HOCON formats to sys.config formats for these applications.

The schema file is not mandatory if no translation/validation is needed. If possible, the format of
config values should be designed in a manner that do not need to be translated by the schema files.

That is, we prefer:

```
force_shutdown_policy {
  max_message_queue_len: 10000
  max_heap_size: 64MB
}
```

to

```
force_shutdown_policy: 10000|64MB
```

The prior is not only more readable to users without reading the comments/documents, but also more
intuitive to programmers for searching the config entry through the code files, as the ConfMap
maintained in the memory is of the same structure (and name) as the config file.

### The Structure of the Config Files

At the beginning of the `emqx.conf` is the notes:

```
## NOTE: The configurations in this file will be overridden by `/etc/emqx_overrides.conf`
## NOTE: See the /etc/docs/emqx_config_sample.conf for all the available configurations and
##       examples.
```

The first thing to be configured is the node name:

```
node {
  name: "emqx@127.0.0.1"
}
```

After that is the listeners:

```
listeners {
  tcp "0.0.0.0:1883": {
    max_connections: 1024000
  }

  ssl "0.0.0.0:8883" {
    max_connections: 512000
  }

  ws "0.0.0.0:8083" {
    mqtt_path: /mqtt
    max_connections: 1024000
  }

  wss "0.0.0.0:8084" {
    mqtt_path: /mqtt
    max_connections: 512000
  }
}
```

Next comes the remaining part of the config file:

```
broker {
  sys_msg_interval: 1m
  sys_heartbeat_interval: 30s
  shared_subscription_strategy: random
}

log {
  primary_level: warning
  handlers: [{
    type: file
    level: warning
    filename: "{{ platform_log_dir }}/emqx.log"
  }]
}

cluster {
  name: emqxcl
  discovery_strategy: manual
}

rpc {
  mode: async
  tcp_client_num: num_cpu_cores
}
```

That's all. The `emqx.conf` is very concise. I put the complete config files
[here](https://github.com/terry-xiaoyu/emqx/tree/emqx50_shawn/configs).

### Config Update at Runtime

The config files can be modified and reloaded after the emqx broker has been started.
But not all of the config entries are able to updated at runtime.
We should provide some CLIs/APIs to help users for debugging/verifying the changes of the config
files, and showing user the changes applied to the runtime after reloading the config files.

Configs should also be update from the Dashboard/APIs, but we won't solve the conflicts between the
changes from the config file and the APIs, as that would introduce much more complexities than benefits.

Configuration changes made by the API with a `permanent` option should be written back to the `etc/`
dir. After the ConfMap validates and applies the configs got from API, it dumps all the changed
configs to `emqx_overrides.conf`, in HOCON format.

If the configs are updated both from the API and config files at the meanwhile, we deny the update
request from API and prompt the user to reload changes from files first, and then let the user make
their changes again from API.

### Changes to the CLIs:

- `emqx_ctl config help <key>`

  Print the help page for the key. The nested keys can be described as a path separated by `.`.
  For example `a.b` for `{a: {b: Val}}`.

  If the key path contains an array, then we can use the `[]`, e.g. `a.b[].c` for
  `{a:{b:[{c:Val}]}}`.

  Example:

  ```shell
  $ emqx_ctl config help log.handlers[].file

  The log filename.
  Type: string
  Default: "{{ platform_log_dir }}/emqx.log"

  If `rotation` is disabled, this is the filename of the log files.

  If `rotation` is enabled, this is the base name of the files. Each file in a rotated log is named
  <base_name>.N, where N is an integer.
  ```

- `emqx_ctl config reload`

  Reload the config file, returns the list of config entries applied to `ConfMap`.

  Config entries that is changed in the config files but requires restarting the broker should be
  shown as warnings:
  `warning: config 'a=1' has been changed in emqx.conf but will only take effect after the emqx is restarted`.

  Or if a change need the restart of a component:
  `warning: config 'b=1' has been changed in emqx.conf but will only take effect after the listener 'tcp.1883' is restarted`.

  Note that changes for configs for listener and logger do require restarting the broker, but they
  can have there API/CLI to change some configs at runtime.
  e.g. CLI `emqx_ctl log set-level debug` changes the current log level to debug, but the logger
  will read configs from the config files after restarting the broker.

- `emqx_ctl config status`

  Shows the list of config entries that are changed but has not been loaded to the broker.
  This shows both the configs that can be hot updated, and the ones need system restart:

  e.g. The status can look like follows after we've made some changes to the config files:

  ```
  log.level: debug                                 [changed] [need restart]
  mqtt.default.max_packet_size: 2MB                [changed]
  mqtt.default.max_clientid_len: 65535             [changed]
  ```

  After `emqx_ctl config reload` the status would be:

  ```
  log.level: debug                                 [changed] [need restart]
  ```

  Or if there's no changes in the config file, return a message that the workspace is clear:
  `no config file has been changed since last configuration reload`

- emqx_ctl config show

  Dumps the current configs used in the broker, both in `AppConf` and `ConfMap`:

  ```
  node.name: emqx@127.0.0.1
  node.cookie: emqxsecretcookie
  mqtt.default.max_packet_size: 1MB
  ...
  ```

### Changes to the APIs:

The detailed design for APIs is not include here. The APIs should provide the same functionalities
as the CLI provides.

#### Specify Config Files at EMQ X Start

We should add some argument to `emqx start` for specifying the config files to be used, as well as
one or more config entires.
This feature is useful to users who want to start emqx from k8s and docker:

e.g.

```shell
emqx start --node-name="emqx1@192.168.0.12" \
  --config-file="/var/docker/volumes/emqx.conf.1" \
  --additional-config-file="/var/docker/volumes/node.conf.1,/var/docker/volumes/node.conf.2"
```

We prefer command arguments rather than environment variables, as:

- the use of environment variables may different on unix and windows;

- environment variables can be stripped by commands like `su - emqx`.

### Configs for Plugins

All the plugins after 5.0 need no config files. The plugins are configured, started or stopped from
dashboard.
This is similar to the approach of emqx rule engine, which can only be configured from CLI and APIs.

#### A new Plugin Framework

A framework for new plugins should be designed, with following properties:

- provide a config spec framework based on `JSON` spec files.

  - The spec file should be separated out of erlang source file.

  - It uses a localization file for translating between different languages. [in future]

- provide a database framework for loading and managing configs.

  The database should be in a text format such as JSON, which is ease to be changed by tools outside
  of emqx.

  A interesting aspect of this approach is that, if we have a tool migrating configs from older
  versions to newer versions, the migration tool could translate the emqx.conf and the plugin's
  config db files to new versions using the same logic.

  The migration tool can simply be a python script that independent from emqx, so that it's easy to
  debug and fix if there's any issue in the tool. If otherwise we provide the migration tool in
  emqx CLI, we have to either re-tag the current version and recall the installation packages from
  website, or wait for the next version to get the issue fixed.

  Another benefit of this approach is that, we are able to create the config db file manually for
  a plugin without a running emqx broker. We could then put it to the `data/` dir and start the
  emqx, the plugin will get started together with emqx.

- provide a plugin management framework that start/stop/restart the plugins.

### Upgrade Config Files during Release Hot Upgrade

The config file should be backward compatible to support release hot upgrade. That is:

- a new (optional) config entry is allowed to be added in new version, but MUST have a
  default value.

- delete/rename an old config entry is not allowed in new version.

When upgrading to a new emqx version, the upgrade handler read the old config files, then merge
them to the new config files.

After that the upgrade handler will load new config files.

## Configuration Changes

See the section "The Structure of the Config Files".

## Backwards Compatibility

Not backward compatible as this is a 5.0 feature.

## Document Changes

The `configuration` section of the document need to be re-written.

## Testing Suggestions

Integrate testing for changing configs at runtime is need, both from the CLI and the API.

## Declined Alternatives

The `Centralized Config Service` way is not necessary as we can manage the configurations
from the Dashboard. And to deploy and maintain a separated configuration node is too complex.

Keeping all the code and components in the same project makes life easer.
With tools like config maps in Kubernetes we can easily update the config files and reload them
to all the running emqx nodes.

The original design for `Centralized Config Service` is here:

### Deploy With Centralized Config Service

If a centralized config service is deployed with emqx brokers, no config file is needed. All config entries are saved and managed at the config service, and the emqx broker nodes would pull the configs from the config service at boot up. The config service can also push configs to the emqx broker nodes at runtime.

The important thing here is that, there's no config files exist on the emqx broker nodes. This ensures there's only one source of changes: from the config service to emqx brokers.

The benefit of using the config service is that we could change one or more config entries to all the nodes in a single push, and the configs for the plugins like `emqx-rule-engine` or `emqx-auth-http` can be pre-configured in the config service before the broker nodes get started.

The architecture in this case looks like following:

```
Config Service

                                                 [Application Controller]
                          (schema)                    +----------+
ConfigGUI ---> KeyWordList -------> [sys.config]----> | AppConf  |
                                                      +-------|--+
                                                              |
..............................................................|.............................
                                                              |
                                 [EMQX NODE1] <---------------+
                                                              |
                                 [EMQX NODE2] <---------------+

EMQX Brokers
```
