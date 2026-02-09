# A2A Registry as a Standard Feature

## Changelog

* 2026-02-03: @zmstone/codex Initial draft
* 2026-02-03: @codex Align with A2A-over-MQTT transport profile and tighten EMQX wording
* 2026-02-05: @codex Add trusted JKU policy for runtime signed messages
* 2026-02-05: @codex Simplify to trusted-JKU-list-or-permissive model
* 2026-02-05: @codex Add Dashboard UI MVP scope (simple CRUD-first design)
* 2026-02-05: @codex Add broker-managed status field and remove cleanup flow
* 2026-02-06: @codex Move broker-managed status to MQTT v5 User Properties and align QoS defaults
* 2026-02-09: @codex Align registry guidance with latest A2A-over-MQTT client interop, shared pool dispatch, and security profile updates

## Abstract

This proposal introduces an A2A Registry feature for EMQX that enables
autonomous AI agents to discover and collaborate through a standardized,
event-driven MQTT 5.0 mechanism. The registry uses retained Agent Cards on
A2A-defined discovery topics and aligns with the A2A-over-MQTT transport profile, including
topic path conventions, MQTT 5 properties, JSON-RPC payload guidance, and
security metadata for public-key-based trust, plus optional end-to-end payload
protection for untrusted broker environments.
The feature improves user experience for both MQTT clients (agents) and system
administrators through CLI and Dashboard management tools while preserving native
MQTT workflows. Agents can self-register by publishing retained messages, and
administrators can inspect and manage entries through EMQX interfaces. This
feature addresses scalable agent discovery and avoids N-squared point-to-point
integration complexity in multi-agent systems, while remaining compatible with
existing MQTT deployments.

## Terminology and Profiles

- **A2A-over-MQTT transport profile**: The normative transport binding that defines topic model, MQTT 5 properties, and requester/responder behavior.
- **Discovery topic profile**: The subset of the transport profile that defines retained Agent Card discovery topics and delivery semantics.
- **Security profile**: An optional mode activated by `a2a-security-profile` that adds extra requirements (for example `ubsp-v1`).
- When this document says "profile" without qualification, it refers to one of the above. Operational settings use terms like **feature**, **policy**, or **defaults**.

## JSON-RPC Context (Coarse Mapping)

This registry aligns with the A2A-over-MQTT transport profile, which uses JSON-RPC **2.0** payloads by default.

- **Why JSON-RPC 2.0?**
  - It is the A2A request/response envelope and is already used by the core A2A protocol.
  - It provides a stable method/params/result/error structure across HTTP and MQTT bindings.

- **How JSON-RPC maps to MQTT:**
  - **JSON-RPC `id`**: application-level correlation inside the payload. It is distinct from MQTT `Correlation Data`.
  - **MQTT `Correlation Data`**: transport-level correlation for request/reply routing. It is REQUIRED on MQTT requests and MUST be echoed on replies.
  - **JSON-RPC `method`**: the A2A operation name (for example `tasks/send`, `tasks/get`, `tasks/cancel`). It is not the same as an Agent Skill.
  - **Agent Skills**: discovery metadata describing what an agent can do. Skills can influence client routing decisions but do not change the JSON-RPC method name.
  - **Agent Card `protocolVersion`**: the A2A protocol version exposed by the agent, not the JSON-RPC version.

In short: JSON-RPC 2.0 is the payload envelope, MQTT properties handle transport correlation, and Agent Skills are discovery hints.

## Motivation

As the industry transitions toward autonomous, goal-directed AI agents, the
requirement for agents to discover, communicate, and collaborate across
heterogeneous environments has become paramount. Current agent-to-agent
protocols rely on synchronous HTTP/gRPC connections, creating a geometric
progression of complexity (N-squared problem) as the number of agents
increases. This makes enterprise-scale deployments with hundreds or thousands
of specialized agents operationally unsustainable.

Event-driven architectures using MQTT 5.0 are emerging as the preferred
transport layer for agentic AI systems. Key industry players (HiveMQ, Solace,
EMQX) are converging on retained messages as the mechanism for agent discovery,
as evidenced by proposals for "Agent Cards" published to discovery topics with
the RETAIN flag.

Currently, EMQX supports retained messages, but there is no standardized,
user-friendly mechanism for:
1. Agents to register themselves with metadata (capabilities, skills,
   authentication requirements)
