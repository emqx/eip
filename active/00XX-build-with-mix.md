Build With Mix
==============

# Abstract
Currently we're using `rebar3` to manage all our projects, rebar3 works good but we have a lot of benefits to move to `mix`.
This documentation explains all the details of moving `rebar3` to `mix`.

# Motivation
  * Ability to improve EMQX with `elixir` language.
  * Powerful dependency management.
  * Deprecate hacked rebar.config.erl.

# Challenge

## Compiler
Be default, We're only able to put all applications in one folder for an umbrella project managed by `mix`.
But we can hack for the [Mix.Project.apps_paths](https://github.com/elixir-lang/elixir/blob/v1.12.1/lib/mix/lib/mix/project.ex#L263) function to load applications in `lib-ce` and `lib-ee`.

```elixir
defmodule Test.MixProject do
  use Mix.Project

  def project do
    set_apps_paths()

    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  defp set_apps_paths() do
    key = {:apps_paths, __MODULE__}
    Mix.State.write_cache(key, %{t1: "apps/app1", t2: "lib-ce/app2", t3: "lib-ee/app3"})
  end
end
```

## Release
**TODO**

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
