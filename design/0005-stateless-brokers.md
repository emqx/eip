# Stateless Brokers in EMQ X v5.0

```
Author: Shawn <liuxy@emqx.io>
Status: Draft
Type: Design
Created: 2020-10-27
EMQ X Version: 5.0
Post-History:
```

## Abstract

This proposal gives a suggestion that breaks the emqx to a few node types. We could specify the node type when starting an emqx node. By default all types will be included in one node if no argument is given.

## Motivation

To improve the scalability of emqx, and allow the broker being able to elastic scales according to the number of concurrent connections.
The goal is to scale the broker out to thousands of nodes.

## Rationale

The distributed system improves the scalability by adding more nodes to handle the growing amount of requests, but it also introduces more complexities, especially when we have to maintain states among multiple nodes.

For availability we need to main multiple replicas of the state, to avoid single point of failure or to improve the performance of read operations; For consistency we need to keep the replicas synchronized, to make the entire system working more like a single node.

The things get more complicated if the state/data has to be partitioned for load balancing or scalability (i.e. partition a large data set). We need a mechanism to mapping requests to the nodes which maintain the corresponding data partitions.

And transactions also become a challenge on distributed nodes. For example, to globally create session for a client-id, some synchronization mechanism like distributed locking might be necessary, which significantly affect the performance of session creation.

All the above problems limit the scalability of the system. By breaking the system into different node types, we move the difficult work to the logic nodes and make the broker nodes stateless. This is a approach that improve the scalability by making part of the system linear scalable.

## Design

### Architecture

This proposal suggests breaking the emqx into 3 node types: The (stateless) broker nodes, the (stateful) logic nodes and the centralized config-service node:

- Broker nodes are front-end nodes that handle the connections and do the parsing work. With this handling thousands of millions of connections are fairly easy, because adding/removing a broker node won't have to re-distribute the data partitions (shards), nor copying the replicas to the new node. Considering it is a common case that the number of connections may grow quickly in a short period of time, this is a nice feature and is good for deploying on infrastructures like AWS EC2. Dropping one or more broker nodes is also simple without worrying about any data loss.

- All the configs like rules (emqx-rule-engine) and plugin settings are only managed in the centralized config service, so that we don't have to handle the consistency of configs between broker nodes. And the broker node don't have to persistent the configs, facilitating deployment in docker containers as no persistent volumes are necessary.

- All other stateful processes such as session management, and any data set that needs to be partitioned such as the route table and trie table, are handled by logic nodes.

```
                     +------------------------+
                     |                        |
                     |     Config Service     |
                     |                        |
                     +------------------------+

[Centralized Config Service]
---------------------------------+------------------------------------
[Broker Nodes]                   | [Logic Nodes]
                                 |
    +---+           +--------+   |   +-------+
    |   |           |        |   |   |       |
    |   |     +-----> Broker |   |   | Logic |
    |   |     |     |        |   |   |       |
    |   |     |     +--------+   |   +-------+
    | L |     |                  |
    |   |     |     +--------+   |
    |   |     |     |        |   |
    |   +-----------> Broker |   |
    |   |     |     |        |   |
    |   |     |     +--------+   |
    | B |     |                  |
    |   |     |     +--------+   |   +-------+
    |   |     |     |        |   |   |       |
    |   |     +-----> Broker |   |   | Logic |
    |   |           |        |   |   |       |
    +---+           +--------+   |   +-------+
                                 |
                                 |
                                 +
```

### Cluster and communication between nodes

There's no clustering for broker nodes. In other word, the broker nodes are completely decentralized and consist a peer-to-peer (p2p) distributed network.

Each broker node establishes one communication channel to each of the logic node. The channel can be secured links over TLS so that it is possible to deploy logic nodes and broker nodes in different data centers.

The logic nodes consist a fully meshed distributed network.

```
+----------+
|  Logic   |
|          |
| [server] |
+----^-----+
     | RPC
+----v-----+
| [client] |
|          |
|  Broker  |
+----------+
```

As shown above, the connections between logic and broker nodes are established by RPC channel. `gen_rpc` is a nice choice.

