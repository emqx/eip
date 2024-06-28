# Durable Shared Subscriptions

## Changelog

* 2024-05-10: @savonarola Initial draft
* 2024-06-28: @savonarola
    * Add the Agent abstraction
    * Describe the two-side communication sequence between an Agent and the SGL
    * Describe the stream reassignment algorithm
* 2025-01-08: @savonarola
    * Change the naming to contain less abbreviations and more comprehensive names
    * Extend the introductory section a bit to make the general problem clear
    * Add a section with the general layer structure
    * Updated the interaction details according to the new simpler design

## Abstract

We describe the implementation of shared subscriptions based on the concept of durable storage.

## Motivation

Since we have durable storage-based implementation for the regular subscriptions, we want to extend its advantages over the shared subscriptions. That is, mainly:
* To have messages persisted, that is, not lost regardless of the crashes or absence of consumers.
* To be able to replay messages from the past.

## Design

### General Idea

Shared subscriptions (or queues) are a feature that allows multiple consumers to consume messages from some topic filter cooperatively.

Several consumers subscribe to a special topic `$shared/GROUP_ID/TOPIC_FILTER` (or `$queue/GROUP_ID/TOPIC_FILTER` in the case of queues) and consume messages from `TOPIC_FILTER`. Each message goes to a single consumer.

With the durable backend (Durable Storage backend, DS), all messages pertain to the ordered _streams_ of messages. Streams may be read sequentially (possibly skipping some messages). Streams may be finalized (i.e., closed) and so fully consumed.

Since the streams are a means of sharding messages, the natural idea is to use the same sharding mechanism for shared subscriptions. That is, assign disjointed subsets of streams to different consumers and let them consume their streams in parallel.

We need an entity responsible for distributing such streams across consumers.
We implement such entity as a cluster-unique process called **Shared Group Leader** or simply **Leader**.

The Leader is spawned when the first consumer connects to the group subscription.

The global registration mechanism is based on the DS precondition feature, which allows the creation/deletion of message entries in the DS atomically.

Leaders' data is also stored in the DS. Note that the DS for the Leader registration and other data is completely separate from the DS for the messages.

The Leader keeps track of topics belonging to the group, their streams, and stream progress. It is the only entity that tracks the replay progress of these streams.

The consumers are persistent sessions. They connect to the Leader via the encapsulated **Agent** entity, and the Leader grants them streams to consume. Sessions consume these streams together with their proper streams but do not persist the progress. Instead, they report the progress to the Leader.

The Leader is responsible for reassigning streams to the other sessions in case a consumer session disconnects and for reassigning streams to the new consumers.

### Layer design

The high-level layers are:
* Session *Shared Subscription Handler*
* Shared Subscription *Agent*
* Shared Subscription *Borrower*
* Shared Subscription *Leader*

#### Session Shared Subscription Handler

Session Shared Subscription Handler (or simply Shared Subscription Handler) is the session-side facade for the shared subscriptions.
It is a counterpart of the module responsible for the regular (private) session subscriptions.

Session Shared Subscription
* Handles the `on_subscribe`/`on_unsubscribe` events from the session, creating/deleting subscriptions in the session's state and forwarding the requests to the Agent.
* Receives stream granting/revocation messages from the Agent and injects stream states into the session's state and the scheduler.
* Receives stream consumption progress updates and sends them to the Agent.

So, the Shared Subscription Handler knows how the session works but nothing about how the streams are obtained and managed. This knowledge is encapsulated in the **Agent** abstraction.

#### Shared Subscription Agent

The Agent is the entity that provides the interface for the Shared Subscription Handler to obtain stream granting/revocation events and reports stream consumption progress.

For the community edition, the Agent is implemented as a stub that does not perform any actions, so sessions' subscriptions and unsubscriptions have no effect.

For the enterprise edition, the Agent actually communicates with the Leaders, receives streams for consumption, and reports stream consumption progress.

Technically, the Agent itself does not have much communication logic, because it handles _all_ shared subscriptions of a single session. So its responsibility is to maintain a collection of Shared Subscription Borrowers and to forward events belonging to the particular shared subscription to the corresponding Borrower.

#### Shared Subscription Borrower

Borrower is the entity within the Agent responsible for a single shared subscription. It talks to the Leader, receives streams for subscription, and reports stream consumption progress.

