# Use FoundationDB as storage layer of EMQX

## Abstract
FoundationDB is a powerful, distributed, ordered key-value storage engine which provides guarantee of ACID.
It is a perfect choice to store all the data needed to persistent in EMQX. And the good scalability of FoundationDB will help us to build a large cluster of EMQ so that we can provide shared cloud service to customers.

## Data need to be stored
* meta data in emqx
* persistent session and messages
* emqx route info

### persistent session and messages
As the [persisten session design](./0011-persistent-sessions.md) mentioned, we should find a storage backend for messages.
FoundationDB is a perfect choice because of its scalability. But we need to provide an easy-use way to build our persistent session data model on it.

The key property of session messages is that the messages are queued. 
So each `sessionId` should bind to a `queue` data model on FDB which contains orderd messages.
We should fetch messages in order.
We should support batch insert and range delete for performance need. 
We should overcome the FoundationDB value size limitation.

So we can provide a [queue data model](https://github.com/wfnuser/CometDB) to solve the problem.