The benefit of this architecture is that we could setup hundreds of thousands of broker nodes without needing to keep a global view of the nodes in each broker. Adding/Removing a broker is pretty simple because we don't have to establish/disconnect distribution links to other brokers. The drawback is that messages forwarding between brokers have to go through a logic node as a proxy. But considering we may maintain message queues in the logic nodes is case of persistent session, that makes sense because if we don't use logic nodes as proxies, we would have had to pass the messages to the logic nodes for message queuing anyway. Message passing between the broker nodes and logic nodes can be batched to enhance the throughput.

Another benefit of this approach is that we could setup channels between multiple geographically deployed logic clusters to enable the cross data-center message passing. The networks between broker nodes from different data centers don't have to be connected to publish a message. It's nice as there are probably much more broker nodes than logic nodes, so that setting up connections between logic nodes is easier than do that between broker nodes.

### Mnesia/ETS Tables

- Tables in Broker Nodes

    emqx_coap

    |           Name            | Type |                Structure                |     |
    | ------------------------- | ---- | --------------------------------------- | --- |
    | coap_topic                | local-ram | {Topic, MaxAge, CT, Payload, MilliSec)} |     |
    | coap_response_process     | local-ram | {Name, Pid, MonitorRef}                 |     |
    | coap_response_process_ref | local-ram | {MonitorRef, Name, Pid}                 |     |

    emqx_lwm2m

    |            Name             | Type |       Structure        |     |
    | --------------------------- | ---- | ---------------------- | --- |
    | lwm2m_object_def_tab        | local-ram | {ObjectId, ObjectXml}  |     |
    | lwm2m_object_name_to_id_tab | local-ram | {NameBinary, ObjectId} |     |
    | lwm2m_clients **newly added** | local-ram | {EndpointName, ...} |     |

    emqx_sn

    |            Name             | Type |       Structure        |     |
    | --------------------------- | ---- | ---------------------- | --- |
    | emqx_sn_registry_<Variable> | local-ram | {TopicId, TopicName}  |     |

    emqx_rule_engine

    |            Name             | Type |      Structure       |                                            |
    | --------------------------- | ---- | -------------------- | ------------------------------------------ |
    | emqx_rule_action | local-ram  | {action, Name, Category, For, App, Types, Module, OnCreate, OnDestroy, Title, Descr} | Actions |
    | emqx_action_instance | local-ram | {ID, Name, Fallbacks, Args}  | Action Instances  |
    | emqx_action_instance_params | local-ram | {ID, Params, Apply}  | Anonymous Func Table for Action instances  |
    | emqx_resource_type | local-ram  | {resource_type, Name, Provider, ParamSpec, OnCreate, OnStatus, OnDestroy, Title, Descr} | Resources |
    | emqx_resource | local-ram | {ID, Type, Config, CreateAt, Descr} | Resource instances |
    | emqx_resource_params | local-ram | {ID, Params, Status} | Dynamic param/status Table for resource instances |

    emqx_core

    |            Name             | Type |      Structure  | |
    | --------------------------- | ---- | -------------------- | --- |
    | emqx_suboption | local-ram | {SubPid, Topic} -> SubOption  |  |
    | emqx_subscriber | local-ram | Topic -> SubPid  |   |
    | emqx_subscription | local-ram | SubPid -> Topic  |   |

    |            Name             | Type |      Structure  | |
    | --------------------------- | ---- | -------------------- | --- |
    | emqx_broker_helper | local-ram | {shards, Integer}  |  |
    | emqx_subid | local-ram | {SubId, SubPid}  |  |
    | emqx_submon | local-ram | {SubPid, SubId}  |  |
    | emqx_subseq | local-ram | Integer  | Topic Subscribed Counter |

    |            Name             | Type |      Structure  | |
    | --------------------------- | ---- | -------------------- | --- |
    | emqx_channel | local-ram | {ClientId, ChanPid}  |  |
    | emqx_channel_conn | local-ram | {{ClientId,Pid}, ConnMod}  |  |
    | emqx_channel_info | local-ram | {{ClientId,Pid}, Info} |  |

    |            Name             | Type |      Structure  | |
    | --------------------------- | ---- | -------------------- | --- |
    | emqx_command | local-ram | {{Seq, Cmd}, MF, Opts}  |  |
    | emqx_flapping| local-ram | {Clientid, PeerHost, StartedAt, DetetCount}  |  |
    | emqx_hooks| local-ram | {Name, Callbacks}  |  |
    | emqx_metrics | local-ram | {Name, Type, Idx} |  |
    | emqx_mod_topic_metrics | local-ram | {Topic, CounterRef} |  |
    | emqx_shared_subscriber | local-ram | {{Group, Topic}, SubPid} |  |
    | emqx_alive_shared_subscribers | local-ram | SubPid |  |
    | emqx_stats | local-ram | [{Key, Counter}] |  |

    |            Name             | Type |      Structure  | |
    | --------------------------- | ---- | -------------------- | --- |
    | emqx_active_alarm | local-ram  | {activated_alarm, Name, Details, Message, ActivateAt} |  |
    | emqx_deactive_alarm | local-ram  | {deactivated_alarm, ActivateAt, Name, Details, Message, DeactivateAt} |  |

