## Community Plugins

```
Author: Yudai Kiyofuji <yudai.kiyofuji@emqx.io>
Status: Draft
First Created: 2021-02-21
EMQ X Version: 4.3
```

## Change log

* 2021-02-23: @z8674558 Initial draft
* 2021-02-25: @z8674558 Add proposal on elixir plugins

## Abstract

This proposal suggests ways to encourage plugin development by community. 

## Motivation

Allowing people to develop their own plugins is a good way for EMQX to gain popularity.
To achieve this, it is nice to `approve` some community plugins and let people use them.

## Design

At the root of emqx.git, we add the file `community-plugins`, 
where we list approved community plugins.
(the advantage of having it in a separate file is to keep minimum lines of such in `rebar.config.erl`
which may otherwise cause more lines of conflicts when porting changes to enterprise.)

```erlang
{erlang_plugins, [{foo_plugin, {git, "https://github.com", {tag, "1.0.0"}}}}]}.
```

And when a user would like to use one of them, 
he/she can do so by setting env variable `EMQX_COMMUNITY_PLUGINS=foo_plugin`.
Then `rebar.config.erl` read the file and the environment variables, to include specified ones.

### Elixir Plugins

Considering the recent popularity of Elixir, we have decided to continue supporting Elixir plugins in v4.3.
At the end of `community-plugins` file, there should be

```erlang
{elixir_plugins, [{bar_plugin, {git, "https://github.com", {tag, "1.0.0"}}}}]}.
```

 ## Configuration Changes



 ## Backwards Compatibility


 ## Document Changes

In `emqx-doc`, there should be detailed information
on how to use third-party plugins.

Add detailed information on how one can develop their own plugins
in `emqx-plugin-template` and `emqx-elixir-plugin`.

 ## Testing Suggestions

Suppose we have approved a third-party plugin `emqx-some-plugin`.
Since we have an umbrella project in v4.3, 
The developers of `emqx-some-plugin` is going to run the test
by placing it to emqx.git, for example in `_checkouts` dir.

In `emqx-some-plugin`'s CI, they have to fetch emqx.git then run the test.
