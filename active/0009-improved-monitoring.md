# Improve performance monitoring

## Change log

* 2021-03-03: @k32 Initial draft

## Abstract

Integrate a changed version of [system_monitor](https://github.com/klarna-incubator/system_monitor/) into EMQX to collect `process_info` data in the background.

## Motivation

Investigation of performance bottlenecks can be greatly simplified by utilizing BEAM VM introspection functions, such as `processes` and `process_info`.
Well-known libraries like `recon` and `observer` make use of this data. However, these libraries don't collect historical data.

Historical data about Erlang processes is of special interest during analysis of bottlenecks.
Also, sometimes the designer needs to investigate a one-time, non-reproducible event.
`system_monitor` application runs in the background all the time, collecting information about the activities in the BEAM VM.
Therefore it has a better chance of capturing the relevant data.

## Design

Currently, `system_monitor` is designed to publish the telemetry to Kafka, which is not suitable for EMQX.
This design can be simplified, and the telemetry data should be written to the local log files managed by OTP kernel `logger` instead.
"Abnormal node state" detection can be incorporated into `system_monitor` to reduce the size of the log files: `system_monitor` should only log data when BEAM schedulers are saturated.

Example log entry format:

```

[#{app_memory => [{unknown,3507672},{system_monitor,2093320}],  %% List of top OTP applications by memory consumption
   app_top => %% List of top OTP applications by reduction consumption
       [{system_monitor,0.9504843084075939},
        {unknown,0.04951569159240604}],
   proc_top => %% List of top N erlang processes with the largest memory, reduction or mailbox size:
       {{1614,779722,299981},
        [#erl_top{pid = "<0.10.0>",dreductions = 1.4991432396385467,
                  dmemory = 0.0,reductions = 4817775,memory = 1115180,
                  message_queue_len = 0,
                  current_function = {erl_prim_loader,loop,3},
                  initial_call = {erlang,apply,2},
                  registered_name = erl_prim_loader,stack_size = 7,
                  heap_size = 17731,total_heap_size = 139267,
                  current_stacktrace = [{erl_prim_loader,loop,3,[]}],
                  group_leader = "<0.0.0>"},
         #erl_top{pid = "<0.44.0>",dreductions = 1.4991432396385467,
                  dmemory = 0.0,reductions = 100455,memory = 460260,
                  message_queue_len = 0,
                  current_function = {gen_server,loop,7},
                  initial_call = {erlang,apply,2},
                  registered_name = application_controller,stack_size = 8,
                  heap_size = 10958,total_heap_size = 57380,
                  current_stacktrace = [{gen_server,loop,7,
                                                    [{file,"gen_server.erl"},{line,437}]}],
                  group_leader = "<0.152.0>"},
         #erl_top{pid = "<0.50.0>",dreductions = 1.4991432396385467,
                  dmemory = 0.0,reductions = 169004,memory = 142796,
                  message_queue_len = 0,
                  current_function = {code_server,loop,1},
                  initial_call = {erlang,apply,2},
                  registered_name = code_server,stack_size = 5,
                  heap_size = 6772,total_heap_size = 17730,
                  current_stacktrace = [{code_server,loop,1,
                                                     [{file,"code_server.erl"},{line,151}]}],
                  group_leader = "<0.152.0>"},
         #erl_top{pid = "<0.151.0>",dreductions = 202.3843373512038,
                  dmemory = 0.0,reductions = 15929,memory = 26612,
                  message_queue_len = 0,
                  current_function = {user_drv,server_loop,6},
                  initial_call = {user_drv,server,2},
                  registered_name = user_drv,stack_size = 10,heap_size = 2586,
                  total_heap_size = 3196,
                  current_stacktrace = [{user_drv,server_loop,6,
                                                  [{file,"user_drv.erl"},{line,191}]}],
                  group_leader = "<0.152.0>"},
...
```

Alternatively, logs can be written in a binary form, to save space.
Also different kinds of messages can be written to different log files instead of a single one.

Finally, `system_monitor` should be added as a release app to the EMQX relx configuration.

## Configuration Changes

TBD. The following parameters might be configurable:

- "Abnormal load" threshold

- Frequency of data collection

- Log retention parameters

## Backwards Compatibility

This change is backward-compatible

## Document Changes

Contents of the new logs should be documented.

## Testing Suggestions

`system_monitor` has unit tests.

## Declined Alternatives
