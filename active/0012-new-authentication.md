# Better Authentication

## Change log

- 2021-05-17: @zhouzb initial draft



## Abstract

Provide more powerful authentication feature.



## Motivation

Improve the unfriendly experience of the current authentication feature. For example, the authentication order is provided but it is difficult to adjust, Mnesia authentication cannot add user credentials in batches, and all listeners must use the same authentication chain.



## Features

- Support authentication chain, support dynamic creation of authentication service, support adjustment of authentication order, support creation of multiple authentication service instances for the same database type.
- The authentication chain is bound to the gateway, and there can be multiple listeners under the same gateway.
- By default, an authentication chain bound to the default MQTT gateway is provided. Users only need to create any authentication service to use the authentication feature.
- Remove anonymous authentication, provide a global authentication switch, turn off authentication by default to allow all clients to connect.
- Mnesia supports importing user credentials from Json and CSV files.
- Enhanced authentication is no longer an independent application. Each authentication service should support enhanced authentication. Currently, it is only supported by Mnesia authentication services.
- To avoid introducing too much complexity, JWT Token authentication and database-based password-based authentication will not be compulsorily distinguished from the authentication chain.
- Support authentication of different gateways.



## Design

- The authentication plugins are merged into an authentication application, which will implement a framework to create and manage authentication chains and authentication services.

- The operation logic of the authentication chain is as follows: 1. Create an authentication chain; 2. Create an authentication service. The authentication chain that is not bound to the gateway will not be used.

- Considering that features such as authentication, authorization, rule engine, etc. will use external resources, and the connection configuration of these external resources is actually very common, so we plan to abstract the configuration of these connections into Connectors, which will provide reading and writing to external resources , monitoring, management and other functions. Multiple features can use the same Connector.

  > Connector will be designed and implemented by Liu Xinyu (@terry-xiaoyu).

- When creating an authentication service, you need to specify a valid Connector ID, and finally use the interface provided by the Connector to complete queries and other operations, such as `emqx_http_connector:request(ConnectorID, Method, Request).`

- Mnesia authentication service does not need to specify a Connector.

- All authentication service codes need to implement and export the `create/2, authenticate/3, destroy/2` functions, which are called by the framework code when services are created, authenticated, and destroyed.

- The authentication framework code will also use the `import_user_credentials/4, add_user_credential/3, delete_user_credential/3, lookup_user_credential/3` code provided by the authentication service code to complete the batch import of user credentials, add/delete/look up user credentials, etc. Currently only Mnesia authentication service support.

- The authentication service should support all fields that can be used for authentication, such as ClientID, Username, IP, Common Name, Issuer, etc., and support the simultaneous use of multiple fields and specify the use mode as `and` or `or`. By default, only Username is used as User Identity, and users need to enter the `Advanced` page to obtain other capabilities.

  > And: higher certification is required. Or: Support multiple types of equipment

- Since the table structure of Mnesia authentication service is completely defined and provided by us, the `and` that supports multiple fields will be more complicated. The original implementation supports `or` to some extent, but the experience in all aspects is not satisfactory. Therefore, we have slightly adjusted the Mnesia authentication service. An instance can only be configured with one field as the User Identity, but multiple instances can be created to achieve the effect of multiple fields `or`.

- The authentication service needs to configure the mapping relationship between the ClientInfo field and the column name of the data table, and the mapping relationship between the gateway configuration protocol field and the ClientInfo field. Taking the CoAP gateway as an example, assuming the format of QueryString is `user={username}&pass={password}`, then the CoAP gateway needs to be configured to map the user field to the username field in ClientInfo, and the pass field to map to the password field in ClientInfo. The gateway Responsible for converting the user and pass fields into the username and password in ClientInfo when the client connects. The authentication directly uses the username and password in ClientInfo for authentication, that is, the authentication does not directly deal with the gateway.

- Enhanced authentication may involve multiple round-trips of messages, and different hooks are used for simple authentication. ~~Temporarily, enhanced authentication and simple authentication can use the same chain~~. And when the enhanced authentication receives an AUTH message, the logic of the chain should no longer be followed, and it should continue to be processed by the previous authentication service.



## Declined Alternatives