2. Agents to discover other agents dynamically
3. Administrators to view, search, filter, and manage registered agents
4. Clear online/offline visibility for registered agents
5. Validation and schema enforcement for agent registration data

Without this feature, developers must build custom discovery mechanisms on top
of raw retained messages, leading to inconsistent implementations, security
gaps, and operational overhead. Providing A2A Registry as a standard EMQX
feature reduces integration cost while maintaining backward compatibility with
existing MQTT infrastructure.

## Design

### Architecture Overview

The A2A Registry feature builds on EMQX's existing retained message
capabilities, adding a structured layer of management, validation, and
user-facing interfaces. The registry maintains agent metadata in retained
messages while providing enhanced functionality through:

1. **A2A Discovery Topic Profile**: Agent Cards are stored as retained messages on
   standardized A2A discovery topics
2. **Registry Service**: A new internal service that indexes and validates
   registrations and keeps query state in sync with retained messages
3. **Admin Interfaces**: CLI commands and Dashboard UI for registry management
4. **Automatic Lifecycle Reflection**: Broker-managed status attached via MQTT
   v5 User Properties (`a2a-status`, `a2a-status-source`) when forwarding
   discovery messages
5. **Security Metadata**: Agent Cards include public key / JWKS metadata for
   optional message signing and encryption policies
6. **Interop Alignment**: Client behavior follows the A2A-over-MQTT profile,
   including shared pool dispatch, binary artifact mode, and optional
   untrusted-broker security profile (`ubsp-v1`)

### Topic Structure

Following the A2A-over-MQTT transport profile, the registry uses this discovery topic
hierarchy:

```
a2a/v1/discovery/{org_id}/{unit_id}/{agent_id}
```

Where:
- `a2a/v1/discovery`: A2A discovery prefix
- `{org_id}`: Organization or trust domain identifier (e.g., reverse DNS:
  `com.example`)
- `{unit_id}`: Business unit or deployment segment identifier
- `{agent_id}`: Unique identifier for the agent instance

Identifier constraints (per A2A-over-MQTT profile):
- `org_id`, `unit_id`, `agent_id` **MUST** match `^[A-Za-z0-9._]+$`
- IDs **MUST NOT** contain `/`, `+`, `#`, whitespace, or other characters

Recommended MQTT identity mapping:
- Client ID or Username format: `{org_id}/{unit_id}/{agent_id}` (do not include `/` in the IDs)
- This enables simple conventional ACL patterns aligned with A2A topic paths.

In addition to discovery topics, the Agent Card endpoint fields SHOULD point to
the standardized interaction path:

```
a2a/v1/{method}/{org_id}/{unit_id}/{agent_id}
```

Where `{method}` is typically one of `request`, `reply`, or `event`.
For flexibility, EMQX allows configurable prefixes, but the default topic model is
the standardized A2A topic model above.

Agents MAY also be discovered via HTTP well-known endpoints defined by core A2A
conventions. MQTT-discovered cards remain authoritative for MQTT routing.

### Agent Card Schema

An Agent Card is a JSON document conforming to the A2A Agent Card specification
with MQTT extensions for security:

```json
{
  "name": "IoT Operations Agent",
  "description": "Monitors factory telemetry and coordinates remediation actions.",
  "version": "1.2.3",
  "provider": {
    "organization": "Example Manufacturing",
    "url": "https://example.com"
  },
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "extensions": [
      {
        "uri": "urn:a2a:mqtt-profile:v1",
        "description": "Broker registry metadata extension.",
        "required": false,
        "params": {
          "securityMetadata": {
            "jwksUri": "https://keys.example.com/.well-known/jwks.json"
          }
        }
      }
    ]
  },
  "defaultInputModes": ["application/json"],
  "defaultOutputModes": ["application/json"],
  "supportedInterfaces": [
    {
      "protocolBinding": "MQTT5+JSONRPC",
      "protocolVersion": "1.0",
      "url": "mqtts://broker.example.com:8883",
      "tenant": "com.example/factory-a"
    }
  ],
  "securitySchemes": {
    "oauth2": {
      "oauth2SecurityScheme": {
        "description": "OAuth2 for agent invocation.",
        "flows": {
          "clientCredentials": {
            "tokenUrl": "https://id.example.com/oauth2/token",
            "scopes": {
              "a2a:invoke": "Invoke A2A operations."
            }
          }
        }
      }
    }
  },
  "securityRequirements": [
    {
      "schemes": {
        "oauth2": {
          "list": ["a2a:invoke"]
        }
      }
    }
  ],
  "skills": [
    {
      "id": "device-diagnostics",
      "name": "Device Diagnostics",
      "description": "Analyzes telemetry and detects device anomalies.",
      "tags": ["iot", "telemetry", "factory-a"],
      "examples": [
        "Detect abnormal vibration from line-7 motor cluster."
      ]
    }
  ]
}
```

