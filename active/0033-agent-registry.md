# A2A Agent Registry as a Standard Feature

## Changelog

* 2026-02-03: @zmstone/codex Initial draft
* 2026-02-03: @codex Align with A2A MQTT profile and tighten EMQX wording

## Abstract

This proposal introduces an A2A Agent Registry feature for EMQX that enables
autonomous AI agents to discover and collaborate through a standardized,
event-driven MQTT 5.0 mechanism. The registry uses retained Agent Cards on
A2A-defined discovery topics and aligns with an A2A MQTT profile, including
namespace conventions, MQTT 5 properties, JSON-RPC payload guidance, and
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
4. Automatic cleanup of stale registrations when agents disconnect
5. Validation and schema enforcement for agent registration data

Without this feature, developers must build custom discovery mechanisms on top
of raw retained messages, leading to inconsistent implementations, security
gaps, and operational overhead. Providing Agent Registry as a standard EMQX
feature reduces integration cost while maintaining backward compatibility with
existing MQTT infrastructure.

## Design

### Architecture Overview

The Agent Registry feature builds on EMQX's existing retained message
capabilities, adding a structured layer of management, validation, and
user-facing interfaces. The registry maintains agent metadata in retained
messages while providing enhanced functionality through:

1. **A2A Discovery Profile**: Agent Cards are stored as retained messages on
   standardized A2A discovery topics
2. **Registry Service**: A new internal service that indexes and validates
   registrations and keeps query state in sync with retained messages
3. **Admin Interfaces**: CLI commands and Dashboard UI for registry management
4. **Automatic Lifecycle Management**: Integration with Last Will and Testament
   (LWT) for automatic cleanup/offline signaling
5. **Security Metadata**: Agent Cards include public key / JWKS metadata for
   optional message signing and encryption policies

### Topic Structure

Following the A2A MQTT profile, the registry uses this discovery topic
hierarchy:

```
a2a/v1/discovery/{org-id}/{agent-id}
```

Where:
- `a2a/v1/discovery`: A2A discovery namespace
- `{org-id}`: Organization or trust domain identifier (e.g., reverse DNS:
  `com.example`)
- `{agent-id}`: Unique identifier for the agent instance

In addition to discovery topics, the Agent Card endpoint fields SHOULD point to
the standardized interaction namespace:

```
a2a/v1/{org-id}/{namespace}/{agent-id}/{method}
```

Where `{method}` is typically one of `requests`, `status`, or `events`.
For flexibility, EMQX allows configurable prefixes, but the default profile is
the standardized A2A topic model above.

### Agent Card Schema

An Agent Card is a JSON document conforming to the A2A Agent Card specification
with EMQX extensions for MQTT transport and security:

```json
{
  "agentId": "finance-analyzer-001",
  "orgId": "com.example",
  "namespace": "production",
  "name": "Financial Analysis Agent",
  "version": "1.2.3",
  "capabilities": [
    {
      "type": "text-analysis",
      "description": "Analyzes financial documents",
      "inputSchema": {...},
      "outputSchema": {...}
    }
  ],
  "status": "online",
  "endpoints": {
    "requests": "a2a/v1/com.example/production/finance-analyzer-001/requests",
    "status": "a2a/v1/com.example/production/finance-analyzer-001/status",
    "events": "a2a/v1/com.example/production/finance-analyzer-001/events"
  },
  "security": {
    "methods": ["oauth2.1", "jwt"],
    "publicKeyPem": "...",
    "jwksUri": "https://example.com/.well-known/jwks.json",
    "signingAlg": "EdDSA",
    "encryptionAlg": "ECDH-ES+A256KW"
  },
  "metadata": {
    "framework": "LangGraph",
    "model": "gpt-4",
    "tags": ["finance", "analysis", "production"]
  },
  "compliance": {
    "iso42001": true
  },
  "registeredAt": "2026-02-03T10:00:00Z",
  "lastSeen": "2026-02-03T15:30:00Z"
}
```

### Core Components

#### 1. Registry Service

A new Erlang service (`emqx_agent_registry`) that:

