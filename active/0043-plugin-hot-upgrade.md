# Plugin Hot-Upgrade for the EMQX Plugin Framework

## Changelog

* 2026-07-31: @JimMoen Initial draft

## Abstract

This EIP introduces a **hot-upgrade** capability to the EMQX plugin framework:
a running plugin can be upgraded to a new version of its code without stopping
its business logic. The upgrade path is described by an optional
`priv/relup/<from>-<to>.relup` file shipped inside the plugin package (the
instruction format is compatible with the existing `emqx_relup` plugin), and
the framework executes the code replacement and rollback on behalf of the
plugin author.

- Stateless plugins get a **zero-downtime** upgrade for free.
- Stateful plugins migrate their own state through a new `on_upgrade/2`
  callback; the framework does not guarantee the correctness of state
  transitions, but it does guarantee code-level rollback on failure.
- New entry points: CLI `emqx ctl plugins upgrade <Name> <TargetVsn>`, an
  extension of the existing HTTP action endpoint, and a new cluster-level
  BPAPI version.
- New configuration `plugins.hot_upgrade.enabled` (default `true`) and a new
  optional `supports_hot_upgrade` field in `release.json`.

## Motivation

The current plugin upgrade flow is disruptive:

```text
stop → disable → uninstall old version
allow → install → enable → start new version
```

The problems with this flow:

1. **Business interruption**: the plugin is fully unavailable during the
   upgrade, which means downtime for plugins that carry connections, rules, or
   bridges.
2. **Long manual operation chain**: 6 manual steps, prone to errors (forgetting
   to disable, mixing up versions, etc.).
3. **Asymmetry with EMQX itself**: EMQX already supports hot-upgrading its own
   release via `emqx ctl relup upgrade`. Plugins, as first-class citizens,
   currently can only be upgraded with downtime.

The goal of this EIP is to give plugin upgrades the same user experience as
`emqx_relup`.

## Design

### Design principles

1. **In-place code replacement of a single OTP application**: a hot upgrade
   replaces the beam code of a running OTP application without stopping it.
   The `rel_apps` of the target package are the goal, and the running OTP
   application of the old version is the carrier.
2. **Instruction-driven**: code changes are described by relup instructions;
   the execution engine is responsible for atomicity, rollback, and ordering.
3. **One plugin callback**: `on_upgrade(FromVsn, ToVsn)` is the only new
   (optional) contract on the plugin side.
4. **Cluster-wide consistency**: the upgrade operation is broadcast to all
   nodes via BPAPI; each node executes independently and reports its result.

### Current state and existing constraints

The startup sequence `do_ensure_started/1` in `emqx_plugins.erl` enforces the
key constraint that **only one version of a plugin may be running at a time**:

1. `ensure_no_other_version_active/1` refuses to start a new version if
   another version is already running;
2. `install/2` unpacks and installs the target package;
3. config schema is loaded and the start config is validated;
4. `emqx_plugins_apps:start/1` loads the beams and runs
   `application:load` + `application:start`.

The code loading in `emqx_plugins_apps:load/2` is coarse-grained and aimed at
fresh starts: each beam is loaded with `code:purge/1` + `code:load_file/1`.
`code:purge` discards the old code immediately without checking whether
processes still reference it. A hot upgrade needs the finer-grained
`code:soft_purge/1` + `code:load_binary/3` instead, combined with process
suspend/resume.

The existing `plugins/emqx_relup` plugin already implements `.relup`-driven
hot upgrades for the EMQX release itself, with the instruction set
`{load_module, Mod}` (skipped when the md5 matches), `{update, Mod,
{advanced, Extra}}` (suspend → load → `sys:change_code` → resume), and
`{restart_application, App}`. Its failure semantics, however, are: exceptions
in `code_changes` are **not caught** and the VM is restarted via
`init:restart()`. Plugin hot upgrades **must not** use that semantics:
exceptions must be caught and the upgrade rolled back locally.

### Overall flow