Note: For MQTT bindings, `url` identifies the broker endpoint (host/port and optional WebSocket path).
In single-broker deployments the broker may be preconfigured and this value can be treated as informational;
in multi-broker or federated discovery it provides the connection target.
Note: Cards registered in EMQX may be identical copies of cards registered externally; retaining `url` preserves the original connection target for interoperability.

Broker-managed lifecycle status is not stored in Agent Card payload fields.
Instead, EMQX may attach status as MQTT v5 User Properties when forwarding
discovery publications to subscribers.

### Core Components

#### 1. Registry Service

A new Erlang service (`emqx_a2a_registry`) that:

- **Indexes Agent Cards**: Maintains an in-memory index of all registered
  agents for fast lookup
- **Validates Registrations**: Enforces schema validation on incoming Agent
  Cards
- **Manages Lifecycle**: Tracks agent liveness through connection state and
  computes broker-managed status for outbound discovery deliveries
- **Provides Query API**: Exposes internal APIs for CLI and Dashboard to query
  the registry

The service subscribes to the registry topic pattern and maintains state
synchronized with retained messages stored in EMQX.

#### 2. Registration via MQTT

Agents register themselves by publishing a retained message:

```bash
Topic: a2a/v1/discovery/com.example/factory-a/iot-ops-agent-001
QoS: 1
Retain: true
Payload: <Agent Card JSON>
```

EMQX intercepts publications to registry topics, validates the payload,
and updates the registry index.

For newly accepted cards, EMQX persists the retained card payload without
injecting broker-managed status fields. Invalid registrations are rejected with
a PUBACK reason code indicating the validation error.

#### 3. Discovery via MQTT

Agents discover other agents by subscribing to registry topics:

```bash
# Subscribe to all agents in an organization
Topic: a2a/v1/discovery/com.example/+/+

# Subscribe to specific agent
Topic: a2a/v1/discovery/com.example/factory-a/iot-ops-agent-001

# Wildcard subscription across organizations (with proper ACLs)
Topic: a2a/v1/discovery/+/+
```

Upon subscription, agents immediately receive all retained Agent Cards matching
the subscription pattern, providing instant discovery.

#### 4. Broker-Managed Status via MQTT User Properties

EMQX does not auto-clean retained cards when an agent disconnects and does not
mutate Agent Card payloads for status.

To expose liveness, EMQX may attach MQTT v5 User Properties when forwarding
discovery messages to subscribers:

- `a2a-status = online` when registration is accepted or agent is active
- `a2a-status = offline` when agent is observed offline
- `a2a-status-source = broker`

This preserves stable retained discovery payloads while still exposing
broker-computed liveness to subscribers.

#### 5. Interaction Modalities (MQTT v5 Required)

The registry standardizes discovery. Agent-to-agent task traffic continues on
interaction topics described by each Agent Card endpoint.

- **Request/Reply**: Requesters publish to
  `a2a/v1/request/{org_id}/{unit_id}/{agent_id}` using QoS 1 and MUST set MQTT
  5 properties `Response Topic` and `Correlation Data`. Responders publish
  replies to the provided reply topic using QoS 1 and MUST echo
  `Correlation Data`. `Correlation Data` is transport correlation and MUST NOT
  be used as an A2A task id. For newly created tasks, responders MUST return a
  server-generated `Task.id`, which requesters use for subsequent operations.
- **Response Topic**: Requesters MUST provide a routable reply topic in the
  MQTT 5 `Response Topic` property, with a recommended pattern
  `a2a/v1/reply/{org_id}/{unit_id}/{agent_id}/{reply_suffix}`.