- **Indexes Agent Cards**: Maintains an in-memory index of all registered
  agents for fast lookup
- **Validates Registrations**: Enforces schema validation on incoming Agent
  Cards
- **Manages Lifecycle**: Tracks agent liveness through LWT and heartbeat
  mechanisms
- **Provides Query API**: Exposes internal APIs for CLI and Dashboard to query
  the registry

The service subscribes to the registry topic pattern and maintains state
synchronized with retained messages stored in the broker.

#### 2. Registration via MQTT

Agents register themselves by publishing a retained message:

```bash
Topic: a2a/v1/discovery/com.example/finance-analyzer-001
QoS: 1
Retain: true
Payload: <Agent Card JSON>
```

The broker intercepts publications to registry topics, validates the payload,
and updates the registry index. Invalid registrations are rejected with a
PUBACK reason code indicating the validation error.

#### 3. Discovery via MQTT

Agents discover other agents by subscribing to registry topics:

```bash
# Subscribe to all agents in an organization
Topic: a2a/v1/discovery/com.example/+

# Subscribe to specific agent
Topic: a2a/v1/discovery/com.example/finance-analyzer-001

# Wildcard subscription across organizations (with proper ACLs)
Topic: a2a/v1/discovery/+/+
```

Upon subscription, agents immediately receive all retained Agent Cards matching
the subscription pattern, providing instant discovery.

#### 4. Automatic Cleanup

When an agent disconnects ungracefully, its Last Will and Testament (LWT)
message can clear the retained registration:

```bash
Topic: a2a/v1/discovery/com.example/finance-analyzer-001
QoS: 1
Retain: true
Payload: null  # Clears the retained message
```

Alternatively, agents can publish an explicit retained offline Agent Card
(`"status": "offline"`) before disconnecting gracefully.

#### 5. Interaction Modalities with MQTT 5.0

The registry standardizes discovery. Agent-to-agent task traffic continues on
interaction topics described by each Agent Card endpoint.

- **Request/Reply**: Requesters publish to
  `a2a/v1/{org-id}/{namespace}/{agent-id}/requests` and set MQTT 5 properties:
  `Response Topic`, `Correlation Data`, and user property `a2a-method`.
- **Streaming**: Long-running tasks can emit partial outputs to the response
  topic, with progress metadata in user properties.
- **Payload format**: A2A task payloads SHOULD follow JSON-RPC 2.0 with
  `content-type = application/json` and `payload format indicator = 1`.

#### 6. CLI Management

New `emqx_ctl agent-registry` commands:

```bash
# List all registered agents
emqx_ctl agent-registry list

# List agents with filters
emqx_ctl agent-registry list --org com.example --status online

# Get specific agent details
emqx_ctl agent-registry get com.example finance-analyzer-001

# Register/update agent manually (admin override)
emqx_ctl agent-registry register <agent-card.json>

# Delete agent registration
emqx_ctl agent-registry delete com.example finance-analyzer-001

# Search agents by capability
emqx_ctl agent-registry search --capability text-analysis

# Show registry statistics
emqx_ctl agent-registry stats
```

#### 7. Dashboard UI

New "Agent Registry" section in the EMQX Dashboard:

- **Agent List View**: Table showing all registered agents with columns:
  - Agent ID
  - Organization
  - Name/Description
  - Status (online/offline)
  - Capabilities
  - Last Seen
  - Actions (view, edit, delete)

- **Agent Detail View**: Full Agent Card display with:
  - Complete JSON view
  - Formatted metadata
  - Endpoint information
  - Security/authentication details
  - Registration history

- **Search and Filter**: 
  - Filter by organization, status, capability type
  - Full-text search across agent names and descriptions
  - Tag-based filtering

- **Management Actions**:
  - Manual registration/update
  - Delete registration
  - Force status update
  - Export agent list

### Security Considerations

1. **ACL Integration**: Registry topics are protected by EMQX ACLs. Only
   authorized clients can publish to registry topics.

2. **Schema Validation**: All Agent Cards are validated against a JSON schema
   before acceptance, preventing malformed or malicious registrations.

