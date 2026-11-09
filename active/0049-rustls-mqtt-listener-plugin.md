# Optional Rustls MQTT Listener Plugin

## Changelog

* 2026-11-03: Initial draft.
* 2026-11-09: @hjianbo Define plugin-owned listeners and summarize prototype results.

Status: Draft. Proposed EIP number: 0049. Target production release is not assigned.

## Abstract

Provide an optional MQTT/TLS listener plugin using upstream Rustls through a Rust
NIF. The plugin owns its configuration, listener lifecycle and management state.
Built-in EMQX listeners and their configuration remain unchanged.

Each connection uses one Erlang process for TCP ownership, TLS processing, MQTT
framing and emqx_channel execution. The plugin reuses EMQX authentication,
authorization, routing and MQTT sessions. The prototype shows lower memory and
CPU use than the OTP TLS listener under the measured workloads.

This EIP proposes the plugin configuration and architecture. Prototype 0.5.0
provides the test results below; it does not yet implement the proposed plugin
configuration interface or establish production readiness.

## Motivation

TLS state, buffers and process activity contribute to the cost of large MQTT
deployments. A Rustls listener can reduce that cost while preserving the existing
MQTT processing pipeline.

A separate plugin lets operators evaluate selected nodes and ports and roll back
through the existing listener deployment. TLS protocol handling and cryptography
remain in unmodified upstream Rustls and its cryptographic provider.

### Performance results

The 0.5.0 prototype uses Rustls 0.23.46 with ring. Measurements ran on
2026-10-29 with official EMQX 6.3.2 and EMQX OTP 28 on an Intel Core i7-14700KF
WSL2 host. Three trials rotated the backend order, using four broker logical
CPUs, separate client CPUs, 128 active clients and 20-second MQTT QoS 1 intervals.
TLS backends used the same RSA certificate and TLS 1.3/AES-256-GCM, with mTLS and
resumption disabled.

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

RSS and CPU are trial means; P99 uses pooled histograms. Added Rustls RSS ranged
from 245 to 304 MiB. RSS includes native memory and excludes kernel socket
memory. Message latency includes sender scheduling lag. Connection service time
includes TCP, TLS where applicable, MQTT CONNECT and CONNACK after a client
concurrency slot is granted.

The burst workload retained 8000 idle connections while sending 4000 messages/s
and opening 800 additional connections per interval. Accepted measurements
verified 2,880,000 messages and 7200 additional transport/MQTT connections, with
connection resources released after cleanup.

These are whole-listener, fixed-load measurements. They do not establish maximum
throughput, resumed-handshake performance or million-connection capacity. Normal
message P99 is approximately unchanged.

## Design

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

The data path has no internal plaintext forwarding connection or extra forwarding
process. Erlang owns socket I/O; the NIF does not start a separate network runtime.

The prototype packages separately named connection implementations derived from
each supported EMQX release. It does not replace emqx_connection. Keep support
version-specific and assign ownership for porting core connection fixes. The
initial plugin does not require a new core TLS backend registry or schema.

### Plugin configuration and lifecycle

Package defaults and a configuration schema with the plugin. Use the existing
plugin configuration mechanism, emqx_plugins:get_config and on_config_changed
for persisted settings and updates. A plugin coordinator manages named listener
workers and reports desired configuration, effective state and activation errors.

Plugin start opens enabled listeners. Plugin stop closes its listeners,
connections and limiters. Individual listener enable/disable affects only that
entry. An empty configuration or all listeners disabled is a healthy idle state.
Package defaults must open no ports until the operator configures certificates
and enables a listener.

Validate configuration and prepare TLS contexts before applying changes. Reject
invalid options while retaining the previous active configuration. Binding
changes can require a restart; report any partial application or failed rollback.
Persisting configuration alone must not be reported as successful activation.
Cluster operations must expose per-node failures through plugin status.

Use the plugin configuration UI/API and plugin management commands. These
listeners do not become entries in the built-in listener editor.

### MQTT channel compatibility

Move connection configuration reads into the plugin's listener context where
possible. Existing channel paths also read listener context from emqx_config;
removing the prototype's user-maintained SSL profile requires an explicit audit
of those dependencies.

A minimal generated runtime context may bridge the existing internal APIs. It
must derive from plugin configuration, use an owned collision-checked identity,
and never become independently editable, persisted or responsible for another
socket. Test cleanup, restart and listener-specific authentication against this
mapping. Do not substitute an existing listener's identity. This compatibility
work remains to be implemented and validated.

### Native state and scheduling

A listener shares its ServerConfig; each connection owns a ServerConnection with
its traffic keys, record state and buffers. Closing the connection releases that
TLS state independently of an offline MQTT session.

Handshake processing, connection creation, configuration construction and close
notification run on dirty CPU schedulers. Initial application processing also
uses dirty scheduling. The prototype's established data path uses calls bounded
by 16 KiB chunks, nonblocking locks and CPU-timeslice accounting.

Ordinary data NIF calls observed a maximum CPU time of 311 microseconds, with no
calls above one millisecond; maximum observed wall time was about 4.05
milliseconds. These are samples, not execution-time bounds. Timeslice accounting
does not preempt native code, and dirty schedulers still compete for host CPU.

Production qualification must audit adversarial input, buffering, destruction
and panic paths. Work without an acceptable ordinary-scheduler bound must use
dirty scheduling and be benchmarked again. A dirty-only data fallback is required
before production support. A native crash can terminate BEAM; native binary
upgrades currently require a fresh VM.

### TLS capabilities and lifecycle