- Tables in Logic Nodes

    |            Name             | Type |      Structure  | |
    | --------------------------- | ---- | -------------------- | --- |
    | emqx_channel_registry |  global-ram | {channel,ClientID,Pid} |  |
    | emqx_route |  global-ram | {route,Topic,Node} |  |
    | emqx_routing_node |  global-ram | {emqx_routing_node, Node, _} |  |
    | emqx_shared_subscription |  global-ram | {emqx_shared_subscription,GroupName,Topic,SubPid} |  |
    | emqx_trie |  global-ram | {trie,Edge,TrieNodeId} |  |
    | emqx_trie_node |  global-ram | {trie_node, TrieNodeId, EdgeCount, Topic, Flags}  |  |
    | emqx_mod_delayed |  global-disc | {delayed_message, Key, Msg}  |  |

- Tables in Config Service

    |            Name             | Type |       Structure        |     |
    | --------------------------- | ---- | ---------------------- | --- |
    | emqx_psk_file | local-ram  | {psk_id :: binary(), psk_str :: binary()}  |     |
    | emqx_banned | local-ram  | {banned, Who, By, Reason, At, Until}  |    |
    | emqx_telemetry | global-disc  | {telemetry, Id, UUID, Enabled} |  |
    | emqx_rule | global-disc  | {rule, ID, For, RawSQL, IsForeach, Fields, DoEach, InCase, Conditions, OnActionFailed, Actions, Enabled, Descr} |  |
    | mqtt_admin | global-disc  | {mqtt_amdin, Username, Password, Tags} |  |
    | mqtt_app | global-disc  | {mqtt_app, Id, Secret, Name, Desc, Status, Expired} |  |
    | emqx_user | global-disc  | {emqx_user, Login, Password, IsSuperUser} |  |
    | emqx_acl | global-disc  | {emqx_acl, Login, Topic, Action, Allow} |  |
    | scram_auth | global-disc  | {scram_auth, Username, StoredKey, ServerKey, Salt, IterationCount} |  |
    | emqx_retainer | global-disc  | {retained, Topic, Msg, ExpiryTime} |  |

### Handling of Subscriptions, Routing and Publishing

The subscription info is the data related to the mapping from topics to subscribers. The subscription info may involve the following tables:

- the subscriber table:
  Maintains the mapping from TopicFilter -> SubPid

- the trie table:
  Used for matching a TopicName to all the possible wildcard topic-filters in the system.

- the route table:
  Maintains the mapping from TopicFilter -> BrokerNodeName.
  Used for effectively forwarding a message to the broker nodes that 'has' a TopicFilter without needing to broadcast.

The brokers manages the MQTT clients and their subscriptions within the single node. On the other hand, the brokers themselves act as the clients of the logic nodes. From this point of view the logic nodes are the "broker" of the broker nodes: they manage the connections from brokers and their subscriptions.

The subscriber tables only reside in the broker nodes, and the route tables only reside in the logic nodes. From the perspective of logic nodes, the route table is actually the subscriber table for the broker nodes.

