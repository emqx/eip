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
    |   |     +---->+ Broker |   |   | Logic |
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

The benefit of this architecture is that we could setup hundreds of thousands of broker nodes without needing to keep a global view of the nodes in each broker. Adding/Removing a broker is pretty simple because we don't have to establish/disconnect distribution links to other brokers. The drawback is that messages forwarding between brokers have to go through a logic node as a proxy. But considering we must maintain message queues in the logic nodes, that makes sense because if we don't use logic nodes as proxies, we would have had to pass the messages to the logic nodes for message queuing anyway.

Another benefit of this approach is that we could setup channels between multiple geographically deployed logic clusters to enable the cross data-center message passing. The networks between broker nodes from different data centers don't have to be connected to publish a message. It's nice as there are probably much more broker nodes than logic nodes, setting up connections between logic nodes is easier than do that between broker nodes.

### Mnesia/ETS Tables

### Handling of Subscriptions

### Routing and Publishing

### Session Management

### State Management of Other Protocols

#### LwM2M

### Start EMQ X without specifying node types

## References
