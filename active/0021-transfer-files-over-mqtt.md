# MQTT based file transfer

## Changelog

* 2022-09-20: @qzhuyan, @id Initial draft

## Abstract

TODO:

## Motivation

EMQX customers are asking for file transfer functionality from IoT devices to their cloud (primary use case), and from cloud to IoT devices over MQTT. Right now they are uploading files from devices via FTP or HTTPS (e.g. to S3), but this approach has downsides:

* FTP and HTTP servers usually struggle to keep up with large number of simultaneous bandwidth-intensive connections
* packet loss or reconnect forces clients to restart the transfer
* devices which already talk MQTT need to integrate with one more SDK, address authenticaion and authorization, and potentially go through an additional round of security audit

Known cases of device-to-cloud file transfer:

* [CAN bus](https://en.wikipedia.org/wiki/CAN_bus) data
* Image taken by industry camera for Quality Assurance
* Large data file collected from forklift
* Video and audio data from truck cars, and video data captured by inbound unloading cameras
* Vehicle real-time logging, telemetry, messaging
* Upload collected ML logs

Known cases of cloud-to-device file transfer:

* Upload AI/ML models
* Firmware upgrades

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [BCP 14](https://www.rfc-editor.org/bcp/bcp14) [[RFC2119](https://www.rfc-editor.org/rfc/rfc2119)] [[RFC8174](https://www.rfc-editor.org/rfc/rfc8174)] when, and only when, they appear in all capitals, as shown here.

The following terms are used as described in [MQTT Version 5.0 Specification](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc39010030):
* Application Message
* Server
* Client
* Topic Name
* Topic Filter
* MQTT Control Packet

*At least once*: a message can be delivered many times, but cannot be lost

## Requirements

* The protocol MUST use only PUBLISH type of MQTT Control Packet
* The protocol MUST support transfer of file segments
* Server MUST be able to verify integrity of each file segment
* Client MAY know total file size when initiating the transfer
* Client MAY abort file transfer
* Server MAY ask the client to pause file transfer
* Server MAY ask the client to abort file transfer
* The protocol MUST NOT require changes in client code
* The protocol MUST guarantee "At least once" delivery
* Server MUST NOT support subscription on topics dedicated for file transfer

## AWS IoT MQTT-based file delivery (reference design)

As an example of existing implementation we can look at AWS IoT Core [which provides functionality](https://docs.aws.amazon.com/iot/latest/developerguide/mqtt-based-file-delivery.html) to [deliver files to IoT devices](https://docs.aws.amazon.com/iot/latest/developerguide/mqtt-based-file-delivery-in-devices.html):

![](0021-assets/aws-mqtt-file-delivery.png)

## Design

### Overview

* Files are split in segments of equal length with the exception of the last segment, it's length is > 0 and  <= segment length
* Client generates UUID for each file being transferred and use it as file Id in Topic Name
* Client calculates sha256 checksum of the segment it's about to send and sends it as part of Topic Name
* Client uses $file Topic Filter to transfer files
* Clients cannot subscribe to $file topics
* Segment length can be calculated on the server side by subtracting the length of the [Variable Header](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901025) from the [Remaining Length](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901105) field that is in the [Fixed Header](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901021)
* Data is transferred in PUBLISH packets in the following order:
  1. $file/{fileId}/init
  2. $file/{fileId}/{sha256sum}
  3. $file/{fileId}/{sha256sum}
  4. ...
  3. $file/{fileId}/[fin|abort]
* Client can send up to N (configured) PUBLISH packets before blocking for PUBACK

#### `$file/{fileId}/init` message

Initialize the file transfer. Server is expected to store metadata from the payload in the session along with `{fileId}` as a reference for the rest of file metadata.

  * Qos=1
  * DUP=0 for the initial segment transfer, 1 when retransmitting
  * Payload Format Indicator=0x01
  * `{fileId}` is corresponding file UUID
  * Payload is a JSON document with the following properties:
    * filepath
      * a character string composed with characters from this set [a-zA-Z0-9_-./]
      * length in bytes MUST be <= 4096 (PATH_MAX=4096 on most common Linux filesystems)
    * filename
      * a character string composed with characters from this set [a-zA-Z0-9_-./]
      * length in bytes MUST be < 256 (NAME_MAX=255 in Linux)
    * size
      * total file size in bytes

#### `$file/{fileId}/{sha256sum}` message

One such message for each file segment.

  * Qos=1
  * DUP=0 for the initial segment transfer, 1 when retransmitting
  * Payload Format Indicator=0x00
  * Packet Identifier=sequential file segment number
  * Payload is file segment bytes
  * `{sha256sum}` is sha256 checksum of file segment bytes

#### `$file/{fileId}/fin` message

All file segments have been successfully transferred.

  * Qos=1
  * no payload

#### `$file/{fileId}/abort` message

Client wants to abort the transfer.

  * Qos=1
  * no payload

### PUBACK Reason codes

| Reason code | MQTT Name                     | Meaning in file transfer context                    |
|-------------|-------------------------------|-----------------------------------------------------|
| OMIT        |                               | Same as 0x00                                        |
| 0x00        | Success                       | File segment has been successfully persisted        |
| 0x10        | No matching subscribers       | Server asks Client to retransmit all segments       |
| 0x80        | Unspecified error             | Server asks Client to retransmit a specific segment. Segment sequential number is indicated by Packet Identifier field in the PUBACK Variable Header |
| 0x83        | Implementation specific error | Server asks Client to cancel the transfer           |
| 0x97        | Quota exceeded                | Server asks Client to pause the transfer            |

#### 0x83, "Implementation specific error", "Cancel Transfer"

Client can retry the transfer after 1 hour.

#### 0x97, "Quota exceeded", "Pause Transfer"

Upon receiving PUBACK message with this reason code, Client is expected to delay sending next packet for 10 seconds. If next PUBACK is also 0x97, Client delays for 20 seconds. Client continues to double the delay length until it reaches 80 seconds.

### PUBACK from MQTT servers < v5.0

PUBACK messages prior to MQTT v5.0 do not carry Reason code. In this case when client did not receive PUBACK, it MUST keep trying to retransmit the corresponding message according to the protocol.

### Happy path

![](0021-assets/flow-happy-path.png)

### Transfer abort initiated by client

![](0021-assets/flow-abort.png)

### Transfer restart initiated by server

![](0021-assets/flow-restart.png)

## Configuration Changes

This section should list all the changes to the configuration files (if any).

## Backwards Compatibility

This sections should shows how to make the feature is backwards compatible.
If it can not be compatible with the previous emqx versions, explain how do you
propose to deal with the incompatibilities.

## Document Changes

If there is any document change, give a brief description of it here.

## Testing Suggestions

The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Innovation Opportunities

* Integration with rule engine
* Support for more back-end, database writes
* Multiple backend writes to a single file
* Support for rules processing of metadata
* Generate modified properties of target files based on file metadata and rules of rules engine
* Do the entire MQTT message logging
* QUIC pure binary stream support
* ACL enables client-side control of file size
* Bulk upload at EMQX
* Multi-node local cache utilization similar to hdfs

## Declined Alternatives

* Use of MQTT extension headers
  * Poor compatibility and complex application layer implementation
* Only supports QUIC protocol
  * Always need to support fallback to TCP so TCP needs to be supported as well
* Capability negotiation
  * Poor client compatibility, complex application layer implementation
* Front-end implementation is directly integrated into the rule engine
  * Rule engine is too complex and not applicable in the case of few types of backend support, only the configuration part can be seen to be reused.