```
upgrade(Name, TargetVsn)
  │
  ├─ 1. Pre-flight (validation only, no side effects)
  │     · the plugin is currently in running state (from plugins.states)
  │     · the target package is installed (or obtainable from a local tar /
  │       another cluster node)
  │     · versions are comparable: target > current (rel_vsn comparison)
  │     · names match; the target version's rel_apps exist
  │
  ├─ 2. Prepare (read-only + unpack the package)
  │     · unpack the target package into the install dir (reuse install/2
  │       if not installed yet)
  │     · read the target release.json; locate priv/relup/<from>-<to>.relup
  │       (optional)
  │     · parse the relup file (if missing, generate default instructions:
  │       one load_module per beam)
  │     · verify that every module referenced by the instructions exists in
  │       the target ebin
  │
  ├─ 3. Execute code_changes (journaled, see "Rollback journal and failure
  │     semantics" below)
  │     · execute load_module / update / restart_application one by one
  │     · snapshot the old beam before each instruction; restore in reverse
  │       order on failure
  │     · exceptions are caught and rolled back; the VM is never restarted
  │
  ├─ 4. Invoke on_upgrade(FromVsn, ToVsn) (see "The on_upgrade callback"
  │     below)
  │     · invoked on the target version's <AppName>_app module (new code is
  │       already loaded at this point)
  │     · ok / {ok, _}          → proceed to Commit
  │     · rollback / {error, _} / exception → restore old code via the
  │       rollback journal and return an error
  │
  └─ 5. Commit (persistence)
        · plugins.states: rewrite the plugin's name_vsn to the target
          version, keep enable = true
        · remove the old version entry; keep the old package (per the
          safe_delete_package semantics) until the operator uninstalls it
        · each cluster node commits independently, then results are
          aggregated
```

### Plugin package format extension

#### New optional `release.json` field