And there can be two types of trie tables: the trie table on broker and the ones on logic nodes.

- The trie table on a broker node is for the wildcard topic-filters only in that broker node.

- The trie table on logic nodes stores the topic trie which contains all of the topic-filters subscribed by the broker nodes. We have to replicate the global trie on each of the logic nodes, i.e. each logic node have a full copy of the trie table. We do so to allow a publish with topic "t/1" being able to forwarded to the subscriber which subscribes to "t/#".

The overall design goal is to make sure that:

1. Clients that are connected to the same broker are able to communicate with each other without needing to forward messages to logic nodes.

2. Clients that are connected to different brokers are able to communicate with each other by using a logic node as the proxy.

3. The persistent session are stored in the logic node, but for non-persistent sessions, it should be stored in broker nodes for performance purpose.

4. Route table and other data or states should be partitioned among logic nodes if possible.

5. We should consider performance of publishing messages over subscribing topics and establishing connections.

```
+---------+   +---------+   +---------+
| LogicN1 |   | LogicN2 |   | LogicN3 |
|   t/1   |   |   t/2   |   |   t/#   |
+----^----+   +----^----+   +----^----+
     |             |             |
     +-------------|-------------+
                   |
              +----+----+       [subscribe]
              | Brokers | <--- t/1, t/2, t/#
              +---------+
```

The above graph illustrated the process of partitioning the route table to different logic nodes, by the hashing key of the topic. This is important as the total topic number is probably proportional to the number of subscribers, like "c/client1", "c/client2", etc. It becomes very hard to scale the logic nodes if the route table is fully replicated and is too large on each node.

When a client subscribes a topic-filter, it updates the subscriber table and the trie table locally on the broker node it connected to, and then the broker subscribes the topic-filter to one of the logic nodes by the hash of the topic. The logic node first broadcast the subscription operation to all other logic nodes, and then update the route table and its tire table locally. All other logic nodes update their trie table respectively after they received the replication of the subscription operation.

A possible optimization is that we can reduce the topic-filters in the route table by removing the overlapping topic-filters subscribed by the same broker node. For example, we could only store "t/# -> b1" in the route table if the broker b1 subscribes "t/1", "t/2", "t/+" and "t/#".

When a client publishes a message, the broker first dispatch the messages to all the subscribers connected on local node, then it sends the message to the logic node and let the node to relay the message to other brokers. The broker selects the logic node by the hash of the topic, this is also how we sharding the route table: the logic node who owns the routing info for a topic also handles the messages with the same topic. Another possible solution is that let the broker request the routing info of a topic from the logic node, and then send the message to the target broker by itself. But I prefer the former as it doesn't require brokers know each other, especially they may be located in different data centers. Sending messages to logic nodes is also good for persisting sessions on it.

The wildcard topic-filter and their matched ordinary topic-filters might not be assigned on the some logic node. So for passing messages to wildcard topics there're 2 solution:

#### Solution1: Forward message to right logic node for wildcard topic-filters

A logic node relays messages by looking up the route table, but for relaying to all available wildcard topic-filters, it has to lookup the topic trie. The node then forwards the message to the right logic node if the topic has a matched wildcard topic-filter:

```

     +----------forward----------+
     |                           |
     |                           |
+----+----+   +---------+   +----v----+
| LogicN1 |   | LogicN2 |   | LogicN3 |
|   t/1   |   |   t/2   |   |   t/#   |
+----^----+   +----^----+   +----^----+
     |
     |
     |
+----+----+   [publish]
| Broker1 | <------ t/1
+---------+

```

For persistent sessions, the messages are stored in LogicN3 in the message queue with "t/#" as the key. After the client re-connected it restores the message queue for "t/#" from LogicN3.

The best condition is that there's no wildcard topic-filters, in which case no inter-logic-node message forwarding is needed. Or if we can assign the wildcard topic-filters to the same node with all the topic-filters that can be matched to them, it's also not necessary to forwarding messages to another logic node. e.g. assign "t/1", "t/2" and "t/#" to the same node. But this requires the user has designed the topics carefully.

