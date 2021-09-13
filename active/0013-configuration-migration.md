# Data import and export using Mnesia backups

## Change log

* 2021-09-09: @k32 Initial draft

## Abstract

Backup and restore of database tables and configuration should be used for the cluster upgrade.
This procedure should replace the JSON configuration dumps.

## Motivation

Upgrading the EMQ X cluster between major releases requires redeployment of the cluster.
Currently runtime data is migrated by dumping it to a JSON file and importing it as described here:
https://docs.emqx.io/en/broker/v4.3/advanced/data-import-and-export.html#data-import-and-export

Encoding Erlang terms to JSON and decoding them back is a manual error-prone process.
We propose to use binary dumps instead, starting from EMQ X 5.0.

## Design

A new `emqx_metadata` mnesia table should be added.
Mnesia has a checkpoint feature that can be used to perform a backup.
TODO: decide the best way to include data from the external databases (MySQL, MongoDB, etc.) to the backup.

Two types of data migration will be supported:
1. Online data migration between patch releases
1. Offline data migration between major and minor releases

### Export

The following steps will be used to export data:

1. Activate a local mnesia checkpoint
1. Backup the checkpoint to a BUP file using the standard mnesia backup callback module
1. `emqx_metadata` table should be always added to the BUP file
1. Hocon configuration dump should be added to the BUP file
1. TODO: dump other data ?

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
   %% Num | Intruduced in release | Allow online | Function
    [ {100, "5.1.0",                false,         fun upgrade_lib_baz/2}
    , {99,  "5.0.1",                true,          fun lib_bar:upgrade_lib_bar/2}
    , {98,  "5.0.0",                false,         fun lib_foo:upgrade_lib_foo/2}
    ...
    ].

upgrade_lib_baz(_From, _To = "5.1.0") ->
  mnesia:transform_table(...).
```

Every upgrade hook definition contains four fields:

1. A strictly decreasing number of the upgrade hook
1. Version of EMQ X release where this upgrade hook has been introduced, non-increasing
1. "Allow online" flag, that specifies whether or not the hook can be used in an online update
1. Reference to the upgrade hook.
   All the upgrade hooks should be immutable: once they are written, they shouldn't change

There should be a separate module that works with the upgrade hooks, called `emqx_upgrade_helper`.

It has the following functions:

1. `init()`, where it creates an internal metadata table that contains `data_version` record that contains the EMQ X release version corresponding to the currently loaded configuration and runtime data.
   This function is called during fresh installation of EMQ X
1. `check()`, where it loads `emqx_upgrade` module and verifies the following properties:
   1. List of the upgrade hooks is sorted by `num` and `introduced_in` fields
   1. The largest `introduced_in` field is lesser or equal to the EMQ X release version
   1. `allow_online` field is `true` for all patch versions, so hot upgrades are possible

   This function can be called in CI to test the upgrade code
1. `upgrade()` that performs data migration.
   It performs the following steps:
   1. Load the latest version of `emqx_upgrade` module
   1. Filter out all the upgrade hooks with `introduced in` lesser than the current `data_version` and `num` lesser then the `last_upgrade_hook` record in `emqx_metadata` table, if present
   1. Execute the hooks obtained on the previous step.
      If the hook ran successfully, update `last_upgrade_hook` counter.
      If `introduced_in` field of the _next_ update hook is larger than the current version, then insert the _current_ version to `emqx_metadata` table

`upgrade()` function can be added to the appup file, so it handles hot upgrades too

#### Configuration migration

Upgrade hooks can perform configuration migration.
TBD: decide how it can work nicely with Hocon

#### Runtime data migration

Runtime data migration helps migrating the database tables, for example user-defined ACL chains, user accounts, etc.
This is done using regular DB functions.
During online upgrade this is done on the live mnesia cluster.
During offline upgrade this is done in the isolated mnesia cluster.

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
