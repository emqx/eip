# Authentication based on Zone

## Changelog

## Abstract

It should be possible to define multiple zones with different authentication stacks.

## Motivation

We have two types of clients, one of them connects through an external network and needs to be authenticated by http,
but another group connects using an internal network and we need only jwt authentication for them.

## Design

## Configuration Changes

There should be zone specific list of authentications.

## Backwards Compatibility

It can be backward compatible by providing authentication methods globally.

## Document Changes

It should be describe on documentation.

## Testing Suggestions

## Declined Alternatives
