# Rolling cluster upgrade

## Change log

* 2021-09-21: @k32 Initial draft
* 2021-09-23: @k32 Applied remarks
* 2021-09-28: @k32 Applied remarks

## Abstract

Currently EMQ X upgrade procedure has two modes of upgrade:

1. Patch releases.
   Upgrading between the patch versions is done by patching the live nodes using Erlang hot code patching feature.
   The patch is loaded to the existing running nodes.
   This is a low-maintenance upgrade path, however severely limited in the scope of the changes.

1. Minor and major releases requires taking down the entire cluster and redirecting the MQTT traffic to a different cluster running the new version of the software.
   This approach introduces a lot of operational overhead.

EMQ X should support rolling upgrade of the cluster when nodes (or pods) are taken down and replaced one by one for minor version upgrades.
Patch version upgrades will remain the same.

This EIP introduces the guidelines for writing the backward- and forward-compatible code.
Also it documents the necessary changes to the existing code base.

## Motivation

In order to make upgrading the cluster smoother, EMQ X should support rolling cluster upgrades and green-blue deployments.
It should be possible to upgrade the cluster without taking it down entirely, by making sure that different minor versions of the code can communicate in both directions.

## Design

Patch version upgrades will not be changed.
They will follow the existing instruction: https://docs.emqx.io/en/broker/v4.3/advanced/relup.html

Live upgrade paths will be limited to `major.minor.* -> major.minor+1.*` or `major.minor.* -> major.minor.*` formulas.

A new concept of a "backplane API" is introduced.

Cluster upgrade should be split in roughly three stages:

1. Optional step: inject the forward compatibility support into the old upgrade.
   This may be needed because we can't predict in advance what will be changed in the next release.
   The upgrade code should be able to inject pre-upgrade beams to the old release.
   This part of the upgrade procedure should be idempotent and reversible.
   It will work much like a patch version upgrade, using `appup` files in the same way as now.

   During this stage, all nodes in the cluster are running the same `major.minor` version of the code.

1. Rolling upgrade of the cluster that involves taking nodes down and replacing them with the newer version.
   This part of the upgrade is revesible.

   During this stage, different nodes in the cluster are running different minor versions of the code.
   Appup files are not used, because the nodes are created from scratch.

1. Once all the nodes are upgraded, a data migration can start.
   This part of the upgrade is not reversible, because the migration process is destructive.
   It is triggered by an explicit command from the operator, and runs asynchronously (TODO: describe the user interface for doing this).
   (TODO: come up with a testing strategy that verifies handling of the partially migrated data)

Deprecated APIs can be removed in the next release.

There are two major areas that need to be considered to support this kind of upgrade:

1. RPC compatibility
1. Mnesia schema backward-compatibility

### Design of the helper bpapi application

We propose to create a new helper application that helps to maintain the API backward-compatibility.
(Let's call it `bpapi`).
This application should be located in a separate repo, so it could be added as a dependency for all the external EMQ X plugins, as well as EMQ X itself.
This application will contain the code that performs static checks of the API modules.

A helper mnesia table tracking the upgrade state and release version for each node can be used to perform the checks between proceeding to the next stage of the upgrade.

### RPC compatibility

In order to simplify the reasoning about the backplane API backward-compatibility, all the functions that may be called remotely should be identified and gathered in specialized modules.
Static checks should be introduced to make sure these functions are not removed without being deprecated first.
(Perhaps dump the list of these functions to a file that is held in the repo and used in the CI?)
Direct sending messages to the remote processes should be prohibited.
Instead, a helper function in the API module should be introduced.

### Mnesia schema compatibility

Fields of the tables can't be removed (until the last stage of the upgrade?).
Non-trivial changes to the schema should be performed in stages:

1. The new version of the code should be able to work with the old schema.
1. Once all the nodes in the cluster are updated, start an async process of migrating the data to the new table.
1. Once the data has been migrated and checks pass, the old table can be removed.
1. In the next release the code supporting the old schema can be dropped.

#### Table migration

`bpapi` application takes care of the static checks.
Writing migration in a way that avoids whole-table locks is a complicated process, and should be done on a case-by-case basis.
Migration process could utilize mnesia transactions to traverse the tables entry-by-entry and move the records to the new table, deleting the old record.
The read code should read both tables.

### Static checks

Annotations can be used to specify the API functions:

```erlang
-module(foo_api).

-intruduced_in({foo/3, {5,0,0}}).
foo(A, B, C) ->
    rpc:call(foo_api_impl, foo, [A, B, C]).

-intruduced_in({bar/3, {5,0,0}}).
-deprecated_in({bar/3, {5,1,0}}).
foo(A, B, C) ->
    rpc:call(foo_api_impl, bar, [A, B, C]).
```

```erlang
-module(foo_api_impl).

foo(A, B, C) ->
    ...

foo(A, B, C) ->
    ...
```

The following static checks should be written:

1. (xref): Only the functions in `*_bpapi` modules, that have `-introduced_in()` annotation, are allowed to call `rpc:call` and `gen_rpc:call` function
1. Functions that have `deprecated_in` annotation are not removed earlier than two releases after the deprecation
1. Each API function does an RPC to an existing function (xref check)
1. Compatibility of the typespecs of the API modules:
   - Function domain is not reduced
   - Function co-domain is not extended

The last check uses custom code, that iterates through function arguments and return types and calls `erl_types:t_is_subtype/2` function for the corresponding types in the new and the old minor version of the application (determined by the `app.src` file).

## Configuration Changes

n/a

## Backwards Compatibility

This change is backward-compatible.

## Document Changes

Document cluster upgrade procedure.

## Testing Suggestions

1. Change the CI, so some or all cluster test suites run on a cluster consisting the nodes running two different versions of EMQ X.

## Declined Alternatives

Offline cluster upgrade via backup transformation.
