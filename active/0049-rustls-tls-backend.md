# Rustls TLS Backend for MQTT Listeners

## Changelog

* 2026-11-03: Initial draft.
* 2026-11-09: @hjianbo Define plugin-owned listeners and summarize prototype results.
* 2026-11-09: @zmstone Move Rustls into the core connection process as a TLS backend
  of the built-in SSL listener. Keep the plugin design as a declined alternative.

Status: Draft. Proposed EIP number: 0049. Target production release is not assigned.

## Abstract

Add an optional TLS backend to the built-in MQTT SSL listener. The backend uses
upstream Rustls through a Rust NIF. A listener selects it with
`tls_backend = rustls`. The default stays `otp`.

The NIF is a TLS state machine with no socket I/O. The connection process reads
raw bytes from the socket, gives them to the NIF, sends the bytes that the NIF
returns, and parses the decrypted bytes as MQTT. There is no ssl connection
process, no ssl sender process and no supervisor per connection.

The listener keeps its configuration, identity, management API, Dashboard
editor, certificate management, authentication and channel. Only the TLS
implementation changes.

## Motivation

TLS state, buffers and process activity contribute to the cost of large MQTT
deployments. Each OTP ssl connection adds two processes to the MQTT connection
process. The OTP handshake is CPU intensive.

Two prototypes measured the cost of OTP ssl against Rustls:

* A core prototype that puts the Rustls state machine in
  `emqx_socket_connection`. This is the design of this EIP.
* A plugin prototype (0.5.0) that owns separate listeners and a copy of the
  connection module. This design is now a declined alternative. Its
  measurements also apply here, because the per-connection architecture is the
  same: one process, one Rustls `ServerConnection`, no plaintext forwarding.

### Core prototype results

Measured on 2026-11-05. One EMQX node built from `dev-63` with 8 schedulers, and
a separate load generator (emqtt-bench) on the same host. All listeners were
open in the same boot and ran in turn, 3 rounds. The TLS listeners used the same
RSA 2048 certificate. The clients used TLS 1.3 with AES-256-GCM, with no
resumption and no client certificates. Each CPU figure is the median of 3 rounds,
with the range in brackets. Lower is better.

| Listener (connection module) | CPU per CONNECT at 500 conn/s offered (ms) | CPU per CONNECT at 1000 conn/s offered (ms) | CPU per message at 10000 msg/s (µs/msg) | p50 (µs), round 3 | p95 (µs), round 3 |
|---|---:|---:|---:|---:|---:|
| TCP, gen_tcp (`emqx_connection`) | 1.10 (1.00–1.18) | 1.03 (0.93–1.03) | 270 (265–271) | 585 | 865 |
| TCP, socket (`emqx_socket_connection`) | 0.93 (0.91–1.05) | 0.94 (0.83–0.96) | 266 (232–299) | 588 | 865 |
| TLS, OTP ssl (`emqx_connection`) | 7.37 (6.92–7.89) | 7.27 (6.89–7.92) | 359 (351–365) | 722 | 1130 |
| TLS, Rustls (`emqx_socket_connection`) | 3.32 (3.24–3.51) | 3.25 (3.03–3.38) | 282 (261–293) | 737 | 1146 |

CPU per CONNECT is broker CPU time for a connect storm of 10000 clients,
divided by the number of clients. The message workload is 500 publisher and
subscriber pairs, 20 messages/s each, QoS 0, 64-byte payload, with a 20 s warm-up
and a 30 s window. Latency is end to end. Rounds 1 and 2 had stalls of several
seconds on all four listeners, with no pattern by listener, so the latency
columns use round 3 only.

* Rustls cuts the TLS share of a CONNECT from about 6.3 ms to about 2.4 ms. The
  RSA signature is in both.
* Rustls removes about 85% of the CPU that OTP ssl adds per message. The
  remaining difference to plain TCP is smaller than the spread between rounds.
