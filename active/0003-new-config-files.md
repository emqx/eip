# New Config Files for EMQ X v5.0

```
Author: Shawn <liuxy@emqx.io>
Status: Draft
Type: Design
Created: 2020-10-19
EMQ X Version: 5.0
Post-History:
```

## Abstract

The configuration files of EMQ X is to be changed significantly in EMQ X 5.0, both in its syntax and its architecture. This proposal explains the rationale behind its design and describing the changes in detail.

## Motivation

The config files and the config entries need to have the following properties:

- The config files should be more readable and editable to users.

- The config entries should be able to updated at runtime.

- The config entries should be able to loaded from a centralized config service in a large distribution deployment.

- The config files should be able to upgraded in a backward compatible manner during release hot upgrade.

## Rationale

### New Config Syntax

A new config syntax/language will be introduced into EMQ X, it can be either `HOCON` or `Yaml`, both are widely used config syntax at the time of writing. For comparison of the two, see [0002-new-config-syntax](./0002-new-config-syntax.md).

In spite of the config syntax, the internal config syntax used by emqx should be erlang terms: the AppConf and the ConfMap, see the architecture section for details.

### Structure of Config Files

The emqx.conf before version 5.0 is self-explained as the comments are very detailed, but is too verbose for editing.

The solution here is to give user a clean emqx.conf with only necessary configs in it, without any comments. And provide an example of config files together with the emqx installation package, which are verbose and full documented.

There should not be too many config files, otherwise the user may have a problem locating the correct place to change a config entry.
Also the config file names should be clear so that the user can speculate which configs would be located in which config file:

```
.
├── emqx.conf
```

I suggested only one config file (`emqx.conf`) here.

For the HOCON based configuration struct of emqx, see [configs](https://github.com/terry-xiaoyu/emqx/tree/emqx50_shawn/configs).

### Deploy Without Centralized Config Service

#### Architecture

This is the default deployment strategy: all configs are read from the config files and translated to `sys.config` (the erlang system config file) by applying the config schema.

```
                                                [Application Controller]
                         (schema)                    +----------+
  HOCON ---> KeyWordList -------> [sys.config]---->  | AppConf  |
                                                     |    [emqx]|
[*.conf]                                             +-------|--+
                                                             |
                                                      +------v--+
                                                      | ConfMap |
                                                      +---------+
                                                    [Persistent Term]
```

The config entries are then loaded to the Erlang's application controller, which is stored in a ETS table. hereafter this text we call it `AppConf`.

After the node is stared, emqx application will read all the configs from `AppConf` under the key `emqx`, converting it to a map and then load it to a config registry in the local node. I'd like to call this config registry as `ConfMap`. The `ConfMap` is based on Erlang's persistent term, and the map data type is used mainly for constant time reading operations.

The config parser interprets the configs files to an Erlang keyword-list to keep the order of the config entries as it is.

The schema files is the same as the cuttlefish schema files we used in emqx before 5.0. We keep using schema files because it separates the work of translation and validation out of emqx application. It is good for the extensibility of our system.

The schema file is not mandatory if no translation/validation is needed. The format of config values should be designed in a manner that do not need to be translated by the schema files:

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

The prior is not only more readable to users without reading the comments/documents, but also more intuitive to programmers for searching the config entry through the code files.

#### Config Update at Runtime

The config files can be modified and reloaded after the emqx broker has been started, but not all of the config entries are able to updated at runtime. We should provide some CLIs/APIs to help users for debugging/verifying the changes of the config files, and showing user the changes applied to the runtime after reloading the config files:

- `emqx_ctl config reload`

  Reload the config file, returns the list of config entries applied to `ConfMap`.

  Config entries that is changed in the config files but requires restarting the broker should be shown as warnings:
  `warning: config 'a=1' has been changed in emqx.conf but cannot be reloaded at runtime`.

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

Configs cannot be update from the dashboard, as it would introduce much more complexities than benefits:

  - If the configs are changed both from the dashboard and in config files at the meanwhile, we have to solve the conflicts between the two. This may be solved by denying the update request from dashboard and prompt the user to reload changes from files first, and then let the user make their changes again from dashboard.

  - If we changed the configs from dashboard, it's hard for us to permanent the changes back to the files, as:

    The user may have changed some configs in the file, in any unpredictable format. If we have to write back the changes, we may need to write additional config lines in the file. But this way if the user changes a config entry later, it would be overridden by the lines we added, which confuses the user. The circumstance becomes worse if there are more than one config files.

  - But if we don't support permanent back to files, there would be a inconsistency between the configs in use and the configs in the config files. We have to notify the user to change the files to make sure they survives a system restart. Then I'd prefer to change the config files directly and then reload it.

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

## References

[1] https://en.wikipedia.org/wiki/Gettext "gettext"