- **Streaming**: Each stream item is a discrete MQTT message to the reply
  topic with the same `Correlation Data`. Receipt of terminal
  `TaskStatusUpdateEvent.status.state` (`TASK_STATE_COMPLETED`,
  `TASK_STATE_FAILED`, `TASK_STATE_CANCELED`) ends the stream.
- **Event Topic**: Agents publish asynchronous notifications to
  `a2a/v1/event/{org_id}/{unit_id}/{agent_id}`. Events MAY be published using
  QoS 0.
- **Optional Shared Pool Dispatch**: Requesters MAY publish to shared pool
  request topics defined by the A2A-over-MQTT transport profile. Pool members
  consume via shared subscriptions and responders MUST include
  `a2a-responder-agent-id` in pooled responses so requesters can route
  follow-ups to the concrete responder.
- **OAuth 2.0/OIDC**: When required by the Agent Card, requesters MUST include
  `a2a-authorization: Bearer <access_token>` as an MQTT User Property on each
  request; responders validate tokens before processing.
- **Optional Binary Artifact Mode**: Requesters MAY set
  `a2a-artifact-mode=binary` to receive chunked binary artifacts. Binary chunks
  include required metadata (`a2a-event-type`, `a2a-task-id`,
  `a2a-artifact-id`, `a2a-chunk-seqno`, `a2a-last-chunk`) and use payload format
  indicator `0` with appropriate `Content Type`.
- **Optional Untrusted-Broker Security Profile**: Requesters MAY set
  `a2a-security-profile=ubsp-v1` to require end-to-end encrypted payloads.
  Payloads use JWE with `Content Type` `application/jose+json` or
  `application/jose` and include `a2a-requester-agent-id`,
  `a2a-recipient-agent-id` (request) or `a2a-responder-agent-id` (response).
- **Payload format**: Default payloads SHOULD follow JSON-RPC 2.0 with
  `Content Type = application/json` and `Payload Format Indicator = 1` unless
  an optional mode (for example `ubsp-v1` or binary artifact mode) requires
  a different content type or payload indicator.

#### 6. CLI Management

New `emqx ctl a2a-registry` commands:

```bash
# List all registered agents
emqx ctl a2a-registry list

# List agents with filters
emqx ctl a2a-registry list --org com.example --status online

# Get specific agent details
emqx ctl a2a-registry get com.example factory-a iot-ops-agent-001

# Register/update agent manually (admin override)
emqx ctl a2a-registry register <agent-card.json>

# Delete agent registration
emqx ctl a2a-registry delete com.example factory-a iot-ops-agent-001

# Show registry statistics
emqx ctl a2a-registry stats
```

#### 7. Dashboard UI

New "A2A Registry" section in the EMQX Dashboard:

- **MVP Scope (CRUD-first)**:
  - View registered cards
  - Manually add/update/delete cards
  - Inspect card details (formatted + raw JSON)

- **List View (simple, practical)**:
  - Columns: `org_id`, `unit_id`, `agent_id`, `name`, `version`, `updated_at`
  - Row actions: `view`, `edit`, `delete`
  - Controls: search (`org_id`, `unit_id`, `agent_id`, `name`), refresh,
    pagination (default page size 20), last-refresh timestamp

- **Card Detail View**:
  - Read-only metadata summary
  - Formatted JSON preview
  - Raw JSON tab with copy action

- **Add/Update Editor**:
  - JSON editor as primary input
  - Validate-before-save workflow (client parse + server schema validation)
  - Success/error toast with clear backend reason

- **Delete Safety**:
  - Confirmation requires typing full identity:
    `{org_id}/{unit_id}/{agent_id}`

- **Small but important MVP features**:
  - JSON template starter for new cards
  - Validate without persisting
  - Import local JSON and export card JSON

- **Out of scope in first iteration**:
  - Universal agent client
  - Request/reply test console
  - Metrics and debugging panels
  - Batch operations

### Security Considerations

1. **ACL Integration**: Registry topics are protected by EMQX ACLs. Only
   authorized clients can publish to registry topics.

2. **Schema Validation**: All Agent Cards are validated against a JSON schema
   before acceptance, preventing malformed or malicious registrations.