* The load generator limited the connect rate to about 850 conn/s for all
  listeners, plain TCP included. The maximum broker connect rate is not
  measured. Memory per connection is not measured.

### Plugin prototype results

The 0.5.0 plugin prototype uses Rustls 0.23.46 with ring. Measurements ran on
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

### Why a core backend, not a plugin

The TLS state machine is small and the change to the connection module is
small. In the core prototype, `emqx_socket_connection` changes by about 60
lines. A plugin must carry a copy of the connection module for each supported
EMQX release, and port each core connection fix into each copy. A plugin must
also have its own listener configuration, management API and UI, and a
generated runtime context so that `emqx_channel` can read listener settings.

A core backend avoids all of this. The listener stays a built-in listener. The
operator changes one field to enable Rustls, and changes it back to roll back.

## Design

### Connection architecture

```text
TLS client
    |
    | encrypted TCP
    v
esockd acceptor (built-in SSL listener, tls_backend = rustls)
    |
    v
emqx_socket_connection (one process)
    |-- owns the TCP socket and backpressure state
    |-- owns one Rustls ServerConnection NIF resource
    |-- feeds raw bytes to the NIF, sends the bytes that the NIF returns
    |-- parses and serializes MQTT frames
    `-- executes emqx_channel
              |
              v
       EMQX authentication, authorization,
       routing and MQTT session management
```

The listener opens the socket as a TCP socket. The connection process does the
TLS handshake through the NIF after accept, in the same place where the OTP
backend calls `ssl:handshake`.

The prototype uses `emqx_socket_connection` (the `socket` TCP backend). The NIF
API has no dependency on the socket type, so `emqx_connection` (the `gen_tcp`
backend) can use the same API. The first delivery supports one of them; select
it after a memory comparison at large connection counts.

### NIF API

The NIF is part of one shared native library with different APIs, not a
separate library for TLS only. The Erlang module `emqx_niftls` wraps it. All
calls return values. The NIF sends no messages.

```erlang
-spec config(map()) -> {ok, conf()} | {error, Reason}.
-spec new(conf()) -> tls().
-spec feed(tls(), binary()) ->
    {ok, Out, App, tls()}
    | {handshake_done, Out, App, Info, tls()}
    | {close, Out, Reason}
    | {error, Reason}.