e.g. If the topics in an instant messaging system look like as follows:

```
c/<group-name>/<client-id>/profile
c/<group-name>/<client-id>/chat
c/<group-name>/<client-id>/status
c/<group-name>/<client-id>/#
```

Then it would be nice if we could assign all the topics prefixed by `c/<group-name>/<client-id>/` to the same logic node.
The rule of hash key in this case is: "c/{2}{3}", where "{2}" and "{3}" are the second and third level of the topic respectively.

Another example:

```
s/<sensor-id>/status
s/<sensor-id>/notify
s/+/status
s/+/notify
```

The the rule of the hash key would be: "s/{3}".

Of course this optimization only makes sense when the topics are well designed so we could evenly partition them among logic nodes by some rules.

#### Solution1: Replicate the route table

Another way is to replicate the route table to all of the logic nodes, so that the LogicN1 don't have to forward the message to the LogicN3, as it has the full routing info about where the message should go.

```
+---------+     +---------+     +---------+
| LogicN1 |     | LogicN3 |     | LogicN2 |
|   t/1   |     |   t/#   |     |   t/2   |
+----^----+     +----^----+     +----^----+
     |
     |
+----+----+   [publish]
| Broker1 | <------ t/1
+---------+

```

In this way we don't have to forwarding the message with topic = 't/1' to LogicN3, saves the overhead of the extra RPC. As an optimization, we only need to replicate the routing info for the wildcard topics.

For persistent sessions, we should store the messages in message queues on LogicN1 and LogicN2 with "t/1" and "t/2" as the keys respectively. After the client re-connected it restores its message queue for 't/#' from both LogicN1 and LogicN2. The problem here is that there are probably multiple message queues for "t/#" on different logic nodes, so we have to save this info on LogicN3 like this:

```
't/#' -> [
    {LogicN1, 't/1'},
    {LogicN2, 't/2'}
]
```

For details of handling of persistent/temporary sessions, see section `Session Management`.

The important thing in this approach is, we need to replicate the subscribe operations about wildcard topic-filters among the logic nodes.

This way we enhanced the performance of publishing messages at the cost of the memory footprint for wildcard subscriptions. I prefer this solution as the trie table cannot be partitioned even in the first solution, if there're too many wildcard topics, the trie table will be large on each logic node.

### Session Management

The session can be temporary or persistent, defined by the `Session Expiry Interval`. The session consists of:

- The session state:

  ETS Table: session_state

  ```
  client: "c1"  ## the key of the table
  subscriptions: [{"t/1", qos2}, {"t/2", qos0}]
  subids: [1: "t/1", 2: "t/2"]
  will_msg: ""
  will_delay_internal: ""
  session_expiry_interval: 2h
  ```

- The message queue that is pending to be sent to the client:

  ETS Table: message_queue

  ```
  key: {client: "c1", topic: "t/1", qos: 2}
  msg_q: [5:"okay", 4:"good job", 3:"nice", 2:"great", 1:"hello"]
  ```

- The inflight queue the has been sent to the client but not ACKed:

  ETS Table: inflight_queue

  ```
  key: {client: "c1", topic: "t/1", qos: 2}
  inflight: [2:"b", 1:"a"]
  ```

- The QoS2 message received but not completed:

  ETS Table: incomplete_qos2_msgs

  ```
  key: {client: "c1", topic: "t/1"}
  msgs: [msg1, msg2]
  ```

I split a session to serval ETS tables here. The session_state is always stored in one of the logic tables, no matter it is a persistent session or not. The session state of a client will be stored to the logic node selected by the hash of ClientId. We keep session state in the logic node because if we keep the (persistent) session state in the broker, we have to takeover the session when the same client re-connected from another broker node. And this unique session state is good for solving the conflict when multiple clients try to create sessions using the same ClientId.

We also store a copy of the message queues and inflight queues for the persistent session in logic nodes, as we have to keep a long-lived state and messages for the client, without worrying about the creation/destroy of the broker nodes.

The other tables are only necessary when the session is persistent, and they are only located in the logic nodes.