3. **Message-Layer Trust**: Agent Cards MAY include public key or `jwksUri`
   metadata. Clients can use this to verify JWS signatures and optionally apply
   JWE payload encryption for dedicated receivers.

4. **Admin Override**: Administrators can manage registrations directly,
   bypassing normal MQTT publication (useful for manual cleanup or
   administrative control).

5. **Rate Limiting**: Registration updates are rate-limited to prevent abuse
   and DoS attacks.

6. **Audit Logging**: All registry operations (registration, update, deletion)
   are logged for audit purposes.

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
2. Status / heartbeat updates: QoS 0
3. Task request delegation: QoS 1
4. Final artifact/result delivery: QoS 1
5. Streaming token-by-token updates: QoS 0

## Configuration Changes

### New Configuration Options

Add to `emqx.conf`:

```hocon
agent_registry {
  ## Enable/disable the agent registry feature
  enable = false

  ## Topic prefix pattern for registry topics
  ## Default: "a2a/v1/discovery/{org_id}/{agent_id}"
  topic_prefix = "a2a/v1/discovery"

  ## Maximum size of Agent Card payload (bytes)
  max_card_size = 65536

  ## Rate limit for registration updates (per agent, per minute)
  registration_rate_limit = 10

  ## TTL for offline agents before automatic cleanup (seconds)
  ## 0 means never auto-cleanup
  offline_ttl = 3600

  ## Enable schema validation
  validate_schema = true

  ## Path to custom Agent Card JSON schema (optional)
  ## If not specified, uses built-in schema
  schema_path = ""

  ## Require security metadata in Agent Card (public key or jwksUri)
  require_security_metadata = false

  ## Enable audit logging for registry operations
  audit_log = true
}
```

### ACL Configuration

Registry topics should be protected by ACL rules. Example:

```bash
# Allow agents to register themselves
{allow, {user, "agent-*"}, publish, ["a2a/v1/discovery/+/+"]}.

# Allow agents to discover other agents
{allow, {user, "agent-*"}, subscribe, ["a2a/v1/discovery/+/+"]}.

# Allow admins full access
{allow, {user, "admin"}, all, ["a2a/v1/discovery/#"]}.
```

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

1. **User Guide**: New section "Agent Registry" covering:
   - Overview and use cases
   - Agent registration via MQTT
   - Agent discovery patterns
   - Best practices

2. **Admin Guide**: New section covering:
   - Configuration options
   - CLI commands reference
   - Dashboard usage
   - Troubleshooting

3. **API Reference**: Document the Agent Card schema and validation rules
   including security metadata fields and MQTT 5 property mapping.

4. **Examples**: Add example code for:
   - Python agent registration
   - JavaScript agent discovery
   - CLI management workflows

5. **Migration Guide**: Document how to migrate from custom discovery to Agent
   Registry

## Testing Suggestions

### Unit Tests

1. **Registry Service**:
   - Agent Card validation (valid/invalid schemas)
   - Index operations (add, update, delete, query)
   - Lifecycle management (online/offline transitions)
   - Rate limiting enforcement

2. **MQTT Integration**:
   - Registration via PUBLISH with RETAIN flag
   - Discovery via SUBSCRIBE receiving retained messages
   - LWT cleanup on disconnect
   - ACL enforcement
   - MQTT 5 properties (`response_topic`, `correlation_data`, user properties)

3. **CLI Commands**:
   - All command variations
   - Error handling
   - Output formatting

### Integration Tests

1. **End-to-End Agent Registration**:
   - Agent publishes registration
   - Another agent discovers it via subscription
   - Admin views it in Dashboard
   - Agent disconnects, registration is cleaned up

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
   - Visual verification of agent list
   - Search and filter functionality
   - Agent detail view
   - Manual registration/update/delete

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

### Alternative 5: Use `$agent-registry/...` as the default namespace

**Proposal**: Keep the previous `$agent-registry/v1/{org-id}/{agent-id}` default.

**Why Declined**:
- Diverges from the proposed cross-vendor A2A topic model
- Makes interoperability guidance harder for users adopting an A2A MQTT profile
- `a2a/v1/discovery/...` aligns discovery and interaction naming conventions
