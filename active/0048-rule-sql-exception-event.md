# Rule SQL Exception Event

## Changelog

* 2026-10-15: @zmstone Initial draft

## Abstract

When the SQL of a rule raises an exception, the rule engine drops the input
message. It increments the `failed.exception` metric and writes a log entry.
No component can get the message after that.

This EIP adds a new rule event, `$events/rule/sql_exception`. The rule engine
sends this event when the SQL of a rule raises an exception. A user writes a
normal rule on this event and attaches any action to it. That rule is a
dead-letter rule. It receives the failed input, the ID of the failed rule, the
clause that failed, and the error reason.

The event uses the same mechanism as the existing
`$events/schema_validation/failed` and `$events/message_transformation/failed`
events. It needs no new configuration. When no rule selects the event, the rule
engine does no extra work.

## Motivation

A rule SQL can raise an exception for each message that has an unexpected
format. Some examples:

* `json_decode(payload)` gets a payload that is not JSON.
* An arithmetic expression gets a string.
* A function gets an argument of the wrong type.

The rule engine catches these exceptions in `emqx_rule_runtime:do_apply_rule/3`.
For each exception it does these steps:

1. It increments `failed.exception` and `failed` for the rule.
2. It writes a `RULE_SQL_EXEC` trace and log entry.
3. It returns `{error, Reason}`.

No caller reads the return value. The input message is lost.

Users ask for a dead letter for these messages. They want to keep the failed
input in a different system, examine it, and send it again after they fix the
rule.

The existing `fallback_actions` do not apply. The resource buffer worker
starts a fallback action only when an action fails to deliver a message. When
the SQL fails, the rule calls no action, so no fallback action starts.

## Design

### Event

Event name: `rule.sql_exception`.

Event topic: `$events/rule/sql_exception`.

The event is in the `$events/<category>/<name>` format only. It has no
legacy flat-name alias.

Example rule:

```sql
SELECT
  rule_id, clause, reason, input.topic as topic, input.payload as payload
FROM
  "$events/rule/sql_exception"
WHERE
  rule_id = 'decode_sensor_data'
```

The user attaches an action to this rule, for example a Kafka producer or a
republish action to the topic `dlq/${rule_id}`.

### Event fields

| Field | Type | Description |
|---|---|---|
| `event` | string | Always `rule.sql_exception`. |
| `timestamp` | integer | The time of the exception, in milliseconds. |
| `node` | string | The node that ran the failed rule. |
| `rule_id` | string | The ID of the failed rule. |
| `namespace` | string | The namespace of the failed rule. |
| `clause` | string | The clause that failed. See the next table. |
| `reason` | string | A readable error reason. See "Error reason". |
| `input` | map | The input columns of the failed rule. |

The `input` field contains the same map that the failed rule got as its input.
The fields of `input` depend on the event or topic that triggered the failed
rule. For a message publish, they include `topic`, `payload`, `clientid`,
`username`, `qos`, and the other publish fields.

The rule engine builds the input columns before the SQL runs. The SQL
exception comes from the evaluation of an SQL expression, not from the build of
the columns. The new event puts the map into the `input` field without change.
It does not decode or evaluate it again. Thus the build of the event does not
repeat the step that failed.

The `clause` field gets its value from the exception that the runtime catches:

| Caught exception | `clause` |
|---|---|
| `{select_and_transform_error, _}` | `select` |
| `{match_conditions_error, _}` | `where` |
| `{select_and_collect_error, _}` | `foreach` |
| `{match_incase_error, _}` | `incase` |
| Any other exception | `other` |

### Scope

The rule engine sends the event only for exceptions. These are the cases that
increment `failed.exception`.

It does not send the event for `failed.no_result`. A `WHERE` clause that does
not match is normal behavior.

Action delivery failures are out of scope. `fallback_actions` already handle
them.

### Call path

The event runs synchronously, in the process that applied the failed rule. For
a rule on an MQTT topic, this is the process of the publishing client.

```
client process (emqx_channel)
└─ hook 'message.publish'
   └─ emqx_rule_events:on_message_publish
      └─ emqx_rule_runtime:apply_rules        % rule A on "t/#"
         └─ do_apply_rule → SQL raises → catch
            └─ apply_event('rule.sql_exception')
               └─ apply_rules                 % rule B on "$events/rule/sql_exception"
                  └─ rule B's actions
```

The catch clauses in `emqx_rule_runtime:do_apply_rule/3` call
`emqx_rule_events` directly. There is no new `emqx_hooks` hook point. Only the
rule engine uses this event.

This nested call is not a new pattern. Two examples exist now:

* The republish action calls `emqx_broker:safe_publish2`. That runs the
  `message.publish` hook again, in the same process, and applies more rules.
* `emqx_schema_validation:on_message_publish` is a `message.publish` hook
  callback. When a validation fails, it runs the `schema.validation_failed`
  hook. That hook applies the rules on `$events/schema_validation/failed`.

### Loop guard

Rule B can also fail. When rule B selects from `$events/rule/sql_exception`,
an exception in rule B must not send a new `sql_exception` event. Without this
guard, one failure starts an infinite chain of nested calls.

Each enriched rule has a `trigger` field, which holds the event topic. The
runtime does not send the event when the `trigger` of the failed rule is
`$events/rule/sql_exception`. Rule B's exception still increments rule B's
`failed.exception` metric and still writes the log entry.