The message queues and inflight queues are maintained by the MQTT connection process located in the broker nodes, we call it "active" message queue or "active" inflight queue. The copy of the queues are created/updated while the messages are passing through the logic nodes. When the persistent client subscribes a topic, the broker also subscribes the topic-filter to the logic nodes with a "persistent" flag. So if a PUBLISH message comes, the message will then be queued in the logic node if the message is matched to a persistent topic-filter:

The subscription operation to a wildcard topic-filter that would be replicated to all of the logic nodes looks like:

```
           [sub]           [sub]
+---------+     +---------+     +---------+
| LogicN1 <-----+ LogicN3 +-----> LogicN2 |
|         |     |   t/#   |     |         |
+----^----+     +----^----+     +----^----+
                     |
                     | [sub]
                +----+----+   [sub]
                | Broker1 | <-------- {client:"c1", topic:"t/#", qos:"2", persist="2h"}
                +---------+
```

The subscription operation to a ordinary topic-filter will goes directly to the select logic node by hash of the topic.

### Retained Messages

The retained messages are stored in logic nodes and also partitioned by topic like the persistent message queues. Unlike the retained message queue, only the latest retained message will be stored on a specific topic. When a client subscribes to the topic-filter, the retained message will be sent to the client.

### State Management of Other Protocols

#### LwM2M

LwM2M is a M2M protocol based on CoAP and it is more and more popular in low battery device solutions, especially in the NB-IoT network.

A client in LwM2M protocol is identified by the peername (source IPAddress and source port), but in practical the IP and port are probably changed frequently, so in most cases we use endpoint-name as the identifier of a client.

LwM2M have no session but it do have a state that lasts for some period of time defined by "lifetime" in the protocol, if a client with the same endpoint-name connected again within the lifetime, no matter on which broker node, the state should be able to restored.

The LwM2M state consists of:

1. The messages pending to be sent to the client but the client is in the sleep state.

2. The CoAP tokens of messages.

The LwM2M state is maintained in the LwM2M channel process, and there's also a copy in the logic node. The logic node is selected by the hash of endpoint-name.

```
+---------+     +---------+     +---------+
| LogicN1 |     | LogicN3 |     | LogicN2 |
|   c1    |     |   c2    |     |   c3    |
+----^----+     +----^----+     +----^----+
     |               |               |
     +---------------+---------------+
                     |
                +----------+    REGISTER
                |  Broker  | <----------- c1,c2,c3
                | c1,c2,c3 |
                +----------+
```

Every "NOTIFY" message sent from the device will also go to their state in the logic nodes. The copy of the state in logic node works like the "shadow" process of the state running in the broker.

### Presence Notifications

Presence notifications are sent by the session/state from the logic node:

When the session/state is created, the logic node invokes the callback functions in plugins which may send out a "client_online" message to the user's application server.

When the session/state is terminated, the logic node invokes the callback functions in plugins which may send out a "client_off" message.

The hooks "client.connected" and "client.disconnected" are not good for sending out this kind of notifications, as the might be more than one competing connections using the same clientid/endpoint-name. There will be eventually only one connection left in the system, but it hard to control the order of the "connected" and "disconnected" notification if they are sent from different broker nodes.

### Start EMQ X without specifying node types

The broker and logic node type are in the same code base, we can specify the node type when starting an emqx node.

If we start an emqx without any argument, it has both capabilities of broker and logic node:

```
emqx start
```

The clients can connect to this node, and all the sessions/states are also saved among these nodes.

```
        +--------------------+
  emqx1 |          emqx2     |     emqx3
+-------+-+     +---------+  |  +---------+
| LogicN1 <--+  | LogicN2 |  |  | LogicN3 |
|         |  |  |         |  |  |         |
| Broker1 |  +--+ Broker2 |  +->+ Broker3 |
+---------+     +----^----+     +---------+
                     |
                     +---- publish (msg1,msg2,msg3)
```

To start an emqx node as broker only, we have to specify the node name of logic node:

```
emqx start --logic-node="emqx@192.168.0.120,emqx@192.168.0.121"
```

This way the "emqx@192.168.0.120" and "emqx@192.168.0.121" should be started with logic capabilities.

## References