3. **Message-Layer Trust**: Agent Cards MAY include public key or `jwksUri`
   metadata. This proposal adopts a simplified broker policy:
   - If `trusted_jkus` is configured (non-empty), Agent Card registration MUST
     include `jwksUri` that matches the trusted list, otherwise registration is
     rejected.
   - If `trusted_jkus` is not configured (empty), EMQX does not enforce JKU
     trust checks at registration time (permissive mode).
   - `https` and TLS certificate validation are REQUIRED when retrieving JWKS.

   This keeps registry-side security simple and explicit while avoiding partial
   inferences from untrusted runtime message headers.

4. **Admin Override**: Administrators can manage registrations directly,
   bypassing normal MQTT publication (useful for manual correction or
   administrative control).

5. **Rate Limiting**: Registration updates are rate-limited to prevent abuse
   and DoS attacks.

6. **Audit Logging**: All registry operations (registration, update, deletion)
   are logged for audit purposes.

7. **Peer-to-Peer Payload Security**: EMQX provides discovery and registration
   policy, but end-to-end message confidentiality/integrity between agents is a
   peer responsibility. For untrusted broker environments, agents SHOULD use
   the A2A-over-MQTT untrusted-broker security profile (`ubsp-v1`) with
   end-to-end encrypted payloads.

### Performance Considerations

1. **Indexing Strategy**: The registry service maintains an in-memory index
   for fast lookups. For large deployments (10,000+ agents), the index can be
   sharded by organization ID.

2. **Retained Message Limits**: The registry respects EMQX's existing retained
   message limits and storage policies.

3. **Query Optimization**: Dashboard queries use the in-memory index rather
   than scanning retained messages directly.

4. **Lazy Loading**: Agent Card details are loaded on-demand for the Dashboard,
   reducing memory footprint.

### Recommended QoS Defaults

EMQX SHOULD document these defaults (aligned with the A2A-over-MQTT profile):

- Discovery / Agent Card retained publications: QoS 1
- Request: QoS 1
- Reply: QoS 1
- Event: QoS 0 (MAY use higher QoS if required by deployment policy)

Interoperability requires clients and brokers to support QoS 1 on discovery,
request, and reply paths.

## Configuration Changes

### New Configuration Options

Add to `emqx.conf`:

```hocon
a2a_registry {
  ## Enable/disable the a2a registry feature
  enable = false

  ## Maximum size of Agent Card payload (bytes)
  max_card_size = 65536

  ## Rate limit for registration updates (per agent, per minute)
  registration_rate_limit = 10

  ## Enable schema validation
  validate_schema = true

  ## EMQX JSON schema registry reference
  schema_name= ""

  ## Require security metadata in Agent Card (jwksUri)
  require_security_metadata = false

  ## Trusted JKU allowlist for Agent Card registration.
  ## If non-empty, card jwksUri must match one entry.
  ## If empty, EMQX runs in permissive mode and does not enforce JKU trust checks.
  ## Prefer exact https JWKS URIs; prefix/domain patterns are implementation-defined.
  trusted_jkus = [
    "https://agents.example.com/.well-known/jwks.json",
    "https://keys.example.org/agents/"
  ]

  ## Enable HTTPS/TLS validation when fetching JWKS from jwksUri
  verify_jku_tls = true
}
```

### ACL Configuration

Registry topics should be protected by ACL rules. Example:

```bash
%% Recommended username format: {org_id}/{unit_id}/{agent_id}
%% Default A2A rules (can be placed in default acl.conf):

%% Allow all authenticated clients to discover cards
%% Allow all clients to receive only its own replies
%% Allow all clients to receive events from all
{allow, all, subscribe, ["a2a/v1/discovery/#", "a2a/v1/reply/${username}/#", "a2a/v1/event/#"]}.

%% Allow all agents to register to self topic, and send event to self topic
{allow, all, publish, ["a2a/v1/discovery/${username}/#", "a2a/v1/event/${username}/#"]}.

%% Allow all to request all.
{allow, all, publish, ["a2a/v1/request/#"]}.
```

These are baseline defaults. Operators can add stricter or broader rules in
`acl.conf` or other ACL backends based on deployment requirements.

## Backwards Compatibility

This feature is fully backward compatible:

1. **Opt-in Feature**: The registry is disabled by default (`enable = false`).
   Existing deployments are unaffected unless explicitly enabled.

2. **Non-intrusive**: The feature does not modify existing MQTT protocol
   behavior or retained message handling. It adds a management layer on top of
   standard MQTT retained messages and does not mutate Agent Card payloads.

