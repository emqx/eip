Build With Mix
==============

# Abstract
Currently we're using `rebar3` to manage all our projects, rebar3 works good but we have a lot of benefits to move to `mix`.
This documentation explains all the details of moving `rebar3` to `mix`.

# Motivation
  * Ability to improve EMQX with `elixir` language.
  * Powerful dependency management.
  * Deprecate hacked rebar.config.erl.

# Changes

## Application Struct

Current emqx is managed by `rebar3` with such folder struct.

```
emqx
├── rebar.config
└── apps
    ├── emqx
    │   ├── rebar.config
    │   └── src
    │       └── emqx.app.src
    ├── emqx_exhook
    │   ├── rebar.config
    │   └── src
    │       └── emqx_exhook.app.src
    ├── emqx_gateway
    │   ├── rebar.config
    │   └── src
    │       └── emqx_gateway.app.src
    ├── ...
```

To add `mix` support, we need to deprecate `rebar.config` and `APP_NAME.app.src` files (don't remove), and add `mix.exs` files for each application.
Here's the folder struct for `mix`.

```
emqx
├── mix.exs
└── apps
    ├── emqx
    │   └── mix.exs
    ├── emqx_exhook
    │   └── mix.exs
    ├── emqx_gateway
    │   └── mix.exs
    ├── ...
```

the `mix.exs` file is based on the `rebar.config` and `APP_NAME.app.src` files, to handle the application name, compile flow, dependency, and so on.

Unlike `rebar3`, `src` folder won't be included in the destination folder, so all `*.hrl` files will be moved into `include` folder.

## Start File (bin/emqx)

`mix release` will generate elixir style `bin/emqx`.
The start options are different with what we have, for example, we'll use `bin/emqx daemon` to start a deamon instead of `bin/emqx start`, and the `bin/emqx start` will start a foregroud server like what `bin/emqx foregroud` did. Also we need to run command with elixir syntax and not erlang once we start the console or run `bin/emqx rpc COMMAND`.

The generated start file is powerful, but we're not able to use it directly.
1. We need to include some environment variables to forward compatible current system.
2. We need to call `nodetool` for our own usages.
3. We need to generate `app.config` and `vm.config` by `hocon` everytime we start the server.

So we need to modify the template to override the default one and add these features above.
The new start file is located at `rel/overrides/bin/emqx`.
The default `escript` depends on the boot file `no_dot_erlang.boot` which won't be copied by `mix release` by default, so we don't use the `bin/escript` to run `nodetool`. The following way helped us to pickup the clean boot file which include correct version of our libraries.

```bash
command="$1"; shift
"$RUNNER_ROOT_DIR/erts-$ERTS_VSN/bin/erl" \
    +B -noshell \
    -boot "$REL_VSN_DIR/$RELEASE_BOOT_SCRIPT_CLEAN" \
    -boot_var RELEASE_LIB "$RELEASE_ROOT/lib" \
    -run escript start \
    -extra "$RUNNER_ROOT_DIR/bin/nodetool" \
    "$command" "$@"
```

## Release Helper Application

`rebar3` provide us the `rebar.config.escript` to handle complex cases, but it's not powerful enough to handle our use cases and we built our own `rebar.config.erl`.
We'll have the same issue when release by `mix`, and we'll handle it with a different way.
With `mix`, we can move all the features we have into a new application, we can call it `emqx_release_helper` and put it into `apps/` folder.

The Release Helper will handle

1. difference between operator systems
2. run scripts under `scripts` folder
3. extra step and system env in `Makefile`
4. different release type(cloud/edge) and package type(bin/pkg)
5. generate overlay files by templates

We don't need to include this application into the release package since it's only for release step, and it's an internal feature for `mix`.

## GRPC

GRPC is a special case for the compile flow.
We're using a rebar plugin to compile `.proto` files to `_pb.erl` files when run `rebar3 compile`, but we don't have `rebar3` when run `mix compile`.
So we need to call `:gpb_compile.file/2` directly before compile the application depends on GRPC.

**TODO**: template for grpc hbvrs and clients.

## EUnit
**TODO**

## CT
**TODO**

# Migration Plan

## Add `mix.exs` to Compile EMQX as an Umbrella App

## Add Release Scripts
Also need to migrate the relx overlay and preprocess scripts.

## Make `eunit` Works
**TODO**

## Make `ct` Works
**TODO**

## Make `dialayzer` Works
**TODO**

## Make `xref` Works
**TODO**

## Migrate All `ci` Scripts
**TODO**
