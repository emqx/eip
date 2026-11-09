# Optional Rustls MQTT Listener Plugin

## Changelog

* 2026-11-03: Initial draft based on the EMQX 6.3 plugin prototype and its validation results.
* 2026-11-03: Use plugin-owned listener configuration and lifecycle. Keep
  built-in listener backends and the core schema unchanged.

* 2026-11-09: @hjianbo Prepare EIP 0049 with attached prototype evidence.

Status: Draft. Proposed EIP number: 0049. Target production release is not assigned.

## Abstract

Introduce an optional MQTT/TLS listener plugin backed by upstream Rustls. The
plugin owns its listener configuration, sockets, lifecycle and management state
through the existing plugin framework. Built-in EMQX listeners and their schema
remain unchanged. The plugin does not register a new built-in TLS backend.

Each accepted connection uses one Erlang process for TCP ownership, Rustls state,
MQTT framing and channel execution. The plugin reuses EMQX authentication,
authorization, routing and MQTT session handling. It does not insert a plaintext
forwarding connection between TLS termination and the broker.

The 0.5.0 prototype supports TLS 1.2/1.3, the nine cipher suites available from its
ring provider, client certificate authentication, session resumption, SNI, ALPN
and file-based certificate, CRL and OCSP reload. A common-configuration benchmark
shows lower RSS and CPU use than the OTP TLS listener. Normal message P99 is
approximately unchanged. These results justify further qualification; they do
not establish production readiness or complete OTP TLS equivalence.

This proposal defines a plugin-managed product interface and its qualification
work. The 0.5.0 package is experimental evidence; its disabled-profile convention
is not that interface. Built-in TLS listeners continue to use OTP.

## Motivation

TLS connection state, buffers and process activity contribute to the cost of
large MQTT deployments. An alternative listener can reduce this cost while
keeping MQTT behavior in the existing EMQX channel pipeline.

A plugin lets operators evaluate that alternative on selected nodes and ports.
It also allows the TLS engine and its platform artifacts to have an explicit
support matrix. Replacing TLS code globally would make evaluation and rollback
more difficult.

The proposed implementation uses an upstream TLS library rather than implementing
the TLS protocol in the plugin. All protocol parsing, cryptography and TLS key
management remain in Rustls and its cryptographic provider. This is in-process
TLS termination, not certificate offload, hardware offload or kTLS.

### Prototype evidence

The measured artifact is plugin 0.5.0, using unmodified Rustls 0.23.46 with ring.
Its archive SHA256 is:

```text
06ceb0ac8061a20afb2f71270e72a450eb7b95d0410d2e8bba68e2ee822bde3c
```

The benchmark ran on 2026-10-29 with official EMQX 6.3.2, the EMQX OTP 28
runtime, four broker logical CPUs, separate client CPUs and MQTT QoS 1 on an
Intel Core i7-14700KF WSL2 host. Three complete trials rotated the listener order;
traffic intervals lasted 20 seconds. TLS backends used the same RSA
certificate, TLS 1.3 and AES-256-GCM, with mTLS and resumption disabled.

| Metric | OTP TCP | OTP TLS | Rustls 0.5.0 | Reduction against OTP TLS |
|---|---:|---:|---:|---:|
| Added RSS for 8000 idle connections, MiB | 296.2 | 713.6 | 268.4 | 62.4% |
| Whole-node RSS with 8000 idle connections, MiB | 678.3 | 1104.9 | 659.3 | 40.3% |
| CPU per message, 256 B at 8000 msg/s, microseconds | 87.2 | 171.2 | 105.1 | 38.6% |
| CPU per message, 16 KiB at 2000 msg/s, microseconds | 93.0 | 175.2 | 129.8 | 25.9% |
| Message P99, 256 B at 8000 msg/s, milliseconds | 1.312 | 1.344 | 1.360 | -1.2% |
| Message P99, 16 KiB at 2000 msg/s, milliseconds | 1.360 | 1.488 | 1.424 | 4.3% |
| Message P99 during connection bursts, milliseconds | 1.312 | 4.720 | 1.408 | 70.2% |
| Full connection service P99 during bursts, milliseconds | 45.728 | 85.744 | 62.832 | 26.7% |

