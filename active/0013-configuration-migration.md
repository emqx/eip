# Data import and export using Mnesia backups

## Change log

* 2021-09-09: @k32 Initial draft
* 2021-09-15: @k32 Reduce the scope. Add description of the UI

## Abstract

Backup and restore of database tables and configuration should be used for the cluster upgrade.
This procedure should replace the JSON configuration dumps.

## Motivation

Upgrading the EMQ X cluster between major and minor releases requires redeployment of the cluster.
User-defined ACL chains, user accounts, and other data is persisted in mnesia, and this data needs to be migrated to the new cluster.
Currently runtime data is migrated by dumping it to a JSON file and importing it as described here:
https://docs.emqx.io/en/broker/v4.3/advanced/data-import-and-export.html#data-import-and-export

Encoding Erlang terms to JSON and decoding them back is a manual error-prone process.
We propose to use binary dumps instead, starting from EMQ X 5.0.

## Design

A new `emqx_metadata` mnesia table should be added.
Mnesia has a checkpoint feature that can be used to perform a backup.

### Export

The following steps will be used to export data:

1. Activate a local mnesia checkpoint
1. Backup the checkpoint to a BUP file using the standard mnesia backup callback module
1. `emqx_metadata` table should be always added to the BUP file

### Import

A separate temporary BEAM process should be used during offline data migration.
This approach solves several problems:

1. The upgrade code can work with mnesia tables directly, using the regular data access layer APIs
1. The upgrade code can perform potentially destructive operations with the data without risk of affecting the running applications
1. The upgrade code can load beams files without affecting the running system

The offline upgrade process can be started manually via a script, or automatically from the main EMQ X process when data import API is called.
This process should load all the `beam` files that the regular EMQ X uses, but it won't start any of the applications.

Steps of the offline migration process:

1. Start `data_migration` application in a separate BEAM VM
1. Run upgrade hooks
1. If the previous step succeeds, create another backup using the standard procedure
1. Stop the temporary BEAM VM
1. Import the backup to the EMQ X cluster

#### Upgrade hooks

There should be an Erlang module called `emqx_upgrade` that collects all upgrade hooks.

```erlang
-module(emqx_upgrade).

-export([upgrade_hooks/0]).

upgrade_hooks() ->
   %% Num | Intruduced in release | Function
    [ {100, "5.1.0",                fun upgrade_lib_baz/2}
    , {99,  "5.0.1",                fun lib_bar:upgrade_lib_bar/2}
    , {98,  "5.0.0",                fun lib_foo:upgrade_lib_foo/2}
    ...
    ].

upgrade_lib_baz(_From, _To = "5.1.0") ->
  mnesia:transform_table(...).
```

Every upgrade hook definition contains the following fields:

1. A strictly decreasing number of the upgrade hook
1. Version of EMQ X release where this upgrade hook has been introduced, non-increasing
1. Reference to the upgrade hook.
   All the upgrade hooks should be immutable: once they are written, they shouldn't change

There should be a separate module that works with the upgrade hooks, called `emqx_upgrade_helper`.

It has the following functions:

1. `init()`, where it creates an internal metadata table that contains `data_version` record that contains the EMQ X release version corresponding to the currently loaded configuration and runtime data.
   This function is called during fresh installation of EMQ X
1. `check()`, where it loads `emqx_upgrade` module and verifies the following properties:
   1. List of the upgrade hooks is sorted by `num` and `introduced_in` fields
   1. The largest `introduced_in` field is lesser or equal to the EMQ X release version

   This function can be called in CI to test the upgrade code
1. `upgrade()` that performs data migration.
   It performs the following steps:
   1. Load the latest version of `emqx_upgrade` module
   1. Filter out all the upgrade hooks with `introduced in` lesser than the current `data_version` and `num` lesser then the `last_upgrade_hook` record in `emqx_metadata` table, if present
   1. Execute the hooks obtained on the previous step.
      If the hook ran successfully, update `last_upgrade_hook` counter.
      If `introduced_in` field of the _next_ update hook is larger than the current version, then insert the _current_ version to `emqx_metadata` table

#### REST API

Management API should be extended with two methods:

```bash
$ curl -i --basic -u admin:public -X POST "http://localhost:8081/api/v4/data/backup"
```
and

```bash
$ curl -i --basic -u admin:public -X POST "http://localhost:8081/api/v4/data/restore" -d @/tmp/my-node-name-2021-09-15-1402.BUP
```

Restore method does both migration and backup, depending on the backup version.

#### CLI

```bash
$ ./emqx_ctl data backup
Created backup /tmp/my-node-name-2021-09-15-1402.BUP
```

```bash
$ ./emqx_ctl data restore /tmp/my-node-name-2021-09-15-1402.BUP
```

#### Interaction of the EMQ X process with the helper process

Add a simple `gen_server` to track the state of backup and restore.
During migration of the old backup, it spawns the migration helper process asynchronously and tracks its state.
This is needed to avoid REST API timeouts when the backup is large.

## Configuration Changes

n/a

## Backwards Compatibility

This fix is backward compatible.

## Document Changes

Document backup and restore functions.

## Testing Suggestions

Automatic upgrades can be tested in CI.
TODO: Decide how to create a configuration backup for each EMQ X release to be used as an input for the test.

## Declined Alternatives

### Configuration migration

Configuration should be backward-compatible.
A more modern solution is to delegate configuration management to the cluster orchestrator, such as terraform.

### Online updates

Integrating the same hook mechanism into hot upgrade looks like a low-hanging fruit.
However, non-trivial hot upgrades that include schema migrations are non-trivial for other reasons, so this idea was abandoned.