### Isolation of the event code

The event code runs inside the `catch` handler of `do_apply_rule/3`. The `try`
of `do_apply_rule/3` does not protect its own handler. When the event code
raises an exception, the exception leaves `do_apply_rule/3` and also the
`apply_rules/3` loop. The remaining rules for the same input do not run.
`emqx_hooks:safe_execute/2` catches the exception, so the client process does
not stop. But the other rules lose the message, and no metric shows it.

Thus the runtime puts all of the event code in its own `try ... catch`. When
the event code fails, the runtime writes a log entry and returns the original
`{error, Reason}` of rule A. A failure in the event code must not change the
result of other rules.

### Error reason

The error term can contain the full payload, for example
`{decode_json_failed, Payload}`. A formatted error can thus be very large.

The runtime formats the reason with a depth limit and truncates the result to a
fixed maximum size. The `reason` field does not contain the stack trace. The
log entry of the failed rule keeps the full stack trace, as it does now.

### Namespaces

The event goes to the rules in the namespace of the failed rule and to the
rules in the global namespace. This follows
`emqx_rule_engine:get_enriched_rules_with_matching_event_including_global/2`.

The event uses this scope also when `rule_engine.limit_selects_in_namespace` is
`false`. For other events, that setting sends an event to the rules in all
namespaces. The `input` field of this event contains message data of a tenant.
A rule in a different tenant namespace must not get it.

### Rule test runs

The SQL tester applies rules through the same runtime functions. The rule
engine must not send the event for these runs:

* `POST /rule_test`. `emqx_rule_sqltester` sets the `is_test_runtime_env`
  process flag for this run. The runtime checks this flag.
* `POST /rules/{id}/test`. This path does not set the flag now. The
  implementation adds a marker for it.

A user can test the SQL of a dead-letter rule with `POST /rule_test`. This
needs a new test context schema, `ctx_rule_sql_exception`, in
`emqx_rule_api_schema`.

### Cost

When no rule selects the event, the cost is one lookup of the matching rules.
`apply_event` builds the event columns only after it finds a matching rule.

A broken rule on a busy topic sends one event for each message. The dead-letter
rule and its actions get the same message rate as the broken rule. The user
must size the action buffers for this rate.

## Configuration Changes

None. A user enables the feature when they create a rule that selects from
`$events/rule/sql_exception`.

## Backwards Compatibility

The event is new. Existing rules do not change. When no rule selects the event,
the behavior does not change.

The event is local to the node that ran the failed rule. It makes no call to
another node, so it adds no BPAPI change.

During a rolling upgrade, a rule on the new event can replicate to a node of an
earlier version. The implementation must check how such a node validates and
applies a rule with an unknown `$events/` topic.

## Document Changes

* Add `$events/rule/sql_exception` to the rule events page in emqx-docs, with
  the field table and the example rule.
* Add a section about dead-letter rules to the rule SQL page. It must tell
  users to forward the input without parsing it again, for example with
  `SELECT *`. A dead-letter rule that runs `json_decode(payload)` fails for the
  same reason as the original rule.
* The `/rule_events` API returns the new event, so the Dashboard shows it in
  its event list. Tell the Dashboard team.

## Testing Suggestions

Add Common Test cases to `emqx_rule_engine` for these behaviors:

1. A `SELECT`, `WHERE`, `FOREACH`, `INCASE`, and other exception each sends one
   event with the correct `clause` value.
2. The event contains the input columns without change, and `reason` has the
   size limit.
3. A rule with no match (`failed.no_result`) sends no event.
4. A dead-letter rule that raises an exception does not send a new event, and
   its `failed.exception` metric increments.
5. When the event code raises an exception, a third rule on the same topic still
   gets the message.
6. A rule in namespace `ns1` does not get the events of a rule in namespace
   `ns2`. Test this with `limit_selects_in_namespace` set to `true` and to
   `false`.
7. `POST /rule_test` and `POST /rules/{id}/test` send no event.
8. `POST /rule_test` with the `ctx_rule_sql_exception` context runs the SQL of a
   dead-letter rule.

## Declined Alternatives

### Fallback actions on each rule

A new rule field can list the actions to run when the SQL of the rule raises
an exception. This gives a per-rule setting in the rule form.

This EIP does not use this design:

* The action gets the input columns, not the `SELECT` output. Action templates
  that a user writes for the normal output do not match.
* It needs new schema, API, and Dashboard work for each rule.
* The event design covers the same case. A dead-letter rule can filter on
  `rule_id`.

### A separate Erlang process for exceptions

The runtime can send each exception to a dedicated process, which then sends
it to an action.

This EIP does not use this design:

* One shared process becomes a bottleneck for all rules on all clients.
* A broken rule on a busy topic fills the mailbox of that process without a
  limit.
* One new process for each exception has no upper limit.

The event design runs in the process of the failed rule. It has no shared
bottleneck and no unbounded mailbox.

### A new `emqx_hooks` hook point

The runtime can run a new hook point, for example `rule.sql_exception`, and the
rule events module can add a callback for it. This lets other applications and
ExHook get the event.

This EIP does not add the hook point now. Only the rule engine uses the event.
A direct call is simpler. A later change can add the hook point without a
change to the event.