RSS and CPU values are trial means. P99 values come from pooled histograms, not
an average of trial percentiles. Message latency starts at the scheduled send
time and includes sender lag. Connection service time starts after a client
concurrency slot is granted and includes TCP, TLS where applicable, MQTT CONNECT
and CONNACK. The burst case combines 8000 idle connections, 128 active messaging
clients, 4000 messages/s and 800 additional connections per interval.

Rustls added RSS varied from 245 to 304 MiB across the accepted trials. RSS
includes native allocations and allocator retention, and excludes kernel socket
memory. The comparison covers whole listener implementations, including their
framing and scheduling choices; it does not isolate cipher performance.

The accepted measurements verified 2,880,000 messages and 7200 additional
transport/MQTT connections. Five externally interrupted attempts were discarded.
The tests do not measure maximum throughput, resumed-handshake performance,
long-duration stability or million-connection capacity.

## Design

### Scope and support contract

The first scope is inbound MQTT over TCP/TLS. MQTT routing and session semantics
remain EMQX responsibilities. WebSocket, QUIC, gateway transports and outbound
TLS clients are outside this proposal.

The prototype is qualified only for EMQX 6.3.0, 6.3.1 and 6.3.2 on OTP 28,
Ubuntu 24.04 x86_64. New EMQX releases, architectures and operating systems need
explicit qualification. Installation compatibility alone is insufficient.

| Area | Prototype 0.5.0 | Boundary |
|---|---|---|
| Protocol versions | TLS 1.2 and TLS 1.3 | Older TLS versions are not provided |
| Cipher suites | All nine ring suites, configurable preference | No legacy or external-PSK suites |
| Key exchange | X25519, P-256 and P-384 | No FIPS or post-quantum provider qualification |
| Client certificates | Optional or required verification against configured CAs | Rustls certificate policies apply |
| Resumption | TLS 1.2 cache/Tickets; TLS 1.3 stateful/stateless Tickets | State is local to a listener configuration |
| SNI and ALPN | Exact-host certificate selection and protocol negotiation | Client verification policy is listener-wide |
| Certificate changes | Atomic replacement for new Rustls connections | Existing connections are not re-authenticated |
| Revocation and stapling | PEM CRLs and static DER OCSP responses | File refresh is external and manual |
| MQTT sessions | Existing EMQX pipeline | Independent of TLS resumption |

Unsupported settings must fail before the listener opens. The plugin must not
silently ignore requested security features or fall back to another backend.
OTP-specific options with different semantics need explicit documentation and
validation; a matching field name does not establish behavioral parity.

### Connection architecture

```text
TLS client
    |
    | encrypted TCP
    v
esockd acceptor
    |
    v
one plugin connection process
    |-- owns the TCP socket and backpressure state
    |-- owns one Rustls ServerConnection NIF resource
    |-- decrypts and encrypts through the NIF
    |-- parses and serializes MQTT frames
    `-- executes emqx_channel
              |
              v
       EMQX authentication, authorization,
       routing and MQTT session management
