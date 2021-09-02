# An Example of EMQ X Improvement Proposal

## Changelog

* 2021-09-02: @zhongwencool init draft

## Abstract

The HTTP REST API implementation generates swagger spec directly from the code, without the need to maintain an additional swagger spec document.

## Motivation

To implement the HTTP REST API interface, the developer needs to maintain a separate swagger spec in top of the implementation code, which is completely separate from the code and is difficult to update and maintain. Manually updating the swagger spec is intricate and error-prone. This proposal proposes to generate swagger spec by code, and swagger schema can reuse the schema in hocon, so that it is also convenient to do entry checking by automatic schema.

## Design

### Plain style example

1. Defining the code SPEC specification

   ```erlang
   ## plain style
   spec("/login") ->
       #{post => #{
           tags => [dashboard],
           description => <<"Dashboard Auth">>,
           summary => <<"Dashboard Auth Summary">>,
           requestBody => #{
               <<"username">> => prop(string(), <<"username desc">>, <<"admin">>),
               <<"password">> => prop(string(), <<"password desc">>, <<"public">>)
           },
           responses => #{
               200 => #{
                   description => <<"Dashboard Auth successfully">>,
                   content => #{
                       <<"token">> => prop(string(), <<"JWT token">>, <<"token">>),
                       <<"version">> => prop(string(), <<"EMQX verison">>, <<"5.0.0">>),
                       <<"license">> => prop(#{<<"edition">> => prop(union(community, enterprise), <<"Edition Desc">>, community)},
                           <<"License Desc">>)
                   }},
               401 =>
               #{description => <<"Dashboard Auth failed">>,
                   content => #{
                       <<"code">> => prop(union('PASSWORD_ERROR', 'USERNAME_ERROR'), <<"password or username error">>, 'PASSWORD_ERROR'),
                       <<"message">> => prop(string(), <<"specific messages">>, <<"Password not match">>)}
               }},
           security => []
       }};
   
   ```

2. According to the SPEC above, swagger SPEC can be generated.

   ```json
   /login: {
   post: {
       description: "Dashboard Auth",
       summary: "Dashboard Auth Summary",
       parameters: [ ],
       requestBody: {
             content: {
               application/json: {
                schema: {
                 properties: {
                   password: {description: "passwword desc",type: "string", default: "public"},
                   username: {description: "username desc",type: "string", default: "admin"}},
                 type: "object"}}}},
       responses: {
         200: {
           content: {
             application/json: {
             schema: {
             properties: {
             license: {
                properties: {
                  edition: {description: "License",enum: ["community","enterprise"],type: "string"}},
               type: "object"},
             token: {description: "JWT Token",type: "string", default: "token"},
             version: {type: "string", default: "5.0.0"}},
           type: "object"}}},
           description: "Dashboard Auth successfully"
         },
         401: {
           content: {
             application/json: {
             schema: {
             properties: {
             code: {description: "password ...",enum: ["PASSWORD_ERROR","USERNAME_ERROR"],type: "string"},
             message: {type: "string"}},type: "object"}}},
             description: "Dashboard Auth failed"
         }
       },
   security: [ ],
   tags: ["dashboard"]}
   }
   ```

3. The developer writes the specific implementation code, due to the entry check has been done by the code SPEC above, so the specific implementation code can be used directly without parameter verification.

   ```erlang
   login(post, #{body := Params}) ->
       #{<<"username">> := Username, <<"password">>  := Password} = Params,
       case emqx_dashboard_admin:sign_token(Username, Password) of
           {ok, Token} ->
               Version = iolist_to_binary(proplists:get_value(version, emqx_sys:info())),
               {200, #{token => Token, version => Version, license => #{edition => ?RELEASE}}};
           {error, Code} ->
               {401, #{code => Code, message => <<"Auth filed">>}}
       end.
   ```

### Scheme Style example

Defining the code SPEC specification：

```erlang
spec("/schema/style/:id") ->
    #{get => #{
        description => "List authorization rules",
        parameters => #{
            path => [param(id, range(1, 100), #{description => "rule id", default => 20, example => 200})],
            query => [param(username, schema(<<"username">>), #{required => false})],
            header => [param('X-Request-ID', schema(<<"x-reqeust-id">>), #{required => false})]
        },
        responses => #{
            200 => resp(list(from_hocon_spec(emqx_rule, rule), #{description => "ok"}),
            400 => resp(schema(<<"rule_400">>))}
    }}
```

We can define our own schema(`schema(<<"username">>)`),  or reuse the hocon spec's schema (`from_hocon_spec(emqx_rule,rule)`).



We no longer need to update swagger.json manually.

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

## Declined Alternatives

Here goes which alternatives were discussed but considered worse than the current.
It's to help people understand how we reached the current state and also to
prevent going through the discussion again when an old alternative is brought
up again in the future.

