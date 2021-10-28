# RPC over QUIC

## Change log

* 2021-10-28: @k32 Initial draft

## Abstract

Replace `gen_rpc` library with another library based on `quicer`.
Keep the same API: support `call`, `cast`, `multicall`, etc. and the same port discovery mechanism.

## Motivation

`gen_rpc` library is very old, very complex, and some of the design choices are not perfect.
It supports `tcp` and `ssl` transports.

Replacing it with a `quicer` implementation will solve the following problems:

- security: quicer supports encryption out of the box, and never transmits data in a plaintext
- network congestion: quicer is based on UDP, and implements more flexible congestion control mechanisms in the userspace
- channels: `gen_rpc` uses a complicated logic to split communication between multiple TCP connections.
  QUIC, on the other hand, is based on a connectionless transport protocol and handles multiplexing of ordered message streams using the concept of channel, which takes away a lot of complexity.

## Configuration Changes

## Backwards Compatibility

## Document Changes

## Testing Suggestions

## Declined Alternatives
