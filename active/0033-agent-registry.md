# A2A Registry as a Standard Feature

## Changelog

* 2026-02-03: @zmstone/codex Initial draft
* 2026-02-03: @codex Align with A2A MQTT profile and tighten EMQX wording
* 2026-02-05: @codex Add trusted JKU policy for runtime signed messages
* 2026-02-05: @codex Simplify to trusted-JKU-list-or-permissive model
* 2026-02-05: @codex Add Dashboard UI MVP scope (simple CRUD-first design)
* 2026-02-05: @codex Add broker-managed status field and remove cleanup flow

## Abstract

This proposal introduces an A2A Registry feature for EMQX that enables
autonomous AI agents to discover and collaborate through a standardized,
event-driven MQTT 5.0 mechanism. The registry uses retained Agent Cards on
A2A-defined discovery topics and aligns with an A2A MQTT profile, including
topic path conventions, MQTT 5 properties, JSON-RPC payload guidance, and
security metadata for public-key-based trust.
The feature improves user experience for both MQTT clients (agents) and system
administrators through CLI and Dashboard management tools while preserving native
MQTT workflows. Agents can self-register by publishing retained messages, and
administrators can inspect and manage entries through EMQX interfaces. This
feature addresses scalable agent discovery and avoids N-squared point-to-point
integration complexity in multi-agent systems, while remaining compatible with
existing MQTT deployments.

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

1. **A2A Discovery Profile**: Agent Cards are stored as retained messages on
   standardized A2A discovery topics
2. **Registry Service**: A new internal service that indexes and validates
   registrations and keeps query state in sync with retained messages
3. **Admin Interfaces**: CLI commands and Dashboard UI for registry management
4. **Automatic Lifecycle Reflection**: Broker-managed status updates in card
   extension metadata (`online`/`offline`)
5. **Security Metadata**: Agent Cards include public key / JWKS metadata for
   optional message signing and encryption policies

### Topic Structure

Following the A2A MQTT profile, the registry uses this discovery topic
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

Recommended MQTT identity mapping:
- Client ID or Username format: `{org_id}/{unit_id}/{agent_id}` (do not include `/` in the IDs)
- This enables simple conventional ACL patterns aligned with A2A topic paths.

In addition to discovery topics, the Agent Card endpoint fields SHOULD point to
the standardized interaction path:

```
a2a/v1/{method}/{org_id}/{unit_id}/{agent_id}
```

Where `{method}` is typically one of `request`, `response`, or `event`.
For flexibility, EMQX allows configurable prefixes, but the default profile is
the standardized A2A topic model above.

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
          },
          "status": "online"
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
      "url": "mqtts://broker.example.com:8883/a2a/v1",
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

This proposal defines `status` as an extension field in the MQTT profile
extension params. Allowed values are `online` and `offline`, and the value is
broker-managed (not client-authoritative).

### Core Components

#### 1. Registry Service

A new Erlang service (`emqx_a2a_registry`) that:

- **Indexes Agent Cards**: Maintains an in-memory index of all registered
  agents for fast lookup
- **Validates Registrations**: Enforces schema validation on incoming Agent
  Cards
- **Manages Lifecycle**: Tracks agent liveness through connection state and
  updates extension status metadata
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

For newly accepted cards, EMQX persists the retained card with extension status
set to `online` regardless of whether the incoming payload includes this field.
Invalid registrations are rejected with a PUBACK reason code indicating the
validation error.

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

#### 4. Broker-Managed Status Extension

EMQX does not auto-clean retained cards when an agent disconnects. Instead, it
keeps the retained card and updates extension status metadata:

- On accepted registration/update: status is persisted as `online`
- When agent goes offline: status is updated to `offline`
- When the same agent reconnects and is active again: status is updated back to
  `online`

This ensures discovery remains stable while liveness is visible directly in the
retained card.

#### 5. Interaction Modalities with MQTT 5.0

The registry standardizes discovery. Agent-to-agent task traffic continues on
interaction topics described by each Agent Card endpoint.

- **Request/Reply**: Requesters publish to
  `a2a/v1/request/{org_id}/{unit_id}/{agent_id}` and set MQTT 5 properties:
  `Response Topic`, `Correlation Data`, and user property `a2a-method`.
- **Response Topic**: Requesters SHOULD provide a routable reply topic in the
  MQTT 5 `Response Topic` property, with a recommended pattern
  `a2a/v1/response/{org_id}/{unit_id}/{agent_id}/{reply_suffix}`. Responders publish
  replies to the provided response topic and echo `Correlation Data`.
- **Event Topic**: Agents publish asynchronous notifications to
  `a2a/v1/event/{org_id}/{unit_id}/{agent_id}`. Lifecycle status (for example,
  online/offline/heartbeat) is treated as event data rather than a separate
  status channel.
- **Streaming**: Long-running tasks can emit partial outputs to the response
  topic, with progress metadata in user properties.
- **Payload format**: A2A task payloads SHOULD follow JSON-RPC 2.0 with
  `content-type = application/json` and `payload format indicator = 1`.

#### 6. CLI Management

New `emqx_ctl a2a-registry` commands:

