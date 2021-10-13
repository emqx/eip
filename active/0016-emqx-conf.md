# EMQX Configuration Manager

## Changelog

* 2021-10-12: @zhongwencool init draft

## Abstract

This proposal introduces a new Erlang application to handle EMQ X's configuration management with a focus on config live-reloads, and cluster wide config change syncs.

## Motivation
Prior to 5.0, EMQ X's configuration management are quite static.
* The user interfaces for config changes are environment variables or a text editor for the config files.
* To load changed configs, it usually requires restarting an application, or reloading a plugin, or sometimes even restarting the node.
* When managing a cluster, one would have to update config files one node after another. 
* Mnesia was used to store some of the configs (such as rule-engine resources) in order to get them replicated, which made it less configurable because it was not possible to bootstrap such configs from a file which can be prepared before the node boots. Instead, one would have to wait for the node to boot, and then call HTTP API to make the changes.

In this proposal, we try to address the pain-points by
- Supporting HTTP APIs to perform live config changes and reload.
- Persisting changes made from HTTP APIs on disk in HOCON format. 
- Maintaining consistency across the nodes in the cluster. For example authentication & authorisation (ACL) configs, and rule-engine rules.

In 5.0, no config is stored in Mnesia, however such changes are not in the scope of this EIP.
Some configs may not make sense to be the same for all nodes, so we should also allow local node overrides. such as `rate_limit` settings for nodes per their hardware capacity.

## Design

### Configuration files

#### emqx.conf

EMQ X reads `emqx.conf` for converting this hocon file into Erlang format at startup, and `emqx.conf` has only 2 lines by default.

```erlang
include "data/configs/emqx_cluster_override.conf"
include "data/configs/emqx_local_override.conf"
```

- If the user wants to manually modify a node's configuration item before startup, it can be appended to the end of the `emqx.conf`, or use `include "data/configs/user_default.conf`, and for the same configuration, the later value will overwrite the earlier one.
- If the user specifies to read environment variables for a configuration item, this value is read-only at runtime and will not be modified. In other words, the environment variables are always taken at the end of the `emqx.conf` file and has the highest priority.
- Unlike the previous declaration of all configuration items displayed in `emqx.conf`, if an item uses a default value, it does not need to be shown in `emqx.conf`.  the default is only embedded in the code. Also, users can view all configuration items via the HTTP API (described later). This would have 2 benefits: 
  - In subsequent version upgrades, adding/removing/updating configurations will not be overwritten by `emqx.conf`. 
  - This allows the user to focus only on the configuration that has been modified. 

#### emqx_cluster_override.conf

- This file can only be modified via the API and manual modification of file directly is not supported.

- When updating configurations that must require consistency across the cluster, they are persisted to this file.
- The node will copy this file from the longest surviving core node before initializing the configuration, this file will be added to initialize the configuration together.
- When the node is updated, the configuration within the cluster is updated via cluster call and persisted to this file.
- This file must be kept the same for all nodes, we will add an extra process to check the content of the file periodically, and alarm after 3 continuous differences are found.

#### emqx_local_override.conf

- This file can only be modified via the API and manual modification of file directly is not supported.

- When the configuration of a specific node is updated via HTTP API, it will be persisted to this file.

#### emqx_conf application
Before, the initialization of the configuration file, cluster_call, was done through the `emqx_machine`, we will split this part of the functionality from the` emqx_machine` and make a new application `emqx_conf`

The role of this application is to
- Convert the configuration from HOCON format to Erlang sys.config format at initialization.
- Manage live-updates and deletions of the configurations, and replicate across the cluster.

Other apps that want to update the configuration must call through the `emqx_conf`'s' API, which cannot call emqx API directly.
The specific flow is: 

```bash
Other Apps(eg: emqx_resource) => emqx_conf => emqx API.
```

### HTTP API design

#### Get the whole configurations.