It is important, that the Borrowers within the session's Agent are isolated from each other and are _not identified_ by the group ID + topic filter. In case of quick unsubscribe/subscribe sequence, there may be multiple Borrowers within the same Agent talking to the same Leader. One connecting to the Leader and the other ones finalizing the previous subscriptions.

#### Shared Subscription Leader

The Leader is the entity that is responsible for a single shared subscription group. The Leader
* Tracks and renews streams for the shared subscription's topic filter.
* Tracks the connected Borrowers.
* Assigns and revokes streams to the Borrowers.
* Receives stream consumption progress updates from the Borrowers.
* Persists the shared subscription's state (e.g. stream consumption progress).

#### Layer interaction

![general-design](./0028-assets/general-design.png)

The Shared Subscription Handler, Agent, and Borrowers are nested session-side entities: The Shared Subscription Handler encapsulates an Agent, which encapsulates a collection of Borrowers. Communication between them is done via simple function calls.

Leader resides in a separate process, so it communicates with Borrowers via completely asynchronous message-based protocol.
Note that Borrowers are the innermost entities, so these messages to and from the Leader are opaquely propagated through the Agent and Shared Subscription Handler layers.

### Protocol between Borrower and Leader

The most complicated part is the asynchronous protocol between a Borrower and a Leader. The other interactions (Agent and Borrower, Shared Subscription Handler and Agent) are mostly forwarding events and callbacks.

On the Borrower side, we have
* A state machine for the Borrower's state as a whole.
* A collection of state machines for each stream granted to the Borrower.

#### Borrower's statuses

The Borrower's statuses are the following:
* `connecting` - the Borrower is created (a client subscribed to a shared subscription or restored an existing subscription).
It is looking for a Leader periodically sending `find_leader` messages.
* `connected` - the Borrower is connected to the Leader, receiving streams (or revoke commands) and reporting progress.
* `unsubscribing` - the session unsubscribed from the shared subscription. The Borrower is waiting for consistent progress from the session, reports it, and terminates.

There are no cyclic status transitions, the statuses change as
`[new]` -> `connecting` -> `connected` -> `unsubscribing` -> `[destroyed]`

If a Borrower detects an inconsistent state (e.g., an unexpected message from the Leader), it terminates itself and asks the enclosing Agent to recreate it from scratch. The new Borrower will obtain a new identifier, and the Leader will see it as a completely new Borrower.

The Borrower has the following timers:
* In `connecting` state, there is a periodic find leader timer. It is used to reissue the `find_leader` message if the Leader is not found.
* In `connected` state, there is a periodic ping timer and a ping response timeout timer. On ping timer, a ping message is sent to the Leader. If there is no response within the ping timeout, the Borrower invalidates (stops and asks the enclosing Agent to recreate it from scratch).
* In `unsubscribing` state, there is a unsubscribe timeout timer. If within the timeout the Borrower does not receive the final consistent progress from the session, it reports incomplete progress and terminates.

### Individual stream states

Each stream has its own state. The stream state is the following:
* `granted` - the stream is granted to the Borrower.
* `revoking` - the stream is being revoked from the Borrower by the Leader.

Stream state changes are also without cyclic transitions; they are `[absent]` -> `granted` -> `revoking` -> `[absent]`.

Stream becomes `granted` when the Leader assigns it to the Borrower (a `grant` event is received).

Stream becomes `revoking` when the Leader revokes it from the Borrower (a `revoke` event is received).
On revoke, the stream is marked as `unsubscribed` in the enclosing session but still belongs to the Borrower.
The Borrower waits for the final consistent progress from the session.

The stream is removed when a `revoked` event is received from the Leader.
This means that the Leader confirms that the final progress is received.

### Messages/callbacks between the Borrower and the Leader

#### `connecting` state

From Borrower:
* `leader_wanted` — a request to find the Leader for the shared subscription.
Since the Borrower is not connected to the Leader yet, it sends this message to a node-local leader registry. The registry will find the Leader and the Leader will respond with a `leader_connect_response` message.

From Leader to Borrower:
* `leader_connect_response` — the Leader responds to the `leader_wanted` message. The response contains the Leader's id.

From the enclosing Agent/Session:
* `on_disconnect`, `on_unsubscribe` — since we have no streams, we send `disconnect` message to the Leader and terminate the Borrower.