3. **Topic Isolation**: Registry topics default to `a2a/v1/`, which
   keeps agent discovery traffic separate from existing application topics.

4. **Graceful Degradation**: If the registry service is unavailable, MQTT
   clients can still use retained messages directly (though without the
   enhanced management features).

5. **Migration Path**: Organizations using custom discovery mechanisms can
   gradually migrate to the standard registry by:
   - Publishing Agent Cards to registry topics alongside existing mechanisms
   - Updating clients to subscribe to registry topics
   - Eventually deprecating custom discovery

## Document Changes

1. **User Guide**: New section "A2A Registry" covering:
   - Overview and use cases
   - Agent registration via MQTT
   - Agent discovery patterns
   - Best practices

2. **Admin Guide**: New section covering:
  - Configuration options
  - CLI commands reference
  - Dashboard CRUD usage (MVP)
  - Troubleshooting

3. **API Reference**: Document the Agent Card schema and validation rules
   including security metadata fields, MQTT 5 request/reply mapping, QoS
   requirements, and broker status user properties, plus optional modes
   (shared pool dispatch, binary artifact mode, and `ubsp-v1`).

4. **Examples**: Add example code for:
  - Python agent registration
  - JavaScript agent discovery
  - CLI management workflows
  - Dashboard JSON import/export workflow

## Future Work

1. **JSON-RPC Gateway**:
   - Add an HTTP JSON-RPC gateway to improve A2A-over-MQTT interoperability.
   - Clarify this is JSON-RPC over HTTP (not a REST resource model).

2. **Streaming Transports for Interop**:
   - Add SSE support for server-to-client streaming over HTTP JSON-RPC flows.
   - Explore WebSocket transport/subprotocol support for bidirectional realtime
     communication.

3. **Request/Reply/Event Awareness for Metrics**:
   - Extend registry observability beyond cards.
   - MVP is card-aware only; future versions should inspect request/reply
     and event flows for richer metrics and operational insights.

4. **Cross-Broker Interoperability Test Suite**:
   - Define conformance and interoperability tests for topic model,
     signatures, broker status user property behavior, and transport parity.

5. **Progressive Policy Engine**:
   - Add policy hooks for per-organization controls (registration policy,
     signing requirements, rate limits, and extension allowlists).

6. **Federated Discovery**:
   - Explore controlled cross-cluster/cross-region registry federation with
     explicit trust boundaries and conflict resolution.

## Declined Alternatives

### Alternative 1: External Database for Registry Storage

**Proposal**: Store Agent Cards in a separate database (PostgreSQL, MongoDB)
instead of retained messages.

**Why Declined**:
- Introduces external dependencies and operational complexity
- Breaks the "pure MQTT" philosophy—agents must use MQTT for everything
- Requires additional infrastructure and maintenance
- Retained messages provide native MQTT discovery without external queries

### Alternative 2: HTTP REST API for Registry Management Only

**Proposal**: Use MQTT for agent registration/discovery but provide HTTP API
for admin management.

**Why Declined**:
- Inconsistent interface (MQTT for agents, HTTP for admins)
- CLI can use Erlang RPC, Dashboard can use WebSocket/HTTP already available
- Keeping everything MQTT-native maintains consistency and reduces attack
  surface

### Alternative 3: Separate Registry Service (Microservice)

**Proposal**: Deploy registry as a separate microservice communicating with
EMQX via APIs.

**Why Declined**:
- Increases deployment complexity
- Introduces network latency for registry operations
- Harder to maintain consistency between registry state and retained messages
- Integrated service provides better performance and simpler operations

### Alternative 4: No Schema Validation

**Proposal**: Accept any JSON payload as Agent Card without validation.

**Why Declined**:
- Leads to inconsistent Agent Card formats
- Makes discovery unreliable (missing required fields)
- Security risk (malformed data could break consumers)
- Schema validation ensures interoperability and data quality

### Alternative 5: Use `$a2a-registry/...` as the default prefix

**Proposal**: Keep the previous `$a2a-registry/v1/{org_id}/{agent_id}` default.

**Why Declined**:
- Diverges from the proposed cross-vendor A2A topic model
- Makes interoperability guidance harder for users adopting the A2A-over-MQTT profile
- `a2a/v1/discovery/...` aligns discovery and interaction naming conventions
