# OpenTelemetry Traces Integration

## Changelog
- 2023-09-28: Initial draft
- 2023-10-04:
  - Apply review remarks (define trace spans for the first iterations)
  - Add description of `emx_external_trace` behaviour
- 2023-12-26:
  - Update the document to match the actual implementation and move to implemented

## Abstract

This document describes EMQX OpenTelemetry integration design proposal.

More details about related components, concepts and conventions can be found in the following resources:

- [OpenTelemetry Erlang lib documentation](https://opentelemetry.io/docs/instrumentation/erlang/)
- [OpenTelemetry main trace components overview](https://opentelemetry.io/docs/concepts/signals/traces)
- [MQTT trace context specification](https://w3c.github.io/trace-context-mqtt/)
- [Trace context header specification](https://www.w3.org/TR/trace-context-1/#tracestate-header)
- [OpenTelemetry messaging system semantic conventions](https://github.com/open-telemetry/semantic-conventions/blob/main/docs/messaging/messaging-spans.md)
- [Draft PR](https://github.com/emqx/emqx/pull/11696)

## Motivation

OpenTelemetry distributed trace integration is the part of EMQX Product Road-map.

## Design

### Core concepts and tracing scope

The core traceable entity for EMQX is a message. It means that one trace should be associated with one message.

For example, a single HTTP request is a common traceable entity for a HTTP server. HTTP server instrumented with OpenTelemetry receives a HTTP request, extracts trace context from headers (e.g., `traceparent`, `tracestate` headers) and traces any processing steps (spans) up to sending a HTTP response back to the client, associating all the spans with the same trace ID (1 request - 1 trace ID).
HTTP client after receiving the response may proceed executing some subsequent operations, tracing and linking them to the same trace ID.

Somewhat analogously, EMQX instrumented with OpenTelemetry, is expected to receive a published message, extract trace context (e.g., `traceparent`, `tracestate` User-Properties), and trace some/all processing steps under the same trace ID.
Producer/consumer of the message may proceed tracing any subsequent operations relating them to the same trace ID.

These traced steps (or spans) should include the following (in the first iteration):

- Process a published message (traced by a node that received a published message).
  This span starts when PUBLISH packet is received and parsed by a connection process and ends when the message is dispatched to local subscribers and/or forwarded to other nodes (forwarding is async by default).
- Send a published message to a subscriber (traced by all nodes that have matched subscribers).
  This span is traced by each connection process (so there will be one span per each subscriber). It will be started when 'deliver` message is received by a connection controlling process and ended when outgoing packet is serialized and sent to the socket port.

NOTE: the above list may be extended/changed in the next iterations.

![An actual EMQX trace example as exported by POC implementation](0024-assets/trace-export-example.png)

Any other processing steps/events like client connection, authentication, subscription are currently not considered for OpenTelemetry tracing due to the following reasons:

- these actions are not directly associated with the main traceable entity (message) defined above
- these actions seem not absolutely suitable for distributed tracing, they can be probably traced only as internal EMQX events

### Implementation details

Erlang OpenTelemetry lib heavily relies on propagating trace context by means of process dictionary.
Obviously, this works fine when function calls are being traced within the context of the same process and needs little efforts when the context is to be propagated to a new spawned process.

However, this approach is not absolutely suitable for EMQX distributed architecture:

- correlated spans can be executed on different nodes and/or by different processes
- a batch of items relating to different traces can be processed together as a single unit of work, e.g., `emqx_connection`, `emqx_channel` modules process deliver messages in batches, where each message would have a unique trace ID if tracing is enabled.

That’s why the proposed implementation mostly relies on propagating the tracing context as a part of the message itself, which has the following advantages:

- inter-cluster communication doesn’t require any changes to support trace context propagation and is backward compatible (trace context is added to a reserved `#emqx_message.extra` field)
- tracing individual messages processed in batches is possible and doesn’t require any significant changes in the current implementation.

API and context propagation examples (see: [full implementation](https://github.com/emqx/emqx/pull/11984/files#diff-73384b930f330bcf64fb285a0bbcdce0edd015f6c7598e847da49d46b878ebe4):

```erlang

put_ctx_to_msg(OtelCtx, Msg = #message{extra = Extra}) when is_map(Extra) ->
    Msg#message{extra = Extra#{?EMQX_OTEL_CTX => OtelCtx}};
%% extra field has not being used previously and defaulted to an empty list, it's safe to overwrite it
put_ctx_to_msg(OtelCtx, Msg) when is_record(Msg, message) ->
    Msg#message{extra = #{?EMQX_OTEL_CTX => OtelCtx}}.

get_ctx_from_msg(#message{extra = Extra}) ->
    from_extra(Extra).

get_ctx_from_packet(#mqtt_packet{variable = #mqtt_packet_publish{properties = #{internal_extra := Extra}}}) ->
    from_extra(Extra);
get_ctx_from_packet(_) ->
    undefined.

from_extra(#{?EMQX_OTEL_CTX := OtelCtx}) ->
    OtelCtx;
from_extra(_) ->
    undefined.
```

Some drawbacks of the proposed implementation should also be mentioned:

- internal tracing API (as of now, implemented in `emqx_otel_trace` module) is not decoupled from the rest of the code base: each traceable action (span) is traced by a specific function and all these functions are quite specific. For example, they may extract/propagate the context differently and/or rely on the previous (parent) span. For now, it doesn’t seem feasible to create a generic trace wrapper that can trace an arbitrary function.

#### emqx_external_trace behaviour

Most (currently all) trace spans are expected to be added to the core `emqx` OTP application. However, `emqx` application mustn't depend on `opentelemetry` libs/apps.
Moreover, we already have `emqx_opentelemetry` OTP application that implements OpenTelementry metrics, schema, configuration, etc.
In order to keep `emqx` application decoupled from `opentelemetry` specific code, it's proposed to introduce `emqx_external_trace` module in `emqx` application.
The module will include necessary callbacks that an actual trace backend must implement. It will also implement `register_provider/1`, `unregister_provider/1` functions, so that `opentelemetry` backend trace module can register itself as a trace provider.

`apps/emqx/src/emqx_external_trace.erl`:
```erlang
-module(emqx_external_trace).

-callback trace_process_publish(Packet, Channel, fun((Packet, Channel) -> Res)) -> Res when
    Packet :: emqx_types:packet(),
    Channel :: emqx_channel:channel(),
    Res :: term().

...

-define(PROVIDER, {?MODULE, trace_provider}).

-define(with_provider(IfRegisitered, IfNotRegisired),
    case persistent_term:get(?PROVIDER, undefined) of
        undefined ->
            IfNotRegisired;
        Provider ->
            Provider:IfRegisitered
    end
).

%%--------------------------------------------------------------------
%% provider API
%%--------------------------------------------------------------------

-spec register_provider(module()) -> ok | {error, term()}.
register_provider(Module) when is_atom(Module) ->
    case is_valid_provider(Module) of
        true ->
            persistent_term:put(?PROVIDER, Module);
        false ->
            {error, invalid_provider}
    end.

-spec unregister_provider(module()) -> ok | {error, term()}.
unregister_provider(Module) ->
    case persistent_term:get(?PROVIDER, undefined) of
        Module ->
            persistent_term:erase(?PROVIDER),
            ok;
        _ ->
            {error, not_registered}
    end.

%%--------------------------------------------------------------------
%% trace API
%%--------------------------------------------------------------------

-spec trace_process_publish(Packet, Channel, fun((Packet, Channel) -> Res)) -> Res when
    Packet :: emqx_types:packet(),
    Channel :: emqx_channel:channel(),
    Res :: term().
trace_process_publish(Packet, Channel, ProcessFun) ->
    ?with_provider(?FUNCTION_NAME(Packet, Channel, ProcessFun), ProcessFun(Packet, Channel)).

```

### External trace context propagation

If EMQX receives trace context in a published message, e.g., `traceparent`/`tracestate` User-property for MQTT v5.0, it must be sent unaltered when forwarding the Application Message to a Client to conform with [MQTT specification 3.3.2.3.7](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901116).

This also perfectly follows [OpenTelemetry semantics for messaging systems](https://github.com/open-telemetry/semantic-conventions/blob/main/docs/messaging/messaging-spans.md#context-propagation):

> Messaging systems themselves may trace messages as the messages travels from producers to consumers. Such tracing would cover the transport layer but would not help in correlating producers with consumers. To be able to directly correlate producers with consumers, another context that is propagated with the message is required.
>
> A message creation context allows correlating producers with consumers of a message and model the dependencies between them, regardless of the underlying messaging transport mechanism and its instrumentation.
>
> The message creation context is created by the producer and should be propagated to the consumer(s).
>
> A producer SHOULD attach a message creation context to each message. If possible, the message creation context SHOULD be attached in such a way that it cannot be changed by intermediaries.

In fact, EMQX is capable of participating in distributed trace out of the box (without OpenTelemetry instrumentation), simply because it implements the above MQTT specification requirement and propagates User-Properties from a publisher to a subscriber.

However, if no trace context received but a message still should be traced, one of the following options should be chosen:

- create internal trace context and trace only internal EMQX events and do not propagate the context to receivers and/or external data systems (if bridges are set up)
- create internal trace context and propagate it to receivers and/or external data systems.

The option shall be configurable and default to not propagating internally created trace context (controlled via `opentelementry.traces.filter.trace_all` configuration parameter).

### Attributes

OpenTelemetry defines [some conventions](https://github.com/open-telemetry/semantic-conventions/blob/main/docs/messaging/messaging-spans.md#messaging-attributes) (status: Experimental at the time of writing this document).

The attributes are grouped under several name-spaces:

- `messaging.*`
- `network.*`
- `server.*`

The implementation shall follow these conventions, but as of now, only a small subset of attributes are added.
The attributes can be extended in future upon request.

### Sampling

OpenTelemetry sampling is described in great depth in the [official documentation](https://opentelemetry.io/docs/concepts/sampling).

Erlang opentelemetry lib implements only head sampling. Head sampling implies that a sampling decision is made as early as possible, e.g., by following a configured percentage of traces to sample (100% by default). A decision to sample or drop a span or trace is not made by inspecting the trace as a whole.

Sampling rate option should be added to EMQX configuration.

Tail sampling that makes a sampling decision after all the spans are done would need to be implemented by extending opentelemetry lib.

Examples of tail sampling capabilities:

- sample traces based on their latency (e.g. sample only traces that take more than 5ms)
- sample traces only if they contain an error, a specific event or attribute value

The first iteration of EMQX OpenTelemetry integration doesn't implement any sampling. This feature can be considered for development in the next EMQX releases.

### Filtering

The goal of filtering is similar to one of sampling: to narrow down the amount of traces.
However, filtering is considered as a EMQX/MQTT specific extension that doesn’t necessary follow OpenTelemetry sampling concepts.

NOTE: filters can be implemented using `otel_sampler` behavior, but it doesn’t seem to have any advantages.
It is suggested to implement a configurable filtering rules, so that a user can control which messages should be traced. It must be possible to leave filtering rules blank, so that all the incoming messages are traced (if tracing itself is enabled).

The filters may be similar to ones used in EMQX tracing:

- Client ID
- Topic
- IP address

The filtering rule should not probably be too complex to minimize performance impact.

The first iteration of EMQX OpenTelemetry integration defines only one boolean filter: `trace_all`. If it is enabled, all published messages are traced, and a new trace ID is generated if it can't be extracted from the message.
Otherwise, only messages published with trace context are traced.

## Configuration Changes

The existing EMQX OpenTelemetry schema (defined in emqx_otel_schema module) must be extended to include trace specific configuration.

Current HOCON config example:
```
opentelemetry {
  enable = true
  exporter {endpoint = "http://172.18.0.2:4317", interval = 10s}
}
```

Suggested HOCON config example:
```
opentelemetry {
  metrics {enable = true} # must be backward-compatible with opentelemetry.enable
  exporter {endpoint = "http://172.18.0.2:4317"}
  trace {
    enable = true
    filter {}
    ...
    }
}
```

## Backward Compatibility

All changes are backward compatible.

## Testing

Besides integration/unit tests, it is necessary to make performance tests/profiling to measure the impact of tracing on EMQX performance.
