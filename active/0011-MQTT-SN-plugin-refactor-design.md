# MQTT-SN Plugin Refactor Design

## Abstract

Refactor non-standard details which in MQTT-SN plugin.

## Motivation

The current MQTT-SN plugin has the following problems:

- DTLS connections are not supported;

- The standard functions of MQTT-SN protocol have not been fully verified.
- Configuration files are messy and non-standard; The Listener configuration item is not uniform enough.

## Design

1. Add DTLS support;

2. Add more Test Cases; Supplement unrealized functions;

3. Configuration changes

- The new version follows the HOCON configuration;
- Support DTLS connection and dynamic load configuration;
- Add Support for Dynamic start and close Listeners.

The new MQTT-SN format follows HOCON format. The following is the configuration specification:

```javascript
// default zone
mqttsn.default {
     gateway_id:  1
     advertise_duration:  "15s" 
     enable_stats:  false
     enable_qos3:  false
     idle_timeout:  "30s"
     username:  "mqtt_sn_username"
     password:  "mqtt_sn_pwssword"
     predefined_topic:  [
          {
             id:  0
             value:  "reserved"
          },
          {
             id:  1
             value:  "/hello"
          },
          {
             id:  2
             value:  "/world"
          }
     ]
}
// listener
listeners.mqttsn {
     bind:  "127.0.0.11884"
     zone:  default
     acceptors: 8
     max_connections: 102400
     access_rules: [
            {
                permission:  "allow"
                cidr:  "0.0.0.0/0"
            }
     ]
     dtls: {
              enable:  false
              key:  ""
              cert:  ""
     }
     udp_options {
           reuseaddr:  true
     }
}
```

When multiple configurations are configured, it is convenient to directly refer to the common parts:

```javascript
// Zone1
mqttsn.default {
     ......
}
// Zone2
mqttsn.zone2 {
     ......
}
// listener1
listeners.mqttsn{
     bind:  "127.0.0.1:1884"
     zone:  default
     ......
}
// listener2
listeners.mqttsn {
     bind:  "127.0.0.1:1885"
     zone:  default
     ......
}
// listener3
listeners.mqttsn {
     bind:  "127.0.0.1:1886"
     zone:  zone2
     ......
}
```

- Defaul zonet, used to configure common parameters;
- The listener added each time can refer to this zone;

## References

- [New Config Files for EMQ X v5.0 ](https://github.com/terry-xiaoyu/emqx/blob/emqx50_shawn/configs_hocon/config_examples/emqx.conf)

  