```erlang
#{
  get => #{
    description => <<"Get all the configurations of a given node, or all nodes in the cluster.">>,
    parameters => [
       {node, hoconsc:mk(typerefl:atom(),
          #{in => query, required => false, example => <<"emqx@127.0.0.1">>,
          desc => <<"Node name. When this parameter is not provided, configs for all nodes in the cluster are returned">>})},
       {debug, hoconsc:mk(typerefl:boolean(), #{in => query, required => false,
          desc => <<"Carries debug (metadata) information, such as file name and line number">>})}],
            responses => #{
                200 => #{"$node" => configs_list()}
            }
        }
    };
```

- Returns what the current value/documentation of all configuration items is, group by nodename.
-  `debug=true`, will return all the meta data, such as line number, default, document, easy to locate the problem.

#### Update specific configuration

```erlang
schema("/configs/:rootname") ->
    #{
      get => #{
            description => <<"Get the sub-configurations">>,
            parameters => [
              {node, hoconsc:mk(atom(), #{in => query, required => false})},
              {debug, hoconsc:mk(typerefl:boolean(), #{in => query, required => false})}
                          ],
            responses => #{
                200 => #{<<"$node">> => config_list()},
                404 => emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<"config not found">>)
            }
        },
        put => #{
            description => <<"Update the sub-configurations">>,
            parameters => [{node, hoconsc:mk(atom(), #{in => query, required => false})}],
            requestBody => config_list(),
            responses => #{
                200 => #{<<"$node">> => config_list()},
                400 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED'])
            }
        }
    }.
```

- get specific configuation, such as: `/configs/emqx_dashboard` will return :
  There should be a `sensitive` flag in the schema for sensitive fields, and the value should be reported back as `"******"` in the API, such as password.

  ```erlang
  #{'emqx@127.0.0.1' => 
     #{default_password => "****",
       default_username => "admin",
       listeners =>
         [#{backlog => 512,inet6 => false,ipv6_v6only => false,
            max_connections => 512,num_acceptors => 4,port => 18083,
            protocol => http,send_timeout => 5000}],
       sample_interval => 10,token_expired_time => 3600000},
    'emqx1@127.0.0.1' => ...
  }   
  ```

- Update specific configuation without the 'node' query string will modify the configuration of all nodes in the cluster and persist it in `emqx_cluster_override.conf`.

- Update specific configuation with `node='xxx@xx.xx.xx'` in the query string, only the configuration of the specified node will be modified, persisted to `emqx_local_override.conf`.

- If we have already modified a configuration in `emqx_local_override.conf` successfully, trying to update this value in `emqx_cluster_override.conf` again will return a failure, and the user will be instructed to reset this configuration from local before the update can succeed. Otherwise, since the priority of `emqx_local` is higher than that of `emqx_cluster`, the changes made in `emqx_cluster` will not take effect.

- Update requests carry the latest value back, and if the update fails, it also explains what the current value is.

#### Reset specific configuration

```erlang
schema("/configs_reset/:rootname") ->
  #{put => #{
     description => <<"Reset the sub-configurations">>,
     parameters => [{node, hoconsc:mk(atom(), #{in => query, required => false})}],
     requestBody => config_list(),
     responses => #{
       200 => #{<<"$node">> => config_list()},
       400 => emqx_dashboard_swagger:error_codes(['REST_FAILED'])
       }
   }
```

- We can't delete a configuration item, we can only reset it.
- Reset specific configuation without query string, will delete the configuation in `emqx_cluster_override.conf`. 
- Reset specific configuation with `node='xxx@xx.xx.xx'` in the query string, only the configuration of the specified node in `emqx_local_overide.conf` will be deleted.

## Configuration Changes

This section should list all the changes to the configuration files (if any).

## Backwards Compatibility

This sections should shows how to make the feature is backwards compatible.
If it can not be compatible with the previous emqx versions, explain how do you
propose to deal with the incompatibilities.

## Document Changes

If there is any document change, give a brief description of it here.

## Testing Suggestions

The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Declined Alternatives

The `emqx_cluster_override.conf` and `emqx_local_override.conf` can't be directly modified by handle, we can also store this information in mnesia. But it is not convenient for users to see it.

