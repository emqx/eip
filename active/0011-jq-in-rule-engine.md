# An Example of EMQ X Improvement Proposal

## Change log

* 2020-03-12: @terry-xiaoyu first draft
* 2020-03-21: @terry-xiaoyu add section for JQ NIF

## Abstract

Introduce [JQ](https://stedolan.github.io/jq/) syntax to the SQL of emqx rule
engine.

## Motivation

The emqx rule engine now supports a subset of SQL syntax for creating rules. We
also provide a set of of SQL functions for manipulating the data structures.

A common use case is to transform JSON strings from MQTT messages.
The solution now is that first decode the JSON string to Erlang terms using
the sql function `json_decode/1`, assign it to a temporary variable, and then
do the transformations. As a handy way for decoding JSON Object and get the
value of a key, we could use the dot syntax like `payload.x`.

The problem is that the sql functions we provided are too limited to transform
complex JSON strings. For instance if we want to run a lambda for each of the
element of an array, we need the `map/2` or `reduce/3` function, and a sql
syntax for defining a lambda to do the transformation. JQ has done a great work
on this, in a concise syntax. Because JQ has been so widely used it has become
the de facto standard for processing JSON strings, it would be nice if we
introduced it to the emqx rule engine.

## Design

The SQL syntax of emqx rule engine now support a very limited set of operators
to retrieve and set the JSON values.

For example the following code snippet retrieves the value from an MQTT message
recursively:

```
        SELECT payload.a.b[1].c
 Input: {"a": {"b": [{"c": 1}]}}
Output: 1
```

And for updating an JSON object, we override the `AS` operator of SQL syntax.

The following example update a value with key `c` from `1` to `0`:

```
        SELECT 0 as payload.a.b[1].c
 Input: {"a": {"b": [{"c": 1}]}}
Output: {"a": {"b": [{"c": 0}]}}
```

This is straightforward but far from "enough" for processing JSON strings.
JQ provide a simple and clean syntax for the frequently used operations, e.g.:

```
        jq '[.user, .projects[]]'
Input:	{"user":"stedolan", "projects": ["jq", "wikiflow"]}
Output:	["stedolan", "jq", "wikiflow"]
```

Where `[]` is a "collector" for collecting multiple element into a single array,
and the operator `.projects[]` gets all of the values from the array `projects`
as multiple results. This would require several lines of code if we don't use
JQ: first we need to get the values of "user" and "project" and then flatten the
results into a single list.

And here's a more complex example for reducing array to accumulate the numbers:

```
        jq 'reduce .[] as $item ([]; . + [$item.a]) | {"acc": .}'
Input:  [{"a": 1}, {"a": 2}, {"a": 3}]
Output: {"acc": [1,2,3]}
```

### Timeout

Having a timeout when executing JQ code in the rule engine is important because
JQ programs can potentially execute forever (JQ is a Turing complete
programming language that allows recursive functions). JQ programs that execute
forever or a very long time are probably buggy and could cause performance
and debugging problems.

Additionally, if one allowed JQ programs to execute forever, one would need
a way to terminate them, for example, if a user want to manually terminate a JQ
program. This could be tricky and time consuming to implement as one would need
an interface to monitor JQ programs and terminate specific ones.

### Suggested JQ Syntax in Rule SQL

We'd better use JQ along with the rule SQL, as it is common to use the output of
a SQL function as the input of JQ, or to assign the output of JQ to an SQL
variable and then SELECT it as part of the SQL result.

One way is use JQ as a normal SQL function, e.g.:

```
SELECT
    jq('reduce .[] as $item ([]; . + [$item.a]) | {"acc": .}',
        payload) as result
```

The above suggestion has been added to the rule engine in the 5.0 release of
EMQX. The second argument in the implementation can be a non-string value as in
the example above. The second argument can also be a JSON value encoded as a
string, in which case the function will automatically transform the argument to
the encoded value before it sent to the JQ program. An implicit timeout which
can be configured with the `rule_engine.jq_function_default_timeout` setting is
used to timeout the JQ function after a certain amount of time. A JQ function
that takes three arguments has also been added in the 5.0 release. The third
argument can be used to explicitly specify a timeout in milliseconds.

To make the code cleaner, we could create an SQL keyword for JQ, this way
we can remove the surrounding quotes out of the JQ filters:

```
SELECT
    JQ payload
    DO
        reduce .[] as $item ([]; . + [$item.a])
        | {"acc": .}
    END
```

As JQ can read input from the environment variables, we could simplify it more
by setting all the available SQL variables into JQ filters as ENVs:

```
SELECT
    JQ
        $ENV.payload
        | reduce .[] as $item ([]; . + [$item.a])
        | {"acc": .}
    END
```

The `JQ` clause doesn't have to be used in the `SELECT` clause of SQL. If we put
`JQ` clause before the `SELECT`, it would look even better:

```
JQ
    .payload
    | reduce .[] as $item ([]; . + [$item.a])
    | {"acc": .}
SELECT
    acc[1] as first
```

This way we use the output of the `JQ` as the input of `SELECT`. The above code
snippet will output `{"first": 1}`.

The only problem now is we can not utilize the existing SQL functions.
Then we change it again by simply putting the `JQ` clause behind the `SELECT`:

```
SELECT
    decode(payload) as p
JQ
    .p
    | reduce .[] as $item ([]; . + [$item.a])
    | {"acc": .}
    | {first: (.acc|.[0])}
```

This example does exactly what the previous example do. The SELECT clause can
only output a single map result, and the map will then be piped to the JQ clause.

I am happy with this syntax now.

### Update 2022-06-09:

Another suggestion has recently been discussed. This option is to support
multiple languages for writing rule engine programs. One of those languages
could be JQ and one could be the current SQL based language. With this
suggestion the user would need to select which language to use. This could be
done with a dropbox in the GUI interface for adding rules. Here are some
advantages with this suggestion:

* It is future proof as it would be easy to add a third language in the future
* The syntax of each individual language would be less cluttered as one would
  not need to combine the SQL based language with JQ
* Implementation is simple (one does not need to extend the SQL based language)

If this suggestion is chosen, one could also add a feature that would make it
possible to pipe the output of one rule engine program to another. For example,
the user might want to pipe the output of a JQ rule engine program to one
written in the SQL based language. This could be useful, for example, if one
wants to use the FOREACH statement to output multiple messages from a single
message, or if one want to use a function that exists in the SQL based language
but not in JQ.

### Introduce JQ as Port, NIF or Compiled BEAM Code

JQ is written in portable C as a single binary, reading command line argument
from stdin and outputting results to the stdout. It supports Linux, OS X,
FreeBSD, Solaris, and Windows for now, so the simplest way is to package the `jq`
binary along with all of the emqx installation packages, and talk to `jq` using
the [erlang port](http://erlang.org/doc/tutorial/c_port.html). For someone who
is building emqx from source code of emqx repo, he can put the jq binary in to
the right path according to the configuration.

The second approach is NIF, with the drawback of more changes to the code (compile
the code to a dynamic C library rather than a single binary), and safety (it
brings down the entire erlang system on crash, and may hold up the erlang
scheduler if it returns too late). But this way has the benefit of efficiency
and no independent `jq` binary is required.

### Update 2022-06-09:

There have recently been discussions about compiling JQ programs to BEAM
bytecode. Here are some of the benefits one might get from doing that:

* Speed - No context switching (between BEAM code and port or dirty NIF thread),
  and running JITed BEAM code will probably be faster than running interpreted
  JQ byte code
* Fairness - BEAM code is run on a main Erlang scheduler and preemted in the
  same way as compiled Erlang code 
* Tools - This would play well with the Erlang VM's tools for tracing and
  performance measuring and so on
* Safety - Running BEAM code is safer than a NIF as a NIF can crash the VM,
  cause hard to debug problems, and leak memory

One could get some of the benefits mentioned above by making the NIF
implementation yielding. However this would be a lot of work (even though some
of the work could be automated with
(YCF)[https://github.com/kjellwinblad/yielding_c_fun]), and would
make upgrades of the JQ library more difficult.

Compiling JQ code to BEAM code would probably be quite straightforward. Both JQ
and Erlang are functional languages. One option is to make use of the JQ
compiler (which can be exposed to Erlang as a Port program) to transform JQ
code to JQ bytecode and then one only have to implement a transformation of JQ
bytecode to BEAM bytecode. This is probably easier than transforming JQ code
to BEAM bytecode without an intermediate step.

### A try for using JQ as NIF

An Erlang NIF library has been create at https://github.com/terry-xiaoyu/jqerl.

It is now at the very early stage and is not well-tested.
It requires the `jqlib`, so before using the library you should install the
`jq` (version 1.6) on your system, and make sure the `libjq.a` can be found
in `/usr/local/lib`.

The NIF now can only parse JSON strings, the argument `--raw-input` maybe supported
in the later version.

Here's a quick look of the NIF:

```
rebar3 shell
...

1> jqerl:parse(<<".a">>, <<"{\"b\": 1}">>).
{ok,[<<"null">>]}

2> jqerl:parse(<<".a">>, <<"{\"a\": {\"b\": {\"c\": 1}}}">>).
{ok,[<<"{\"b\":{\"c\":1}}">>]}

3> jqerl:parse(<<".a|.[]">>, <<"{\"a\": [1,2,3]}">>).
{ok,[<<"1">>,<<"2">>,<<"3">>]}
```

If very thing is OK, the API `jqerl:parse/2` always returns a list as the second
element of the tuple, because jq may have multiple outputs.

If there's some error in the jq filter or the json string, `{error, Reason}` will
be returned:

```
1> jqerl:parse(<<".a">>, <<"{\"a\": ">>).
{error,{jq_err_parse,<<"Unfinished JSON term at EOF at line 1, column 6 (while parsing '{\"a\": ')">>}}
```

### Update 2022-06-09:

"https://github.com/terry-xiaoyu/jqerl" has been moved to
"https://github.com/emqx/jq". The library has also been extended so that the
interface supports both a NIF based backend and port based backed. The user can
configure which backend to use. The port based one is safer (as it cannot crash
the Erlang VM and cannot cause memory leaks and memory fragmentation inside the
VM) but the NIF backend is faster. At the time of writing, the JQ function in
the rule engine can only use the port based backend as this backend is
currently the only one that supports timeouts. There is a plan to also support
timeouts in the NIF based backend. When that is possible, EMQX users should be
given the option to configure which backend to use.

## Configuration Changes

If we are about to use erlang port to talk to the independent `jq` command line
tool, then we need a configuration entry for specify the path of the `jq` binary.

Otherwise no configuration change is required.

## Backwards Compatibility

There's no backward compatibility problems.

## Document Changes

The JQ can be used in the following syntax:

```
SELECT
    *
JQ
    {u: .username, c: .clientid}
FROM
    "t/1"
```

This outputs `{"u": "Shawn", "c": "00001"}` if the user "Shawn" with client-id
"00001" publishes a message to "t/1".

You can learn more about JQ [here](https://stedolan.github.io/jq/).

## Testing Suggestions

Benchmarking for processing large JSON strings using the new JQ syntax is
required.

## Declined Alternatives

Another way to process JSON strings in SQL is to provide more SQL functions or
SQL keywords, just like how the jq does. But this would be too complicated and
the syntax we created is hard to beat the JQ. The idea is that it's better to
use the well-tested library to do the work, rather than spend time reinventing
the wheels.

## Status 2022-06-09: JQ Function Added to the Rule Engine in the EMQX 5.0 Release


In the EMQX 5.0 release, we have introduced JQ functions to EMQX's SQL based
rule engine language. This is the first suggestion discussed in the "Suggested
JQ Syntax in Rule SQL" section above. Please read the first part of the
"Suggested JQ Syntax in Rule SQL" Section for more details about the added
functions.

This way of introducing JQ to the rule engine was chosen as it makes it possibe
to use JQ in the rule engine without invalidating any of the other suggestions
for extending the syntax of the rule engine.
