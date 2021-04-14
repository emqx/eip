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

The `emqx.conf` file includes another (large) `emqx_base.conf` file that contains all the available
configs.

> **To include the `emqx_base.conf` file or just use it as an example config file:**
>
> Another way is to use the `emqx_base.conf` as an sample or example config file, which can be used
> as a documentation. The user can also do a little change to the file and then replace the
> `emqx.conf` with it.
> Including the base file from the `emqx.conf` has the benefit of declaring the "from" file explicitly.
> So the user can easily know where the "missing" configs in the `emqx.conf` can be found, and what
> the default values are.

The if a config is not found in `emqx.conf`, then emqx will find it from the `emqx_base.conf` file.
If the config is also not found in `emqx_base.conf`, then the default value of the config will be
used. If the config is mandatory then it prints an error messages and the emqx will not be started.

There should not be too many config files, otherwise the user may have a problem locating the
correct place to change a config entry. Also the config file names should be clear so that the user
can speculate what the file is for.

I suggested 2 config files (`emqx.conf` and `emqx_base.conf`) here:

```
etc/
├── emqx_base.conf
├── emqx.conf
```

### Configuration file loading

All configs are read from the config files and translated to `sys.config` (the erlang system config file) by applying the config schema.

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

The config entries are then loaded to the Erlang's application controller, which is stored in a ETS table. Hereafter this text we call it `AppConf`.

After the node is stared, emqx application will read all the configs from `AppConf` under the key `emqx`, converting it to a map and then load it to a config registry in the local node. I'd like to call this config registry as `ConfMap`. The `ConfMap` is based on Erlang's persistent term, and we choose the map as the data structure mainly for constant time reading operations.

The schema files is the same as the cuttlefish schema files we used in emqx before 5.0. We keep using schema files because it separates the work of translation and validation out of emqx application. It is good for the extensibility of our system. And also some of the application depended by emqx such as the OTP logger requires configurations in `sys.config` format, so we need to convert the HOCON formats to sys.config formats for these applications.

The schema file is not mandatory if no translation/validation is needed. If possible, the format of config values should be designed in a manner that do not need to be translated by the schema files:

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

The prior is not only more readable to users without reading the comments/documents, but also more intuitive to programmers for searching the config entry through the code files, as the ConfMap maintained in the memory is of the same structure (and name) as the config file.

### The Structure of the Config Files

#### The Listeners


