# Remove Anonymous Authentication

## Change log

- 2021-04-13: @zhouzb Initial draft

## Abstract

Remove anonymous authentication. A new authentication function switch is added to meet the requirement of allowing all devices to be connected in the initial state.

## Motivation

The logic of Anonymous Authentication is unreasonable and can easily cause misunderstanding. For example, the user has added an authentication data source. Since anonymous authentication is enabled by default, the user can still successfully connect using the wrong username and password. Secondly, even if the user specifies a username and password, anonymous authentication will take effect, which is a wrong behavior.

## Design

- Remove anonymous authentication function

- By providing the authentication function switch and it is turned off by default, all devices can be connected in the initial state. Once the authentication function is enabled or the authentication data source is added, the username and password must be carried when the device is connected.

- If there is a valid authentication data source or authentication chain when the authentication function is turned off, Dashboard needs to give sufficient prompts to inform the risk.

#### 1. Why add authentication function switch?

In theory, when no authentication data source is added, it can be equivalent to no authentication, that is, all devices can be connected. However, there are situations where users find that they can connect even if they specify the wrong username and password, which may cause misunderstanding. At the same time, if all devices can be connected without adding any authentication data source, **then the effect of adding the first authentication data source is to change any device can be connected to only some devices can be connected**, and the role of all subsequent authentication data sources is to allow more devices to be connected. This makes the act of adding an authentication data source produce different effects in different scenarios.

Adding an authentication function switch can solve this problem. This switch is responsible for the state switching of **Allow all devices to access** and **Reject all devices to access**. Then the effect of adding a authentication data source will remain the same in all situations.

#### 2. Why remove anonymous authentication?

Anonymous authentication lacks a clear user scenario. I don't think that users will perform this operation on a certain listener in a production environment, exposing the Broker to risk. In other words, authentication and "anonymous authentication" are basically completely mutually exclusive in a production environment. In fact, we did not originally support the temporary enablement of anonymous authentication. The listener needs to be restarted after modifying the anonymous authentication configuration items. The user will not spend a lot of time in the production environment just to allow his debugging client to temporarily connect.

Therefore, the possible use environment of anonymous authentication is only left in the testing phase. So even in the test environment, you really need to consider the user’s debugging needs. Obviously, there will be two scenarios where the username and password are not carried and the wrong user name and password are carried. Anonymous authentication can only take care of one of them. It is better to turn off the authentication function directly. This way all clients can connect.

#### 3. Allow some listeners to close or skip authentication

The authentication on some listeners does not make much sense, such as listeners that enable SSL/TLS mutual authentication and listeners that only accept intranet connections. Therefore, some listeners should be allowed to close or skip authentication. In fact, there is a `bypass_auth_plugins` configuration item to provide this capability. Of course, maybe we should change it to a better name.

## Configuration Changes

Need to add an authentication function switch configuration item that supports hot configuration. Others are not clear yet.

## Backwards Compatibility

Not backward compatible.

## Document Changes

## Testing Suggestions

The test of this change will be completed through test cases.

## Declined Alternatives