```bash
# List all registered agents
emqx_ctl a2a-registry list

# List agents with filters
emqx_ctl a2a-registry list --org com.example --status online

# Get specific agent details
emqx_ctl a2a-registry get com.example factory-a iot-ops-agent-001

# Register/update agent manually (admin override)
emqx_ctl a2a-registry register <agent-card.json>

# Delete agent registration
emqx_ctl a2a-registry delete com.example factory-a iot-ops-agent-001

# Search agents by capability
emqx_ctl a2a-registry search --capability device-diagnostics

# Show registry statistics
emqx_ctl a2a-registry stats
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
  - Request/response test console
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
   peer responsibility. Publishers SHOULD encrypt sensitive payloads using the
   subscriber/receiver public key and receivers SHOULD verify sender signatures.

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

### Recommended QoS Profile

MQX SHOULD document these defaults:

1. Discovery / Agent Card retained publications: QoS 1
2. Event / heartbeat updates: QoS 0
3. Task request delegation: QoS 1
4. Final artifact/result delivery: QoS 1
5. Streaming token-by-token updates: QoS 0

## Configuration Changes

### New Configuration Options

Add to `emqx.conf`:

```hocon
a2a_registry {
  ## Enable/disable the a2a registry feature
  enable = false

  ## Topic prefix pattern for registry topics
  ## Default: "a2a/v1/discovery/{org_id}/{unit_id}/{agent_id}"
  topic_prefix = "a2a/v1/discovery"

  ## Maximum size of Agent Card payload (bytes)
  max_card_size = 65536

  ## Rate limit for registration updates (per agent, per minute)
  registration_rate_limit = 10

  ## Enable schema validation
  validate_schema = true

  ## Path to custom Agent Card JSON schema (optional)
  ## If not specified, uses built-in schema
  schema_path = ""

  ## Require security metadata in Agent Card (public key or jwksUri)
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

  ## Enable audit logging for registry operations
  audit_log = true
}
```

### ACL Configuration

Registry topics should be protected by ACL rules. Example:

```bash
# Recommended username format: {org_id}/{unit_id}/{agent_id}
# Default A2A rules (can be placed in default acl.conf):

# Allow all authenticated clients to discover cards
{allow, all, subscribe, ["a2a/v1/discovery/#"]}.

# Allow all authenticated clients to send requests
{allow, all, publish, ["a2a/v1/request/#"]}.

# Allow each client to receive only its own responses
{allow, all, subscribe, ["a2a/v1/response/${username}/#"]}.
```

These are baseline defaults. Operators can add stricter or broader rules in
`acl.conf` or other ACL backends based on deployment requirements.

## Backwards Compatibility

This feature is fully backward compatible:

1. **Opt-in Feature**: The registry is disabled by default (`enable = false`).
   Existing deployments are unaffected unless explicitly enabled.

2. **Non-intrusive**: The feature does not modify existing MQTT protocol
   behavior or retained message handling. It adds a management layer on top of
   standard MQTT retained messages.

3. **Topic Isolation**: Registry topics default to `a2a/v1/discovery`, which
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
   including security metadata fields and MQTT 5 property mapping.

4. **Examples**: Add example code for:
  - Python agent registration
  - JavaScript agent discovery
  - CLI management workflows
   - Dashboard JSON import/export workflow

5. **Migration Guide**: Document how to migrate from custom discovery to Agent
   Registry

## Testing Suggestions

### Unit Tests

1. **Registry Service**:
   - Agent Card validation (valid/invalid schemas)
   - Index operations (add, update, delete, query)
   - Lifecycle management (online/offline status updates)
   - Rate limiting enforcement

2. **MQTT Integration**:
   - Registration via PUBLISH with RETAIN flag
   - Discovery via SUBSCRIBE receiving retained messages
   - Offline transition updates retained card extension status to `offline`
   - Reconnect transition updates retained card extension status to `online`
   - ACL enforcement
   - MQTT 5 properties (`response_topic`, `correlation_data`, user properties)
   - Registration trust policy with `trusted_jkus`
     - card `jwksUri` must match allowlist when configured
     - unmatched `jwksUri` registration is rejected
     - empty `trusted_jkus` behaves as permissive mode

3. **CLI Commands**:
   - All command variations
   - Error handling
   - Output formatting

### Integration Tests

1. **End-to-End Agent Registration**:
   - Agent publishes registration
   - Another agent discovers it via subscription
   - Admin views it in Dashboard
   - Agent disconnects, status changes to offline in retained card

2. **Multi-Agent Scenario**:
   - Register 1000 agents
   - Verify discovery performance
   - Test concurrent registration updates

3. **Failure Scenarios**:
   - Invalid Agent Card rejection
   - ACL denial handling
   - Registry service restart recovery
   - Signature verification failure handling (when enabled)

### Performance Tests

1. **Scalability**:
   - Measure registration throughput (agents/second)
   - Measure discovery query latency with 10K+ agents
   - Memory usage with large registries

2. **Dashboard Performance**:
   - Page load time with 1000+ agents
   - Search/filter response time
   - Concurrent admin operations

### Manual Testing

1. **Dashboard UI**:
   - Visual verification of list/detail views
   - Search and filter functionality
   - Manual add/update/delete
   - Delete confirmation guard
   - Validate-before-save behavior
   - Import/export JSON behavior

2. **CLI Usability**:
   - Command completion
   - Error messages clarity
   - Output formatting readability

3. **Real-world Scenarios**:
   - Deploy with actual agent frameworks (LangGraph, CrewAI)
   - Test with production-like agent counts
   - Verify interoperability with A2A protocol implementations

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
- Makes interoperability guidance harder for users adopting an A2A MQTT profile
- `a2a/v1/discovery/...` aligns discovery and interaction naming conventions