```json
{
  "name": "demo",
  "rel_vsn": "1.1.0",
  "rel_apps": ["demo-1.1.0"],
  "with_config_schema": true,
  "supports_hot_upgrade": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `supports_hot_upgrade` | bool | `false` | The plugin explicitly declares it supports hot upgrades. When `false`, the framework refuses the `upgrade` command to protect plugins that are not aware of hot upgrade from dangerous in-place code replacement. |

`supports_hot_upgrade: true` is the plugin author's commitment: every process
in the application either has no state to migrate (stateless), or migrates its
state in `on_upgrade/2`.

#### Optional `priv/relup/<from>-<to>.relup`

The file lives under `priv/relup/` inside the plugin package, named after the
convention `<from>-to-<to>.relup` (e.g. `1.0.0-to-1.1.0.relup`), where
from/to are the plugin's `rel_vsn` (**not** the EMQX version).

The format is compatible with the schema in
`emqx_relup/priv/relup/README.md`, but only the following fields are used:

```erlang
#{
    from_version => "1.0.0",
    target_version => "1.1.0",
    code_changes => [
        {load_module, demo_handler},
        {update, demo_server, {advanced, #{max_pending => 1000}}}
    ]
}.
```

- Supported instructions: `{load_module, Mod}`, `{update, Mod, {advanced,
  Extra}}`, `{restart_application, App}`.
- **The `post_upgrade_callbacks` field is not supported**: post-upgrade
  actions uniformly go through the `on_upgrade/2` callback, avoiding two
  coexisting conventions.
- If the file is missing, the framework generates default instructions —
  `{load_module, M}` for every beam of the target application (modules whose
  md5 is unchanged are skipped) — and then proceeds to the `on_upgrade/2`
  phase.
- Parsing is the same as `emqx_relup` (`file:script/1`, dynamic terms
  allowed); only `from_version`/`target_version` are checked against the
  requested hop.

### The `on_upgrade/2` callback

The plugin's main application module (`<AppName>_app`, the same module
convention as the existing `on_config_changed` etc. callbacks) may optionally
export:

```erlang
%% State migration callback, old version → new version.
%% Called after the new code is fully loaded (after code_changes, before commit).
%% Return values:
%%   ok                    → migration complete, commit is allowed
%%   {ok, term()}          → same, with a migration result (logged by the framework)
%%   {error, Reason}       → migration failed; the framework performs an
%%                           automatic rollback (restores the old code)
%%   rollback              → the plugin has rolled its state back itself and
%%                           asks the framework to restore the old code
%%   {rollback, Reason}    → same as rollback, with a reason
on_upgrade(FromVsn, ToVsn) -> ok | {ok, term()} | {error, term()} | rollback | {rollback, term()}.
```

Semantics (documented in the plugin development guide as mandatory):

1. **Idempotent**: operators may retry a failed upgrade and `on_upgrade/2`
   may run again; it must be safe to repeat (same reentrancy requirement as
   `emqx_relup`).
2. **`rollback` is the plugin's own responsibility**: returning `rollback`
   means the plugin has restored its state to a level where the old code can
   keep working; the framework then restores the old beams.
3. **An exception is an error**: an exception in the callback is treated as
   `{error, Exception}` and the framework rolls back automatically.
4. During the callback, the plugin must **not** call `application:stop/start`,
   `init:restart`, or anything else that would break the framework's rollback
   capability.
5. The callback is dispatched through the existing `apply_callback/3`
   mechanism in `emqx_plugins_apps`; if the function is not exported, the
   framework treats the plugin as stateless (`{error, callback_not_found}` is
   not a failure — see "Failure semantics" below).

#### Helper functions provided by the framework

The `emqx_plugins_hot_upgrade` module offers the following helpers to plugin
callbacks (designed to cooperate with the framework's rollback journal):

| Function | Purpose |
|----------|---------|
| `suspend_and_change(Module, Pids, Extra)` | Wrapper for `sys:suspend` → `sys:change_code(_, Module, FromVsn, Extra)` → `sys:resume` on a set of processes; on failure of any step it restores the pre-suspend state and returns `{error, _}` |
| `is_module_changed(Module)` | Tells whether a module was replaced in this upgrade (md5 comparison), so the plugin can decide whether migration is needed |
| `old_beam_md5(Module)` | Reads the old beam snapshot of a module from the rollback journal, for plugin-implemented custom rollbacks |

### The execution engine: new module `emqx_plugins_hot_upgrade`

A new framework module in `apps/emqx_plugins/src/`:

```erlang
-module(emqx_plugins_hot_upgrade).

%% Main entry points
-export([upgrade/2]).                 % upgrade(Name, TargetVsn) -> ok | {error, Reason}
-export([upgrade_cluster/3]).         % upgrade_cluster(Nodes, Name, TargetVsn) -> per-node results

%% Helpers for plugin callbacks (see above)
-export([suspend_and_change/3, is_module_changed/1, old_beam_md5/1]).
```

Responsibilities and boundaries:

- **Pre-flight / Prepare**: reuses `emqx_plugins_fs` (tar unpacking, install
  dir) and `emqx_plugins_info` (release.json); **adds** relup file location
  and parsing.
- **Execution and rollback journal**: the only module holding the rollback
  journal (a private ETS table, see below).
- **Never writes `plugins.states` directly**: the commit phase goes through
  the existing config update path (`emqx_conf:update` style), so the
  `post_config_update` hook keeps working.
- During an upgrade, an in-progress marker is set so that concurrent
  lifecycle operations (`ensure_started` etc.) are serialized or rejected
  with `{error, plugin_upgrade_in_progress}`.

### Instruction execution semantics

Aligned with `emqx_relup_handler:eval/2` (the same instruction set, to enable
future code reuse):

| Instruction | Execution | Rollback |
|-------------|-----------|----------|
| `{load_module, Mod}` | Compute the md5 of the new beam; skip if it matches the currently loaded one; otherwise `code:soft_purge` + `code:load_binary(Mod, NewFile, Bin)` and make sure `code:add_patha` points to the new ebin | Restore the old beam: `code:load_binary(Mod, OldFile, OldBin)` |
| `{update, Mod, {advanced, Extra}}` | Expands to `{suspend, Pids}` → `{load_module, Mod}` → `{code_change, Pids, Mod, {advanced, Extra}}` → `{resume, Pids}`; Pids are the processes in the plugin's supervisor tree whose callback module is `Mod` (aligned with `emqx_relup_handler:get_supervised_procs`) | Code level: restore the old beam; process level: the process state must be rollback-safe by the plugin's own `code_change` (documentation requirement) |
| `{restart_application, App}` | `application:stop(App)` → purge & delete all modules → `application:load` + `application:start` (target `.app` file) | On failure: restore the old modules via the journal and attempt `application:ensure_all_started(oldApp)` to bring the app back up; if that also fails, return `{error, {rollback_failed, ...}}` |

**Key differences from `emqx_relup` (must be preserved):**

| Dimension | emqx_relup | Plugin hot upgrade |
|-----------|------------|--------------------|
| code_changes exception | **Not caught, VM restarted** | Caught and rolled back, VM stays up |
| Scope | The whole release | The plugin's rel_apps only |
| Version identifier | EMQX version | Plugin rel_vsn |
| Post-upgrade actions | `post_upgrade_callbacks` | `on_upgrade/2` callback |

### Rollback journal and failure semantics

**Rollback journal**: `#{Module => #{old_file => Path, old_bin => Binary}}`,
written before each `load_module`/`update`/`restart_application` takes
effect. Stored in a private ETS table
(`emqx_plugins_hot_upgrade_rollback`) that exists during the upgrade and is
destroyed after commit/rollback.

**Failure semantics:**

| Stage | Behavior on failure | Return |
|-------|---------------------|--------|
| Pre-flight / Prepare | No side effects, fail directly | `{error, #{stage => check_and_prepare, reason => _}}` |
| code_changes | Restore old beams from the journal in reverse order; processes already resumed by `{update, _}` stay resumed; return an error | `{error, #{stage => execute_code_changes, rolled_back => true}}` |
| `on_upgrade` returns `rollback` | The plugin has handled state rollback itself; the framework only restores old beams | `{error, #{stage => on_upgrade, action => rollback}}` |
| `on_upgrade` returns `{error, _}` / raises | The framework restores old beams (default automatic rollback) | `{error, #{stage => on_upgrade, action => auto_rollback, reason => _}}` |
| Commit | Config write failed: code is already new but the state still points to the old version; the framework does **not** auto-rollback (code and config have diverged). An error is returned telling the operator to either fix the config and retry `upgrade` (safe because callbacks are idempotent) or manually roll back to the old package | `{error, #{stage => commit, reason => _}}` |

**When the default automatic rollback applies:**

- The plugin does not implement `on_upgrade/2` → the framework treats it as
  stateless, skips the migration phase, and commits; code-change failures are
  auto-rolled back.
- The plugin implements `on_upgrade/2` but returns an error or raises →
  automatic rollback.
- The plugin explicitly returns `rollback` → the plugin's decision is
  respected; only the code is restored.

### State and metadata changes

#### `plugins.states` migration

After a successful hot upgrade:

```text
# before
[{name_vsn => "demo-1.0.0", enable => true}]

# after
[{name_vsn => "demo-1.1.0", enable => true}]
```

- Written through the existing config update path (`emqx_conf:update`), so
  the `post_config_update/4` hook in `emqx_plugins.erl` keeps working and the
  cluster config sync mechanism follows transparently.
- The old version entry is removed; the old package and directory are
  **kept** (`safe_delete_package` semantics) until the operator explicitly
  uninstalls them.
- The `enable` ordering of `plugins.states` (front/rear/before positions) is
  preserved.

#### Version consistency coordination

`ensure_no_other_version_active/1` must be relaxed to work with the state
after a hot upgrade:

- Case A: upgrade done, state points to the new version → on
  `ensure_started` of the new version, since the code is already replaced and
  the application is already running, `application:load/start` is **skipped**
  (idempotent `ok`).
- Case B: upgrade in progress / upgrade failed without rollback (abnormal
  state) → `ensure_started` returns `{error, plugin_upgrade_in_progress}` or
  triggers the automatic rollback to complete first.

#### Restart semantics (pending on restart)

Consistent with `emqx_relup`, a hot upgrade is a **code-level** replacement
and does not rewrite `.app` metadata:

- After a hot upgrade, `application:which_applications()` still shows the old
  version until the node restarts and loads from the new version directory.
  This is expected: the plugin API (`plugins list` / `plugins describe`)
  shows the new version, while the OTP application view shows the old one.
- After a node restart, `ensure_started` runs normally from `plugins.states`
  (which points to the new version), identical to a fresh install of the new
  version.
- Irreversibility: a successful hot upgrade is "semi-permanent" (pending on
  restart). To go back to the old version, the operator must either run a
  reverse upgrade before the restart (if a reverse relup file exists) or
  restore the old package files and restart.

### CLI / HTTP API / BPAPI

#### CLI

New branch in `plugins/1` of `emqx_mgmt_cli.erl`:

```text
emqx ctl plugins upgrade <Name> <TargetVsn>
```

- `<Name>` is the plugin name (without version); the current running version
  is derived from `plugins.states` (only one version of a plugin can be
  running at a time, so the old version need not be given explicitly).
- Equivalent explicit form (for scripts): `emqx ctl plugins upgrade
  <OldNameVsn> <NewNameVsn>`, where `<OldNameVsn>` must match the currently
  running version.
- Cluster behavior: broadcast to all nodes by default (same as
  `ensure_started`, via BPAPI multicall); results are printed per node, and
  failed nodes are listed separately.
- Usage text is added to the `plugins <command>` help list; argument errors
  print usage (aligned with the existing `plugins(_)` fallback branch).

#### HTTP API

Extend the action enum of `PUT /plugins/:name/:action` in
`emqx_mgmt_api_plugins.erl`:

```text
PUT /api/v5/plugins/{NameVsn}/upgrade
Content-Type: application/json

{ "target_vsn": "1.1.0" }
```

- The `:action` enum grows from `[start, stop]` to `[start, stop, upgrade]`;
  the `upgrade` branch reads `target_vsn` from the request body.
- Responses: `200` (success, per-node results), `400` (bad parameter / target
  version unavailable), `404` (plugin not found), `409` (upgrade in progress
  or version constraint not met), `500`.
- Follows the existing swagger schema style (`?DESC`, `hoconsc`);
  `operationId => upgrade_plugin`.
- Alternative (not recommended): a new path `POST /plugins/upgrade` —
  inconsistent with the existing path organization, unless the community
  review prefers a standalone resource path.

#### BPAPI

New proto version `emqx_mgmt_api_plugins_proto_v6` (layered on top of v5,
v5 compatibility preserved):

```erlang
-spec hot_upgrade([node()], binary(), binary()) -> emqx_rpc:multicall_result().
hot_upgrade(Nodes, Name, TargetVsn) ->
    rpc:multicall(Nodes, emqx_plugins_hot_upgrade, upgrade, [Name, TargetVsn], ?TIMEOUT).
```

- Old nodes (without v6) refuse the hot upgrade request and return an error
  pointing to the traditional flow (stop/install/start).

## Configuration Changes

### New node in `emqx_plugins_schema.erl` (HOCON schema)

```hocon
plugins {
  hot_upgrade {
    enabled = true
  }
}
```

- Defaults to `true`; when `false`, the CLI/API returns
  `{error, hot_upgrade_disabled}`.
- Part of the cluster config via `emqx_conf`, supports runtime hot update
  (the `config` update path).

### New optional `release.json` field

- `supports_hot_upgrade`: bool, defaults to `false` — see "Plugin package
  format extension".

## Backwards Compatibility

| Dimension | Impact |
|-----------|--------|
| Old plugin packages (no `supports_hot_upgrade`, no relup file) | Unaffected: without the declaration there is no hot upgrade support; `upgrade` is refused and the traditional flow is unchanged |
| `plugins.states` structure | Unchanged (still an array of `#{name_vsn, enable}`) |
| Existing CLI/API | Only the action enum is extended and a subcommand added; existing behavior is unchanged |
| BPAPI | New v6; v5 callers are unaffected |
| Config schema | New nodes are optional with defaults |

## Document Changes

- `PLUGIN.md` (plugin development guide): add a "Hot Upgrade" chapter —
  the `supports_hot_upgrade` field, the `on_upgrade/2` callback contract
  (idempotency/rollback requirements), the `priv/relup` file format and
  instruction table, and the upgrade sequence.
- `emqx_plugins` i18n (`etc/en_US/` etc.): new error description strings for
  the CLI/API/config additions.
- The example plugin in this document doubles as a CT fixture and a best
  practice template.

## Testing Suggestions

| Layer | Cases |
|-------|-------|
| Unit tests (emqx_plugins_hot_upgrade) | relup parsing (missing / malformed / from-to mismatch); rollback journal correctness (reverse restore, md5 snapshot); md5 skip logic |
| Unit tests (callback dispatch) | Each return branch of `on_upgrade/2` (ok / rollback / error / exception / not exported); failure path of `suspend_and_change` |
| CT (single node) | Example plugin: old version running → upgrade → verify state migration and process liveness; force a code_changes failure → verify the old version keeps serving after auto-rollback |
| CT (rollback) | After `on_upgrade` returns `{error, _}`: old beams restored, old state readable, processes alive |
| CT (cluster) | All nodes upgraded simultaneously: all succeed; one node fails → that node rolls back while the rest succeed; `plugins.hot_upgrade.enabled = false` refuses the command |
| Concurrency | upgrade racing `ensure_started`/`restart` → serialized or `upgrade_in_progress`; operator retry of a failed upgrade → idempotency check |

## Declined Alternatives

### Blue-green / A-B dual-active (phase-2 optional direction)

Initially considered as the core approach: the framework maintains two
independent supervisor subtrees / namespaces (A/B) and a config switch routes
traffic to one of them. **Rejected for this EIP** because:

- Dual-active makes fundamental architectural demands on plugins (shared
  state replication/coordination, connection migration) that most existing
  plugins do not meet; it cannot land as a generic capability;
- The implementation cost is far higher than in-place code replacement, and
  most of the benefits (instant switchover, natural rollback) are covered by
  the rollback journal plus a fast reverse upgrade;
- It is orthogonal to `supports_hot_upgrade` and can be proposed as a
  separate EIP later.

Design intent is kept for the record: plugins declare
`supports_blue_green: true` (a new field); the framework provides
co-existence scheduling and namespace isolation; plugins own the dual-active
semantics. To be elaborated as phase 2.

### Restarting the VM on failure (reusing emqx_relup semantics)

Considered reusing the `emqx_relup_handler` execution flow directly (no
exception catching, `init:restart()` on failure). **Rejected**: a plugin is a
single application; restarting the VM interrupts the whole node's business,
which directly contradicts the zero-downtime goal. Plugin upgrade failures
are also expected to be more frequent than EMQX release upgrades and must be
handled with a local rollback rather than a node restart.

### Refusing upgrades when no relup file is present

Considered requiring every plugin to ship a relup file before it can be hot
upgraded. **Rejected**: for stateless plugins (the most common case) the code
replacement is a deterministic soft-purge-and-load sequence that does not
need hand-written instructions. Generated default instructions plus md5
skipping are safe enough and lower the adoption bar.

### Reusing `post_upgrade_callbacks` (supporting the field in plugin relup files)

Considered making plugin relup files fully isomorphic to emqx_relup,
including `post_upgrade_callbacks`. **Rejected**: two coexisting callback
conventions (a callback list plus `on_upgrade/2`) would confuse plugin
authors; a single `on_upgrade/2` entry is easier to document and easier to
coordinate with rollback.

## References

- `apps/emqx_plugins/src/emqx_plugins.erl` — lifecycle API and the
  `ensure_no_other_version_active` constraint
- `apps/emqx_plugins/src/emqx_plugins_apps.erl` — application loading and the
  `apply_callback/3` callback dispatch
- `apps/emqx_plugins/src/emqx_plugins_schema.erl` — `plugins.states` HOCON
  schema
- `apps/emqx_management/src/emqx_mgmt_api_plugins.erl` — HTTP API
  (`PUT /plugins/:name/:action`)
- `apps/emqx_management/src/emqx_mgmt_cli.erl` — CLI registration (`plugins/1`)
- `apps/emqx_management/src/proto/emqx_mgmt_api_plugins_proto_v5.erl` — the
  current BPAPI, the base for v6
- `plugins/emqx_relup/src/emqx_relup_handler.erl` — reference implementation
  of relup instruction execution
- `plugins/emqx_relup/priv/relup/README.md` — the relup file format spec
  (schema, instruction table, reentrancy requirements)
- `PLUGIN.md` — the plugin development guide (package format, release.json,
  application callback conventions)
- EIP-0019 (implemented) — background on the EMQX 5.0 plugin framework
