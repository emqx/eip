# New Configuration Syntax for EMQ X v5.0

## Abstract

Introduce a new configuration format in EMQX v5.0 release.

## Motivation

- The `k=v` format is too verbose
- Should support hierarchy and list

## Design

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

listener.tcp {
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

### YAML

YAML is a declined option. We have decided to use HOCON as a configuration format.

## Rationale

## Implementation

We need a parser that reads HOCON file into nested map.

`foo.conf`
```
a = 1
b = { p = 2 }
```

```
hocon:load("foo.conf").
#{a => 1, b => #{p => 2}}
```

And we may need each values with metadata. 
Add `filename` and `line` by default to print helpful error info.
We should also support injecting metadata from API.
e.g. if dashboard has the config editor, we may want to know who updated the value.

```
hocon:load("foo.conf", #{include_metadata => {true, [{'changed_at', 100}, {'changed_by', "kiyofuji"}]})).
#{a => #{ value => 1, 
          metadata => #{ filename => "foo.conf", 
                         line => 1, 
                         'changed_at' => 100, 
                         'changed_by' => "kiyofuji" },
  b => #{ value => #{ p => #{ value => 2,
                              metadata => #{ filename => "foo.conf", 
                                             line => 2, 
                                             'changed_at' => 100, 
                                             'changed_by' => "kiyofuji" }}}, 
          metadata => #{ filename => "foo.conf", 
                         line => 2, 
                         'changed_at' => 100, 
                         'changed_by' => "kiyofuji" }}}
```

The map is then passed into cuttlefish, 
where the validation of values and so on take place as same as v4.x.
Hence, we also need to modify cuttlefish to accept above maps as input,
and add metadata (filename and line) into error info.

## References

- [HOCON Config](https://github.com/lightbend/config)
- [SAP Integrations and Data Management](https://help.sap.com/viewer/50c996852b32456c96d3161a95544cdb/1905/en-US/25550740941d434b8c003347601af0ac.html)
- [HashiCorp Resources](https://www.terraform.io/docs/configuration/syntax.html)