For the HOCON based configuration structure of emqx, see
[configs](https://github.com/terry-xiaoyu/emqx/tree/emqx50_shawn/configs).

### Config Update at Runtime

The config files can be modified and reloaded after the emqx broker has been started. But not all of the config entries are able to updated at runtime. We should provide some CLIs/APIs to help users for debugging/verifying the changes of the config files, and showing user the changes applied to the runtime after reloading the config files.

Configs should also be update from the Dashboard/APIs, but we won't solve the conflicts between the changes from the config file and the APIs, as that would introduce much more complexities than benefits.

Configuration changes made by the API with a `permanent` option should be written back to the `etc/` dir. After the ConfMap validates and applies the configs got from API, it dumps all the changed configs to `emqx.conf`, in HOCON format. Before overwriting the `emqx.conf` we should backup it to `emqx.config.old` and notify the user about that.

If the configs are changed both from the API and in config files at the meanwhile. We need to deny the update request from API and prompt the user to reload changes from files first, and then let the user make their changes again from API.

We don't write an additional config files for the changes from API, because if the user changes a config entry in the `emqx.conf` later, it would be overridden by the new file we added, which will confuse the user. We can print some warning messages about this and the user may eventually find the root cause himself, but that can not be a good experience.

### Changes to the CLIs:

- `emqx_ctl config reload`

  Reload the config file, returns the list of config entries applied to `ConfMap`.

  Config entries that is changed in the config files but requires restarting the broker should be shown as warnings:
  `warning: config 'a=1' has been changed in emqx.conf but will only take effect after the emqx is restarted`.

  Or if a change need the restart of a component:
  `warning: config 'b=1' has been changed in emqx.conf but will only take effect after the listener 'tcp.1883' is restarted`.

  Note that changes for configs for listener and logger do require restarting the broker, but they can have there API/CLI to change some configs at runtime.
  e.g. CLI `emqx_ctl log set-level debug` changes the current log level to debug, but the logger will read configs from the config files after restarting the broker.

- `emqx_ctl config status`

  Shows the list of config entries that are changed but has not been loaded to the broker.
  This shows both the configs that can be hot updated, and the ones need system restart:

  e.g. The status can look like follows after we've made some changes to the config files:

  ```
  log.level: debug                                 [need restart]
  mqtt.default.max_packet_size: 2MB                [waiting reload]
  mqtt.default.max_clientid_len: 65535             [waiting reload]
  ```

  After `emqx_ctl config reload` the status would be:

  ```
  log.level: debug                                 [need restart]
  ```

  Or if there's no changes in the config file, return a message that the workspace is clear:
  `no config file has been changed since last configuration reload`

- emqx_ctl config show

  Shows the current configs used in the broker, both in `AppConf` and `ConfMap`:

  ```
  node.name: emqx@127.0.0.1
  node.cookie: emqxsecretcookie
  mqtt.default.max_packet_size: 1MB                [reloadable]
  ...
  ```

  The configs that are able to updated at runtime should be marked as `[reloadable]`.

#### Specify Config Files at EMQ X Start

We should add some argument to `emqx start` for specifying the config files to be used, as well as one or more config entires. This feature is useful to users who want to start emqx from k8s and docker:

e.g.

```shell
emqx start --node-name="emqx1@192.168.0.12" \
  --config-file="/var/docker/volumes/emqx.conf.1" \
  --addtional-config-file="/var/docker/volumes/node.conf.1,/var/docker/volumes/node.conf.2"
```

We prefer command arguments rather than environment variables, as:

- the use of environment variables may different on unix and windows

- environment variables can be stripped by commands like `su - emqx`.

### Configs for Plugins

All the plugins after 5.0 need no config files. The plugins are configured, started or stopped from dashboard. This is similar to the approach of emqx rule engine, which can only be configured from dashboard.

#### Config Specs

The emqx rule engine provided a in-module config spec to the dashboard. It is used both for displaying the configs available and validating the configs got from user:

```
-resource_type(#{
    name => 'backend_pgsql',
    create => on_resource_create,
    destroy => on_resource_destroy,
    status => on_get_resource_status,
    params => #{
      server => #{
        order => 1,
        type => string,
        required => true,
        default => <<"127.0.0.1:5432">>,
        title => #{en => <<"PostgreSQL Server">>,
                   zh => <<"PostgreSQL 服务器"/utf8>>},
        description => #{en => <<"PostgreSQL Server Address">>,
                         zh => <<"PostgreSQL 服务器地址"/utf8>>}
      },
      database => #{
        order => 2,
        type => string,
        required => true,
        title => #{en => <<"PostgreSQL Database">>,
                   zh => <<"PostgreSQL 数据库名称"/utf8>>},
        description => #{en => <<"Database Name for Connecting to PostgreSQL">>,
                         zh => <<"PostgreSQL 数据库名称"/utf8>>}
      }
    },
    title => #{
        en => <<"PostgreSQL">>,
        zh => <<"PostgreSQL 数据库"/utf8>>
    },
    description => #{
        en => <<"PostgreSQL">>,
        zh => <<"PostgreSQL 数据库"/utf8>>
    }
}).
```

The `params` field is the config spec for that resource. The config spec is designed in a key-value manner, where the key is the name of the config entry, and the value describes the data type, title of the config entry, and whether it is required or optional, etc.

This works but is not easy to use, especially for developers from GitHub community to develop their own plugins. Also for the localization method used here is not extensible, we need to switch to some appropriate method such as [gettext](https://en.wikipedia.org/wiki/Gettext)[1].

#### A new Plugin Framework

A framework for new plugins should be designed, with following properties:

- provide a config spec framework based on `HOCON/Yaml` spec files.

  - The spec file should be separated out of erlang source file.

  - It uses a localization file for translating between different languages.

- provide a database framework for loading and managing configs.

  The database should be in a text format such as JSON/Yaml/HOCON, which is ease to be changed by tools outside of emqx.

  A interesting aspect of this approach is that, if we have a tool migrating configs from older versions to newer versions, the migration tool could translate the emqx.conf and the plugin's config db files to new versions using the same logic.

  The migration tool can simply be a python script that independent from emqx, so that it's easy to debug and fix if there's any issue in the tool. If otherwise we provide the migration tool in emqx CLI, we have to either re-tag the current version and recall the installation packages from website, or wait for the next version to get the issue fixed.

  Another benefit of this approach is that, we are able to create the config db file manually for a plugin without a running emqx broker. We could then put it to the `data/` dir and start the emqx, the plugin will get started together with emqx.

- provide a plugin management framework that start/stop/restart the plugins.

### Upgrade Config Files during Release Hot Upgrade

The config file should be backward compatible to support release hot upgrade. That is:

- a new config entry is allowed to be added in new version, but MUST have a default value.

- delete/rename an old config entry is not allowed in new version.

When upgrading to a new emqx version, the upgrade handler read the old config files, then merge them to the new config files.

After that the upgrade handler will load new config files.

## Configuration Changes

See the ...

## Backwards Compatibility

Not backward compatible as this is a 5.0 feature.

## Document Changes

The `configuration` section of the document need to be re-written.

## Testing Suggestions

Integrate testing for changing configs at runtime is need, both from the CLI and the API.

## Declined Alternatives

The `Centralized Config Service` way is not necessary as we can manage the configurations from the Dashboard. And to deploy and maintain a separated configuration node is too complex. Keeping all the code and components in the same project makes life easer. With tools like config maps in Kubernetes we can easily update the config files and reload them to all the running emqx nodes.

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

## References

[1] https://en.wikipedia.org/wiki/Gettext "gettext"