#### `connected` and `unsubscribing` states

From Borrower:
* `ping` — a periodic ping message to keep the connection alive.
* `disconnect` — a message to disconnect from the Leader. The message contains the latest progress of all granted streams.
* `update_progress` — a message to update the progress of the stream consumption.
* `revoke_finished` — a message to notify the Leader that the stream revocation is finished.

From Leader to Borrower:
* `ping_response` — a response to the `ping` message.
* `grant` — a message that the Leader grants a stream to the Borrower.
  * in `unsubscribing` state it is ignored.
  * in `connected` state, the granted stream is added to the Borrower's stream set and an event returned to the enclosing session to install the stream.
* `revoke` — a message that the Leader revokes a stream from the Borrower.
  * in `unsubscribing` state it is ignored.
  * in `connected` state, the stream is marked as `revoking` and an event returned to the enclosing session to unsubscribe from the stream. We still keep the stream in the Borrower's stream set until the final progress is received.
* `revoked` — a message that the Leader confirms that the final progress is received.
  * in `unsubscribing` state it is ignored.
  * in `connected` state, the stream is removed from the Borrower's stream set. We respond to the Leader with `revoke_finished` message.

From the enclosing Agent/Session:
* `on_disconnect` — we send the current progress to the Leader and terminate the Borrower.
* `on_unsubscribe` — we move the Borrower to the `unsubscribing` state.
* `on_stream_progress` — we send the progress to the Leader via the `update_progress` message.

#### All state messages

`invalidate` — a message that the Leader wants to invalidate the Borrower. The Borrower terminates itself and asks the enclosing Agent to recreate it from scratch.

### Leader's logic

Leader maintains:
* The renewed set of streams for the topic filter of the shared subscription.
* The progress of each stream.
* The set of connected Borrowers.
* The assignment of streams to the Borrowers.

The stream assignment to a borrower has the following statuses:
* `granting` — the stream is being granted to the Borrower.
* `granted` — the stream is assigned to the Borrower.
* `revoking` — the stream is being revoked from the Borrower.
* `revoked` — the stream is revoked from the Borrower.

Periodically, or after some events, the Leader runs the stream reassignment process.

The stream reassignment process is the following:
* We renew the set of streams for the topic filter.
* We check the total number of streams and the registered Borrowers.
* We calculate the desired number of streams per Borrower.
* For borrowers having more streams than desired, we revoke some of its streams.
* For borrowers having fewer streams than desired, we grant some free streams (not assigned to any Borrower).

The granting process is the following:
* We create the stream assignment `stream <-> borrower_id` in the `granting` status.
* We send the `grant` message to the Borrower together with the stream and its progress.
* We resend the `grant` message on timeout.
* After the `grant` message is received by the Borrower it starts to send stream progress.
* On receiving the progress, we consider the stream granted and update the stream assignment status to `granted`.

The revoking process is the following:
* We move the stream assignment `stream <-> borrower_id` in the `revoking` status
* We send the `revoke` message to the Borrower.
* We resend the `revoke` message on timeout.
* After the `revoke` message is received by the Borrower, it starts to finalize the stream consumption.
* When we receive the progress from the Borrower with the stream final progress, we move the stream assignment status to `revoked`.
* We send the `revoked` message to the Borrower.
* We resend the `revoked` message on timeout.
* After the `revoked` message is received by the Borrower, it deletes all the stream-related data and responds with `revoke_finished` message.
* On receiving the `revoke_finished` message, the Leader deletes the stream assignment.

### Configuration Changes

### Backwards Compatibility

One of the main difficulties is the coexistence of durable shared subscriptions with regular shared subscriptions. For example, consuming messages by an in-memory session from a shared group backed by durable storage.

### Document Changes

### Testing Suggestions

### Declined Alternatives

Previous PoC implementation appeared to be too complex both for implementation and for understanding.
* There was not one-to-one Borrower <-> Subscription correspondence. That made resubscribing complicated and led to much complex logic in the Shared Subscription Handler.
* Consequently, the Borrowers handled invalidation and resubscription themselves. Their state machine was larger and had cycles.
* The Borrowers and the Leader did not have separate communication levels (connection maintenance vs. stream assignment and progress reporting). Instead, the Leader and the Borrower exchanged versioned sets of streams, which also appeared to be too complex.

