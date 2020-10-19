# New Config Syntax for EMQ X v5.0

## Abstract

Introduce a new configuration format in EMQ X v5.0 release.

## Motivation

- The `k=v` format is too verbose
- Should support group and list

## Design

### YAML Style

Node/cluster config in YAML style:

```yaml
node:
  name: emqx@127.0.0.1
  cookie: emqxsecretcookie
  data_dir: {{ platform_data_dir }}
  global_gc_interval: 15m
  crash_dump: {{ platform_log_dir }}/crash.dump
cluster:
  name: emqxcl
  proto_dist: inet_tcp
  discovery: manual
  autoheal: on
  autoclean: 5m
```

Listeners config in YAML style:

```yaml
listeners:
  tcp:
    - name: mqtt_over_tcp
      bind: 0.0.0.0:1883
      zone: default
      acceptors: 8
      max_conn_rate: 1000
      max_connections: 1024000
    - name: mqtt_over_ssl
      bind: 8883
      zone: default
      enable_ssl: on
      acceptors: 16
      max_conn_rate: 1000
      max_connections: 102400
    - name: internal_mqtt_over_tcp
      bind: 127.0.0.1:11883
      zone: internal
      acceptors: 4
      max_connections: 1024000
      max_conn_rate: 1000
      active_n: 1000
      tcp_options:
        backlog: 512
        send_timeout: 5s
        send_timeout_close: on
        recbuf: 64KB
        sndbuf: 64KB
        buffer: 16KB
  ws:
    - name : mqtt_over_websocket
      bind: 8083
      zone: default
      mqtt_path: /mqtt
      acceptors: 4
      max_conn_rate: 1000
      max_connections: 102400
    - name: mqtt_over_websocket_ssl
      bind: 8084
      zone: default
      enable_ssl: on
      mqtt_path: /mqtt
      acceptors: 4
      max_conn_rate: 1000
      max_connections: 102400

```

### HOCON Style

Node/cluster config in HOCON style:

```hocon
node {
  name: "emqx@127.0.0.1"
  cookie: emqxsecretcookie
  data_dir: "{{ platform_data_dir }}"
  global_gc_interval: 15m
  crash_dump: "{{ platform_log_dir }}/crash.dump"
}

cluster {
  name: emqxcl
  proto_dist: inet_tcp
  discovery: manual
  autoheal: on
  autoclean: 5m
}
```

Listener config in HOCON style:

```hocon
listener.tcp {
  bind: "0.0.0.0:1883"
  zone: default
  acceptors: 8
  max_conn_rate: 1000
  max_connections: 1024000
}

listeners.tcp {
  bind: "127.0.0.1:11883"
  zone: internal
  acceptors: 4
  max_connections: 1024000
  max_conn_rate: 1000
  active_n: 1000
  tcp_options: ${tcp.options} //Substitution
}

listener.ssl {
  bind: 8883
  zone: default
  acceptors: 16
  max_conn_rate: 1000
  max_connections: 102400
  include "ssl.conf" //Include
}

listener.ws {
  bind: 8083
  zone: default
  acceptors: 4
  max_conn_rate: 1000
  max_connections: 102400
  mqtt_path: /mqtt
}

listener.wss {
  bind: 8084
  zone: default
  enable_ssl: on
  acceptors: 4
  max_conn_rate: 1000
  max_connections: 102400
  mqtt_path: /mqtt
}

tcp.options {
  backlog: 512
  send_timeout: 5s
  send_timeout_close: on
  recbuf: 64KB
  sndbuf: 64KB
  buffer: 16KB
}
```

## Rationale

## Implementation

Libs to parse YAML/HOCON.

## References

- [HOCON Config](https://github.com/lightbend/config)
- [SAP Integrations and Data Management](https://help.sap.com/viewer/50c996852b32456c96d3161a95544cdb/1905/en-US/25550740941d434b8c003347601af0ac.html)