The prototype supports TLS 1.2/1.3, all nine ring cipher suites, X25519/P-256/P-384,
optional or required client certificate authentication, SNI certificate selection,
ALPN, session resumption and file-based certificate/CRL/OCSP reload. Unknown or
unsupported configuration must fail before opening a listener.

Rustls manages live TLS state and resumable session contents. Configure a bounded
cache or the upstream stateless Ticketer. Resumption state is local to the
listener configuration, is not persisted or shared with OTP or other nodes, and
must preserve verified client certificate identity. Each MQTT CONNECT still runs
EMQX authentication. MQTT persistent sessions remain independent of TLS sessions.
0-RTT stays disabled pending a separate MQTT replay policy.

Certificate reload prepares a complete replacement before publishing it for new
Rustls connections. Failure retains the active configuration. Established
connections and handshakes already using the old configuration continue with
it. Replacement invalidates previous resumption state; revocation procedures
must separately address existing connections.

CRLs use Rustls validation with expiration enforcement. Static OCSP responses
need external validation and refresh. Automated refresh, managed certificates,
FIPS/PQ providers and full OTP option parity are outside the current prototype.

## Configuration Changes

The following is proposed plugin configuration, managed through the existing
plugin framework. It is not an emqx.conf listeners.ssl entry and is not yet
supported by package 0.5.0.

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
      verify = verify_none
      reuse_sessions = true
      session_tickets = stateless
      session_cache_size = 4096
      supported_groups = ["X25519", "P-256", "P-384"]
    }
  }
}
```

All entries use Rustls. main is a plugin listener name; enable controls that
listener while the plugin is running. Keep TLS, SNI, revocation and cache settings
in this single validated configuration. No separate options-file environment
variable or user-maintained disabled core SSL profile is required.

Prototype migration stops the old listener, imports its settings into plugin
configuration, removes the old profile and side-file dependency, and starts the
new configuration after checking port ownership. Any required internal runtime
context is generated and owned by the plugin.

The example enables resumption; the performance comparison above disabled it.

## Backwards Compatibility

Built-in listeners retain their configuration, identities, APIs and defaults.
Operators install and configure the plugin explicitly on a separate address or
port. No core schema, TLS backend registry or running module is replaced.

The prototype was tested on EMQX 6.3.0, 6.3.1 and 6.3.2 with OTP 28 on Ubuntu
24.04 x86_64. Other releases and platforms require qualification. Encrypted
private keys, managed certificate integration, PROXY protocol and non-default
network access rules are not currently supported.

Retain an OTP listener during initial rollout and migrate traffic gradually.
Stopping the plugin closes its connections. Backend or node changes can require
full TLS handshakes because resumption state is not shared.

## Document Changes

Provide a user guide for plugin installation, its configuration UI/API, named
listener lifecycle, effective status, certificates, MQTT authentication, TLS
resumption and rollback. Document supported versions/platforms and configuration
semantics, including the distinction between persisted and active settings.

## Testing Suggestions

### Final prototype results

* All 36 real-network E2E groups passed on each of EMQX 6.3.0, 6.3.1 and 6.3.2,
  with zero skips. Coverage includes MQTT 3.1.1/5, QoS, authentication, wills,
  sessions, takeover, flow control, TLS variants, mTLS, resumption, SNI, ALPN,
  revocation, certificate reload and cleanup.
* Selected public tlsfuzzer probes recorded 419 passes and 21 failures across
  440 executions, including repeated probes. The profile was TLS 1.3/AES-256-GCM
  with RSA and no resumption. Raw assertions were retained.
* Three failures concern legal compatibility CCS messages; a separate TLS/MQTT
  continuation test passed all seven cases. The other 18 cover empty encrypted
  Alerts, plaintext Finished, missing-KeyShare alert selection and legacy_version
  handling, and need individual upstream/specification triage. They cannot all
  be treated as harmless alert-code differences.

These results do not establish full TLS conformance or OTP equivalence. The new
plugin configuration interface was not part of prototype 0.5.0 validation.

### Remaining qualification

1. Test plugin configuration, multiple listener ownership, effective status,
   invalid updates, idle health, stop/start, node restart and cluster partial
   failures. Verify compatibility-context cleanup and unaffected core listeners.
2. Cover changed MQTT credentials during resumed TLS, trust/CRL changes during
   reload, cross-SNI attempts and certificate identity after resumption.
3. Extend public TLS/certificate testing to TLS 1.2, mTLS, additional suites and
   resumption, and resolve or explicitly approve known limitations.
4. Exercise malformed records, fragmentation, KeyUpdate, partial I/O, slow peers,
   connection churn and process crashes. Add native-boundary fuzzing/sanitizers
   and scheduler responsiveness checks.
5. Run long-duration and large-connection tests on every supported platform.
   Benchmark mTLS, TLS 1.2 and resumption under matched backend configurations.
   Define production acceptance thresholds before those qualification runs.

## Declined Alternatives

* **Global OTP TLS replacement:** widens deployment and rollback scope to all
  consumers of OTP TLS. The plugin provides an independently deployed listener.
* **A plaintext forwarding process:** adds copying, process activity and another
  flow-control boundary. Keep TLS and MQTT in the connection owner.
* **A private Rustls fork:** transfers TLS maintenance to the plugin. Use upstream
  releases and triage protocol differences upstream.
* **A core backend registry in the first delivery:** changes core schema and
  startup/lifecycle behavior. Keep listener ownership in the plugin first.
* **A user-maintained disabled SSL profile:** creates conflicting enable semantics
  and multiple configuration owners. Generate any internal compatibility context
  from the plugin's single configuration.

External TLS termination remains a valid deployment alternative when process
isolation or existing infrastructure is preferred.
