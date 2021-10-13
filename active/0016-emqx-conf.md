# EMQX Configuration Manager

## Changelog

* 2020-10-21: @zhongwencool init draft

## Abstract

This proposal introduces a new Erlang application to handle EMQ X's configuration management with a focus on config live-reloads, and cluster wide config change syncs.

## Motivation

Try to find a suitable way to:

- Hot update configurations via HTTP API.
- Maintain consistency of the configuration across the cluster, for example `authorization.source`, rules engine's rules.
- Different nodes of the cluster may set different values for the same configuration item, such as: use different `rate_limit` settings for machines with different hardware limitations.

## Design

### Configuration files

#### emqx.conf

Emqx reads `emqx.conf` forconverting this hocon file into Erlang format at startup, and `emqx.conf` has only 2 lines by default.

```erlang
include "./data/emqx_cluster_override.conf"
include "./data/emqx_local_override.conf"
```

- If the user wants to manually modify a node's configuration item before startup, it can be appended to the end of the `emqx.conf`, or use `include "./data/user_default.conf`, and for the same configuration, the later value will overwrite the earlier one.
- If the user specifies to read environment variables for a configuration item, this value is read-only at runtime and will not be modified. In other words, the environment variables are always taken at the end of the `emqx.conf` file and has the highest priority.
- Unlike the previous declaration of all configuration items displayed in `emqx.conf`, if an item uses a default value, it does not need to be shown in `emqx.conf`.  the default is only embedded in the code. Also, users can view all configuration items via the HTTP API (described later). This would have 2 benefits: 
  - In subsequent version upgrades, adding/removing/updating configurations will not be overwritten by `emqx.conf`. 
  - This allows the user to focus only on the configuration that has been modified. 

#### emqx_cluster_override.conf

- This file can only be modified via the API and manual modification of file directly is not supported.

- When updating configurations that must require consistency across the cluster, they are persisted to this file.
- The node will copy this file from the longest surviving core node before initializing the configuration, , this file will be added to initialize the configuration together.
- When the node is updated, the configuration within the cluster is updated via cluster call and persisted to this file.
- This file must be kept the same for all nodes, we will add an extra process to check the content of the file periodically, and alarm after 3 continuous differences are found.

#### emqx_local_override.conf

- This file can only be modified via the API and manual modification of file directly is not supported.

- When the configuration of a specific node is updated via HTTP API, it will be persisted to this file.

#### emqx_conf application
Before, the initialization of the configuration file, cluster_call, was done through the `emqx_machine`, we will split this part of the functionality from the` emqx_machine` and make a new application `emqx_conf`

The role of this application is to
- Converting the configuration from hocon format to erlang sys.config format at initialization.
- Manage hot updates and deletions of configurations within the cluster.

The basic node configuration hot update remains in emqx, in other words: `emqx_config_handler`, remains unchanged, but other apps that want to update the configuration must call through the `emqx_conf`'s' API, which cannot call emqx API directly.
The specific flow is: 

```bash
Other Apps(eg: emqx_resource) => emqx_conf => emqx API.
```

### HTTP API design

#### Get the whole configurations.

```erlang
#{
  get => #{
    description => <<"Get all the configurations of cluster, including hot and non-hot updatable items.">>,
    parameters => [
       {node, hoconsc:mk(typerefl:atom(),
          #{in => query, required => false, example => <<"emqx@127.0.0.1">>,
          desc => <<"Node's name: If you have this field defaulted, the whole cluster is return.">>})},
       {debug, hoconsc:mk(typerefl:boolean(), #{in => query, required => false,
          desc => <<"Carries debug(meta data) information, such as:line number,default value,documentation">>})}],
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

  ```erlang
  #{'emqx@127.0.0.1' => 
     #{default_password => "public",
       default_username => "admin",
       listeners =>
         [#{backlog => 512,inet6 => false,ipv6_v6only => false,
            max_connections => 512,num_acceptors => 4,port => 18083,
            protocol => http,send_timeout => 5000}],
       sample_interval => 10,token_expired_time => 3600000},
    'emqx1@127.0.0.1' => ...
  }   
  ```

- Update specific configuation without query string, will modify the configuration of all nodes in the cluster and persist it in `emqx_cluster_override.conf`. In other words, it is the configuration that keeps the cluster strongly consistent.

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