```

Decrypted application bytes stay in the owning process's MQTT pipeline. There
is no internal plaintext TCP listener or additional forwarding process. Process
ownership and flow control must remain consistent with EMQX management APIs,
connection takeover, rate limits, statistics, wills and disconnect handling.

The prototype derives separately named connection modules from each qualified
EMQX release. It never replaces the running emqx_connection module. This preserves
the tested release behavior but creates a maintenance obligation: connection
fixes must be reviewed and ported to each derived implementation.

The first delivery keeps these separately named connection implementations in
the plugin and supports only explicitly qualified EMQX releases. Assign an owner
for porting core connection fixes and verify each supported release. A future
shared extension interface can reduce this maintenance cost, but introducing one
is not a prerequisite or a core modification in this proposal. The current
private EMQX/esockd APIs still require a version compatibility contract.

### Plugin ownership and configuration integration

The plugin owns one validated configuration containing its listeners. Package
priv/config.hocon defaults and priv/config_schema.avsc with the plugin, declare
schema support in its metadata, read the effective configuration through
emqx_plugins:get_config, and apply updates through on_config_changed. The plugin
framework manages the persisted runtime configuration. Package defaults are not
a second runtime configuration file for users to edit.

A plugin supervisor manages the configuration coordinator and named listener
workers. Plugin start creates the listeners whose enable field is true. Plugin
stop closes all owned listeners and connections. Enabling or disabling an
individual listener changes only that listener. An empty configuration or all
listeners disabled is a valid idle state, not a health failure.

The plugin configuration, plugin API status and runtime listener registry must
agree. Use the existing plugin configuration UI/API for edits, and plugin CLI or
plugin API handlers for listener details. Include desired enable state, actual
running state, bind address, active configuration generation, connection count
and last error. These listeners are not advertised as built-in listener entries
or controlled through the built-in listener editor.

The plugin starts after the required EMQX applications through the existing
plugin lifecycle. It does not require a new core startup phase, a TLS backend
registry or changes to built-in listener defaults. Plugin health reports failure
when an enabled plugin listener cannot start. Plugin stop is an intentional stop
of its listeners, not an attempt to unload a provider used by core listeners.

Cluster configuration operations use the existing plugin framework. Expose
per-node listener status and failures; configuration propagation alone does not
prove that every node opened its socket. Never report partial activation as
complete success.

### Compatibility with the MQTT channel

A user-visible core SSL profile must not be required. Move connection-level
configuration reads into the plugin's listener context where possible. Reuse
EMQX zones, authentication, authorization and MQTT session handling through their
existing entry points.

Some existing paths, including emqx_channel initialization, read listener context
from emqx_config. The plugin must audit these reads before removing the current
profile dependency. Where necessary, a minimal generated runtime context may
bridge such internal APIs. It is derived from plugin configuration, has an
owned and collision-checked identity, is not independently editable or persisted,
and must never cause the core listener manager to bind a second socket. It is a
compatibility projection, not a second source of desired configuration.

Tests must prove that configuration updates, worker crashes, plugin restart,
node restart and cleanup preserve this ownership. Cleanup must not remove
another listener's context. Listener-specific authentication and management must
use an explicitly supported identity mapping; do not silently substitute the
identity of an existing TCP or TLS listener. This compatibility work remains to
be implemented and validated. Unsupported integrations must be documented rather
than resolved through an unreviewed core patch.

### Native ownership and scheduling

The listener shares an immutable ServerConfig through a native resource. Each
connection owns a separate ServerConnection with its traffic keys, record state
and buffers. Erlang owns socket I/O; the NIF does not start Tokio or a separate
network runtime. TLS connection resources are released when the connection closes,
including when an offline MQTT session remains in EMQX.

Handshake processing, connection creation, configuration construction and close
notification use dirty CPU scheduling. In the prototype, initial application
processing also uses dirty scheduling; established data uses calls bounded by
16 KiB input/output chunks, nonblocking locks and CPU-timeslice accounting.

The benchmark observed a maximum ordinary data NIF CPU time of 311 microseconds,
with no calls above one millisecond. The observed maximum wall time was about
4.05 milliseconds. Neither value is an execution-time bound. consume_timeslice
does not preempt a running native call, and dirty CPU schedulers still compete
for host CPU.

Production qualification must audit adversarial record processing, buffering,
resource destruction and panic paths. It must either establish an acceptable
ordinary-scheduler work bound or move the affected work to dirty scheduling and
repeat performance tests. A dirty-only data execution fallback is required
before production support; it is not implemented in 0.5.0. The production default
execution policy remains a review decision.

### TLS session management

Rustls manages both live TLS protocol state and the contents of resumable TLS
sessions. The plugin configures a bounded session cache or the upstream rotating
stateless Ticketer. It does not implement its own Ticket encryption scheme.

The default configurable cache capacity is 4096 entries. Stateless Tickets use
the upstream ring Ticketer's six-hour key rotation and twelve-hour advertised
lifetime. Cache and Ticket keys are local to the listener configuration. They
are not persisted, shared with OTP TLS or shared across nodes.

TLS resumption must preserve authenticated client certificate identity. Every
new MQTT CONNECT must still execute EMQX authentication and authorization. A
resumed TLS session must not restore revoked MQTT permissions.

0-RTT stays disabled. Enabling it would require a separate MQTT replay policy.
Cross-node Ticket sharing and configurable cache/Ticket lifetime policies are
future work, not implied by local resumption support.

### Certificate and policy lifecycle

The reload operation reads the configured certificate, private key, CA, CRL and
OCSP files and constructs a complete replacement configuration before publishing
it. Failure retains the working configuration. Successful replacement atomically
changes the configuration captured by subsequently created Rustls connections.
Existing connections and handshakes that already captured the previous
configuration continue with it.

Replacement creates fresh resumption state. A new connection cannot use an old
Ticket or cached session to bypass a changed trust policy. Existing connections
are not re-authenticated or disconnected automatically; revocation procedures
must specify when operators also disconnect existing clients.

CRLs use Rustls verification with expiration enforcement. OCSP responses are
opaque stapled bytes: the external refresher must validate their contents and
refresh them before expiration. SNI responses must respect the same stapling
switch as the default certificate. Automated refresh and managed certificate
integration need separate implementation before equivalent operational support
can be claimed.

### Lifecycle, operations and native artifacts

The plugin listener manager controls listener start, stop and health checks.
The EMQX plugin manager controls application installation, startup and shutdown.
Listener stop releases its socket, connections and limiters without changing
built-in listeners. Orderly closure of an established TLS connection sends close_notify.
Fatal alert paths flush the alert
without appending a second close alert. Forced process termination cannot
promise a TLS close exchange.

Publish effective capabilities, listener connection counts, handshake failures,
resumption statistics, buffer limits and NIF execution metrics. Production
metrics must support concurrent consumers; the prototype's reset-on-read
benchmark counters are not a production monitoring contract.

Native artifacts must be built and tested for each supported platform and OTP
combination, with dependency versions, checksums and licenses recorded. Upstream
Rustls remains unmodified. Protocol differences are triaged upstream rather than
resolved through a private TLS fork. Security updates require a documented owner,
release process and regression matrix.

A native crash can terminate BEAM. Native in-place upgrades are not qualified;
upgrading the plugin requires a fresh BEAM VM. MQTT session retention follows the
broker's existing session implementation, not the lifetime of a TLS resource.

## Configuration Changes

### Proposed plugin configuration

The following is the proposed contents of the plugin configuration, managed
through the normal EMQX plugin configuration mechanism. It is not an emqx.conf
listeners.ssl entry, and it is not yet supported by package 0.5.0.

```hocon
listeners {
  main {
    enable = true
    bind = "0.0.0.0:9883"
    zone = default
    max_connections = 10000

    tcp_options {
      active_n = 10
      backlog = 1024
    }

    tls {
      certfile = "/etc/emqx/certs/server.pem"
      keyfile = "/etc/emqx/certs/server.key"
      versions = ["tlsv1.3", "tlsv1.2"]
      ciphers = []
      honor_cipher_order = true
      verify = verify_none
      reuse_sessions = true
      session_tickets = stateless
      session_cache_size = 4096
      supported_groups = ["X25519", "P-256", "P-384"]
      alpn_advertised_protocols = ["mqtt"]
      max_fragment_size = 0
      sni_hosts = []
      crlfiles = []
    }
  }
}
```

main is a plugin listener name. The manager supports distinct named entries,
with separate socket ownership and TLS configurations. enable=true means the
plugin should run that listener; enable=false means it should stop it. The
plugin must itself be running for any of its listeners to run.

All entries use Rustls. No tls_backend selector is needed. Existing OTP TLS
listeners retain their existing core configuration. Operators may run both
implementations on different addresses or ports.

Provide one typed schema covering listener, TCP and TLS options, with validated
defaults and unknown-field rejection. There is one session_tickets policy; remove
the external file's overriding ticket_mode field. Keep SNI, cache, groups and
revocation settings in the same plugin configuration. There is no required
EMQX_RUSTLS_OPTIONS_FILE or manually configured application environment.

The default packaged configuration must open no ports until an operator supplies
certificates and enables a listener. Runtime configuration and its backups use
the plugin framework's configuration location; users do not edit files inside
the extracted package. Configuration remains available while the plugin is
stopped. The user guide must distinguish preparing persisted configuration from
applying a live update, according to the framework's supported workflow.

### Applying changes

The configuration callback parses and semantically validates the complete target
configuration, resolves certificate files and prepares native contexts before
changing active listeners. Serialize updates through the plugin coordinator.
The update response and health/status must distinguish desired configuration
from the last successfully applied generation.

| Change | Required behavior |
|---|---|
| Enable or disable one listener | Reconcile that listener through the plugin manager |
| Unknown option or invalid TLS configuration | Reject before activation; retain the previous active configuration |
| Certificate, CA, CRL or OCSP replacement | Prepare a complete native context before replacing it for new connections |
| Replace TLS configuration | Preserve established connections where supported; invalidate old resumption state for new connections |
| Change bind address | Perform a controlled listener restart and document connection disruption |
| Stop the plugin | Close all owned listeners and connections; leave built-in listeners unchanged |

Binding changes cannot promise atomic network rollback. Report actual state and
any failed restoration. Updates involving several listeners must report partial
application explicitly if rollback cannot restore all sockets. Existing plugin
configuration propagation semantics still apply; no new cluster-wide atomicity
is implied.

Some existing startup/reload notification paths do not propagate callback errors
as a transaction failure. The plugin must expose its effective generation and
activation error rather than equate a persisted file with a successful runtime
update. This behavior needs E2E validation on every supported EMQX release.

A certificate reload operation rereads configured paths, prepares the replacement
and reports its result through plugin management. It does not require a built-in
listener lifecycle or a second editable configuration. Native binary upgrades
require a fresh VM and follow the node upgrade procedure.

### Prototype migration

Prototype 0.5.0 reads listeners.ssl.rustls with enable=false, opens the socket
from its own manager and accepts a separate options file. The next plugin
configuration interface replaces both user-maintained inputs. It does not turn
the plugin into an implementation of the core SSL listener.

Migration stops the prototype, imports the old settings into one validated plugin
configuration, checks address ownership, removes the old user-maintained profile
and side file dependency, and starts the new plugin configuration. If the core
channel still requires generated runtime context, the plugin creates and owns
that projection. It must not silently enable an old core listener profile.

The benchmark used resumption disabled on both TLS backends. The configuration
example above enables it and is not the measured benchmark profile.

## Backwards Compatibility

Existing built-in listeners keep their settings, identities, APIs and defaults.
Operators install and configure the plugin explicitly. No running module is
overwritten, and no global ssl or crypto behavior is replaced. The first delivery
does not change the core listener schema, add tls_backend or introduce a new
core provider registry.

OTP-only capabilities, encrypted private keys, managed certificate integration,
PROXY protocol and non-default network access rules are not currently supported
by the plugin. Migration requires checking the effective capability set. Do not
assume an existing OTP SSL configuration can be copied without review.

Roll out to a limited group of nodes while retaining the OTP listener. A load
balancer or client configuration controls traffic migration and rollback. The
same address cannot be owned by both listeners. Moving traffic between nodes or
backends may require a full TLS handshake because resumption state is not shared.

Production promotion requires an operator procedure for certificate refresh,
plugin failure, node restart, backend rollback and MQTT session continuity.

## Document Changes

Document installation and platform compatibility, complete configuration
semantics, authentication and resumption boundaries, certificate reload,
monitoring, native upgrade procedures and backend migration.

Publish the reproducible benchmark conditions, individual trials and TLS test
differences alongside any performance claim. Use added RSS and whole-node RSS
as separate metrics. Do not translate fixed-load CPU savings into a maximum
throughput claim or extrapolate 8000 connections to a million connections.

## Testing Suggestions

### Existing evidence

The prototype passes 36 real-network E2E groups on each of EMQX 6.3.0, 6.3.1
and 6.3.2 with zero skips. Coverage includes MQTT 3.1.1/5, QoS, authentication,
wills, offline sessions, takeover, flow control, shutdown, all nine ring suites
with RSA/ECDSA certificates, version/group negotiation, mTLS, revocation,
resumption, SNI, ALPN and reload failure retention. Twelve new feature groups
fail on archived 0.4.3 and pass on 0.5.0.

Selected public tlsfuzzer probes execute 440 times per backend, including repeated
sanity and random probes. The native result is 419 passes and 21 failures. The
probe profile is TLS 1.3/AES-256-GCM/RSA without resumption. Cipher selection and
HTTP sanity payloads were adapted for MQTT; raw TLS assertions were retained,
with no SKIP or XFAIL conversion.

Three failures concern tests that expect rejection of legal compatibility CCS
messages; a separate continuation test completes TLS and MQTT successfully in
all seven cases. The other 18 failures span empty encrypted Alert handling,
plaintext Finished handling, missing-KeyShare alert selection and legacy_version
validation. These require individual upstream/specification triage. They must
not all be described as harmless alert-code differences. Passing the plugin
feature gate does not pass the public strict TLS gate.

The OTP baseline also has probe differences. Aggregate pass counts do not rank
backend security or establish full protocol coverage.

### Production acceptance work

1. Add automated Common Test/E2E coverage for every supported configuration and
   certificate/session lifecycle. Include changed MQTT credentials during TLS
   resumption, trust/CRL changes during reload, cross-SNI attempts and resumed
   certificate identity. Use real TLS clients rather than mocked handshakes.
2. Extend public conformance and certificate testing to TLS 1.2, additional
   suites, mTLS and resumption. Triage each known failure and record upstream
   disposition or an explicitly approved limitation. TLS-Anvil, BoGo and
   x509-limbo are candidates, not suites already executed for this prototype.
3. Exercise malformed records, fragmentation, KeyUpdate, partial I/O, slow
   readers/writers, connection churn, process crashes and native resource cleanup.
   Measure normal/dirty scheduler responsiveness under those conditions.
4. Run sanitizers and fuzzing at the Erlang/NIF ownership boundary. Audit resource
   destructors, input limits and failure handling in addition to protocol parsing.
5. Add end-to-end plugin management tests covering configuration UI/API and CLI
   status consistency; independent enable/disable of multiple listeners; idle
   health; stop/start; invalid updates; cluster partial failures; and prototype
   migration. Require one desired-configuration owner and one socket owner. Audit
   any generated channel context for collisions, cleanup and accidental core
   socket creation. Verify unchanged core schema, modules and built-in listeners.
6. Run long-duration and large-connection-count tests on every supported platform.
   Test mixed-version clusters, node restart, rollback and certificate rotation.
7. Repeat performance comparisons with mTLS, TLS 1.2 and resumption enabled on
   both backends. Include representative hardware and publish every accepted
   trial. Keep platform noise, workload rate, sender lag and RSS retention visible.
8. Set quantitative promotion criteria for scheduler latency, memory, resource
   cleanup and supported features before the production qualification run.
   The current benchmark percentages are observations, not acceptance thresholds.

### Evidence and reproduction

* [Evidence scope, provenance and availability](0049-assets/README.md)
* [Functional compatibility manifest](0049-assets/functional-validation.json)
* [Public TLS probe report](0049-assets/tls-probe-report.txt)
* [TLS probe verification data](0049-assets/tls-probe-verification.json)
* [Performance report with individual trials](0049-assets/performance-report.txt)
* [Performance verification data](0049-assets/performance-verification.json)
* [Benchmark method and commands](0049-assets/benchmark-method.txt)

These are the author's prototype measurements. The implementation, native package,
complete traffic histograms and runtime logs are not included in this EIP PR.
The copied reports and source/package hashes preserve the reported observations;
independent reproduction still requires publication of the implementation and
its artifacts before production qualification.

The prototype commands refer to its workspace. Functional and performance claims
must identify the exact package and source hashes. The plugin-owned configuration
interface proposed here was not implemented or measured in version 0.5.0.

## Declined Alternatives

### Replace the OTP TLS implementation globally

This would widen the compatibility and rollback scope to every consumer of OTP
TLS. An independent listener preserves the existing deployment path and allows
operators to qualify the alternative gradually.

### Terminate TLS in a forwarding process inside the plugin

A separate TLS owner forwarding plaintext to a normal MQTT connection adds
processes, copying and flow-control coordination. It loses the single-process
path being evaluated. A dirty-only NIF policy can change execution placement
without requiring a plaintext forwarding connection.

### Maintain a private Rustls fork to make public probes pass

This would transfer protocol maintenance and validation responsibility to the
plugin. Version 0.5.0 instead uses the unmodified upstream release and reports
its known test differences. Engine updates and upstream fixes must retain a
reproducible validation record.

### Treat a sidecar or load balancer as the same implementation

External TLS termination remains a valid deployment alternative and provides
process isolation. It has different networking, failure and operational costs.
This proposal evaluates an in-process option; it does not claim it is preferable
for every deployment. A native crash boundary remains a reason to choose an
external terminator.

### Add a core TLS backend registry in the first delivery

A registry could make the backend appear as a built-in listener option, but it
also changes the core schema, startup ordering and lifecycle. This proposal keeps
configuration and listener ownership in the plugin. A future core extension can
be considered separately after the plugin has a maintained compatibility matrix.
Version-specific connection code remains an explicit maintenance cost.

### Require users to maintain a disabled core SSL profile

A user-maintained profile and a separate plugin settings file create multiple
configuration owners and confusing enable semantics. The plugin should own one
validated listener definition. A narrowly scoped, generated runtime compatibility
context may be necessary for existing channel APIs, but it must not become a
second user-facing listener or an independently editable source of policy.
