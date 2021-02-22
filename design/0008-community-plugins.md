# Community Plugins

```
Author: Yudai Kiyofuji <yudai.kiyofuji@emqx.io>
Status: Draft
First Created: 2021-02-21
EMQ X Version: 4.3
```

## Abstract

This proposal suggests ways to encourage plugin development by community. 

## Motivation

Allowing people to develop their own plugins is a good way for EMQX to gain popularity.
To achieve this, it is nice to `approve` some community plugins and let people use them.

## Design

In rebar.config.erl, we can add a list of approved community plugins.

```erlang
community_deps() ->
    [
      {foo_plugin, {git, "https://github.com/###"}}
    , {bar_plugin, {git, "https://github.com/###"}} 
    ].
```

And when a user would like to use one of them, 
he/she can do so by setting env variable `EMQX_COMMUNITY_PLUGINS=foo_plugin`.


 ## Configuration Changes



 ## Backwards Compatibility


 ## Document Changes



 ## Testing Suggestions