-spec encrypt(tls(), iodata()) -> {ok, Out} | {error, Reason}.
-spec close(tls()) -> Out.
```

* `config/1` makes one Rustls `ServerConfig` from the listener `ssl_options`.
  The listener shares it with all its connections. A configuration change makes
  a new one; connections that already exist keep the old one.
* `feed/2` takes the bytes read from the socket.
  * `ok`: send `Out`, then parse `App` (decrypted bytes) as MQTT. Both can be
    empty.
  * `handshake_done`: as `ok`, once, when the handshake completes. `Info` has
    the TLS version, cipher suite, SNI, ALPN and the peer certificate. The
    connection gives `Info` to `emqx_channel` in the same form as the OTP
    backend gives `ssl:connection_information/1` and the peer certificate.
  * `close`: send `Out` (for example a TLS alert), then close the socket.
  * `error`: close the socket.
* `encrypt/2` takes outgoing MQTT packets and returns TLS records to send.
* `close/1` returns a close_notify alert to send before the socket closes.

A close_notify from the peer is not an error. `feed/2` returns the data before
it with `ok`, and the socket then sees end of stream.

### Native state and scheduling

A listener shares its `ServerConfig`; each connection owns a `ServerConnection`
with its traffic keys, record state and buffers. Closing the connection releases
that TLS state independently of an offline MQTT session. One connection process
owns each `ServerConnection`, so its lock has no contention.

Handshake processing, connection creation, configuration construction and close
notification run on dirty CPU schedulers. The core prototype runs the handshake
on a dirty CPU scheduler and the record layer on a normal scheduler, with no
bound on the input size of one call. Before production, bound each normal
scheduler call: the plugin prototype uses calls bounded by 16 KiB chunks,
nonblocking locks and CPU-timeslice accounting.

In the plugin prototype, ordinary data NIF calls observed a maximum CPU time of
311 microseconds, with no calls above one millisecond; maximum observed wall
time was about 4.05 milliseconds. These are samples, not execution-time bounds.
Timeslice accounting does not preempt native code, and dirty schedulers still
compete for host CPU.

Production qualification must audit adversarial input, buffering, destruction
and panic paths. Work without an acceptable ordinary-scheduler bound must use
dirty scheduling and be benchmarked again. A native crash can terminate BEAM;
native binary upgrades currently require a fresh VM.

### TLS capabilities

Rustls supports TLS 1.2 and 1.3 with modern cipher suites only. The backend
maps the existing `ssl_options` of the listener to a `ServerConfig`:

* `certfile`, `keyfile`, `cacertfile`. Encrypted private keys need a decrypt step
  in Erlang before `config/1`.
* `verify` and `fail_if_no_peer_cert`, through `WebPkiClientVerifier`.
* `versions`, `ciphers` (only the suites that Rustls supports), and
  `supported_groups`.
* `server_name_indication` and ALPN.
* `enable_crl_check`: the verifier gets the CRLs from `emqx_crl_cache`, so the
  CRL fetch and refresh stay the same as for the OTP backend.
* `ocsp.enable_ocsp_stapling`: a certificate resolver staples the response from
  `emqx_ocsp_cache`, so the OCSP fetch and refresh stay the same.
* Managed certificates and certificate reload: a reload makes a new
  `ServerConfig` and uses it for new connections. If the reload fails, the old
  configuration stays active.

Configuration validation rejects `tls_backend = rustls` together with an option
that Rustls cannot honor, for example PSK, TLS 1.0 or 1.1, or a cipher suite
that Rustls does not support. The error names the option.

Session resumption: Rustls manages its own session cache or stateless tickets.
Resumption state is local to the listener configuration and is not shared with
OTP or with other nodes. It must keep the verified client certificate identity.
Each MQTT CONNECT still runs EMQX authentication. 0-RTT stays disabled. The core
prototype disables tickets (`send_tls13_tickets = 0`), the same as the OTP ssl
server default.

### Fallback to OTP ssl (later phase)

A later phase can accept clients that need PSK or old cipher suites on the same
listener. The connection reads the ClientHello with the Rustls `Acceptor`. If
Rustls cannot serve the client, the connection gives the bytes that it read and
the socket to OTP ssl:

* With `gen_tcp`, put the bytes back with `gen_tcp:unrecv/2`, then call
  `ssl:handshake/2`.
* With `socket`, `unrecv` is not supported. Peek the ClientHello with
  `socket:recv/3` and the `peek` flag instead, so that no bytes are consumed.

The first delivery does not include this. A listener that must serve such
clients uses `tls_backend = otp`.

## Configuration Changes

Add one field to the MQTT SSL listener:

```hocon
listeners.ssl.default {
  bind = "0.0.0.0:8883"
  tls_backend = rustls   # otp (default) | rustls
  ssl_options {
    certfile = "${EMQX_ETC_DIR}/certs/cert.pem"
    keyfile = "${EMQX_ETC_DIR}/certs/key.pem"
    versions = ["tlsv1.3", "tlsv1.2"]
    verify = verify_none
  }
}
```

All other fields keep their meaning. The field has low importance in the first
delivery, and the Dashboard shows it as an advanced setting.

## Backwards Compatibility

The default is `tls_backend = otp`, so nothing changes until an operator sets
the field. A listener update that changes the field restarts the listener, the
same as a change to the TCP backend. Connections that exist keep their backend
until they close. Backend or node changes can require full TLS handshakes
because resumption state is not shared.

The connection info that the channel, the hooks and the management API show
must be the same for both backends: the TLS version, the cipher, SNI and the
peer certificate fields.

## Document Changes

Document `tls_backend` in the listener configuration and the TLS guide: what it
does, the options that Rustls does not support, how to roll back, and that a
change of the field restarts the listener.

## Testing Suggestions

### Prototype results

* Core prototype: a test of the NIF against an OTP ssl client, with TLS 1.3
  (AES-256-GCM) and TLS 1.2 (ECDHE-RSA-AES256-GCM), with a 100 KB echo. MQTT connect, publish and subscribe through the listener.
* Plugin prototype: all 36 real-network E2E groups passed on each of EMQX 6.3.0,
  6.3.1 and 6.3.2, with zero skips. Coverage includes MQTT 3.1.1/5, QoS,
  authentication, wills, sessions, takeover, flow control, TLS variants, mTLS,
  resumption, SNI, ALPN, revocation, certificate reload and cleanup.
* Plugin prototype: selected public tlsfuzzer probes recorded 419 passes and 21
  failures across 440 executions, including repeated probes. The profile was
  TLS 1.3/AES-256-GCM with RSA and no resumption. Three failures concern legal
  compatibility CCS messages; a separate TLS/MQTT continuation test passed all
  seven cases. The other 18 cover empty encrypted Alerts, plaintext Finished,
  missing-KeyShare alert selection and legacy_version handling, and need
  individual upstream/specification triage.

These results do not establish full TLS conformance or OTP equivalence.

### Remaining qualification

1. Run the existing SSL listener test suites with `tls_backend = rustls`: mTLS,
   CRL, OCSP stapling, certificate reload, managed certificates, SNI,
   listener-specific authentication and peer certificate as client ID or
   username.
2. Test listener update from `otp` to `rustls` and back, with connected clients,
   and validation errors for unsupported options.
3. Extend public TLS testing to TLS 1.2, mTLS, additional suites and
   resumption, and resolve or explicitly approve known limitations.
4. Exercise malformed records, fragmentation, KeyUpdate, partial I/O, slow peers,
   connection churn and process crashes. Add native-boundary fuzzing/sanitizers
   and scheduler responsiveness checks.
5. Measure memory per connection and the maximum connect rate with enough load
   generators. Run long-duration and large-connection tests on every supported
   platform. Benchmark mTLS, TLS 1.2 and resumption.

## Declined Alternatives

* **A plugin that owns separate listeners:** this was the first draft of this
  EIP. It keeps the core unchanged, but the plugin must carry a copy of the
  connection module for each EMQX release, port each connection fix into each
  copy, and have its own listener configuration, API and UI. `emqx_channel`
  reads listener settings from `emqx_config`, so the plugin also needs a
  generated runtime context for each listener. The core change is about 60
  lines in the connection module, so the plugin costs more than it saves.
* **Global OTP TLS replacement:** widens deployment and rollback scope to all
  consumers of OTP TLS, for example the cluster RPC, HTTP clients and data
  integration. This EIP changes only MQTT listeners, one listener at a time.
* **kTLS after an OTP handshake:** OTP 28 can hand a connection to kernel TLS
  after the handshake and stop the ssl processes. It does not reduce the
  handshake cost, and OTP supports it only for TLS 1.3 with AES-256-GCM.
* **A NIF that owns the socket:** the NIF does its own I/O and sends messages to
  the connection process. This adds a native network runtime and a second
  flow-control boundary. With return values, the connection process keeps the
  socket, the backpressure and the error handling.
* **A plaintext forwarding process:** adds copying, process activity and another
  flow-control boundary. Keep TLS and MQTT in the connection owner.
* **A private Rustls fork:** transfers TLS maintenance to EMQX. Use upstream
  releases and triage protocol differences upstream.

External TLS termination remains a valid deployment alternative when process
isolation or existing infrastructure is preferred.
