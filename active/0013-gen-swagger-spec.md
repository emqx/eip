# An Example of EMQ X Improvement Proposal

## Changelog

* 2021-09-02: @zhongwencool init draft

## Abstract

The HTTP REST API implementation generates swagger spec directly from the code, without the need to maintain an additional swagger spec document.

## Motivation

To implement the HTTP REST API interface, the developer needs to maintain a separate swagger spec in top of the implementation code, which is completely separate from the code and is difficult to update and maintain. Manually updating the swagger spec is intricate and error-prone. This proposal proposes to generate swagger spec by code, and swagger schema can reuse the schema in hocon, so that it is also convenient to do entry checking by automatic schema.

## Design

### Basic Structure

we define a basic structure.

```erlang
paths() -> ["/user/:user_id"].

schema("/user/:user_id") ->
   #{operationId => user}.
```

It defines all the paths of this spec, specify a unique `operationId`.  Using this value to name the corresponding methods in code.

### Operations

For each path, we define operations (HTTP methods) that can be used to access that path. A single path can support multiple operations, for example, `GET /users` to get a list of users and `POST /users` to add a new user. we defines a unique operation as a combination of a path.. Minimal example of an operation:

```erlang
schema("/user/:user_id/:fingerprint") ->
   #{
       operationId => user,
       get => #{response => 
                  #{200 => 
                      hocon:mk(hoconsc:ref(?MODULE, "user"), 
                               #{description => <<"return self user informations">>})}               
    }.
```

Operations also support some optional elements for documentation purposes: `summary, description, tags`.

### Query String in Paths

 Query string paramters is defined as query parameters:

```erlang
#{put =>
  #{
   parameters => [
    {user_id, hoconsc:mk(string(), #{in => path, description => <<"The client ID of your Emqx app">>, example => <<"an long client id">>})},                
    {per_page, mk(range(1, 50), #{required => true, in => query, example => "10"})},
    {is_admin, mk(boolean(), #{required => true, in => query, example => "true"})},  
    {oneof_test_in_query, mk(hoconsc:union([string(), integer()]), #{in => query, example => "a_good_oneof_in_query"})}
   ]}}
```

will generate a swagger json:

```json
parameters: [
   {example: "a_good_oneof_in_query",
    in: "query",
    name: "oneof_test_in_query",
    schema: {
      oneOf: [
        {example: 100,
         type: "integer"},
        {example: "string example",
         type: "string"}]}},
   {example: "true",
    in: "query",
    name: "is_admin",
    required: true,
    schema: {
      example: true,
      type: "boolean"}},
  {example: "10",
   in: "query",
   name: "per_page",
   required: true,
   schema: {
     example: 1,
     maximum: 50,
     minimum: 1,
     type: "integer"}},   
   {description: "The client ID of your Emqx app",
    example: "an long client id",
    in: "path",
    name: "client_id",
    required: true,
    schema: {
      example: "string example",
      type: "string"}}].
```

### Request Body

Request bodies are typically used with “create” and “update” operations (POST, PUT, PATCH). For example, when creating a resource using POST or PUT, the request body usually contains the representation of the resource to be created. OpenAPI 3.0 provides the `requestBody` keyword to describe request bodies.

```erlang
#{requestBody =>
  #{
    client_secret => mk(string(), #{description => <<"The OAuth app client secret for which to create the token.">>, maxLength => 40}),
    scopes => mk(hoconsc:array(string()), #{<<"description">> => "A list of scopes that this authorization is in.", example => ["public_repo", "user"], nullable => true}),
    test => mk(hoconsc:enum([test, good]), #{<<"description">> => "good", example => test}),
    note => mk(string(), #{description => <<"A note to remind you what the OAuth token is for.">>, example => <<"Update all gems">>}),
    note_url => mk(string(), #{description => <<"A URL to remind you what app the OAuth token is for.">>}),
    page => mk(range(1, 100), #{description => <<"Page Description.">>}),
    ip => mk(emqx_schema:ip_port(), #{description => <<"ip:port">>, example => "127.0.0.1:8081"}),
    oneof_test => mk(hoconsc:union([range(1, 100), infinity, hoconsc:ref(?MODULE, client_id)]), #{description => "oneof description", example => "1"})
   }}.
```

 RequestBody is json object. If we have too much nesting, we can use `hoconsc:ref/2` to make the code a little clearer. such as:

`hoconsc:ref(?MODULE, client_id)` will call `?MODULE:fields(client_id)` to get specific schema.

### Responses

```erlang
#{responses => 
  #{
   200 => mk(hoconsc:ref(?MODULE, "authorization"), #{description => <<"if returning an existing token">>}),
   422 => mk(hoconsc:ref(?MODULE, "validation_failed"), #{}),
   400 => mk(hoconsc:array(hoconsc:ref(?MODULE, "authorization")), #{}),
   401 => #{
            total_count => mk(integer(), #{required => true}),
            artifacts => mk(hoconsc:array(hoconsc:ref(?MODULE, "authorization")), #{})
           },
   203 => maps:from_list(emqx_schema:fields("authorization"))
  }}.
```

will generate swagger.json:

```json
responses: {
  200: {
    description: "if returning an existing token",
    content: {application/json: {schema: {$ref: "#/components/schemas/emqx_swagger_api.authorization"}}}},
  203: {description: "",content: {application/json: {schema: {properties: {cache:   
                {$ref:"#/components/schemas/emqx_schema.cache"},
        deny_action: {
            default: "ignore",
            enum: ["ignore","disconnect"],
            type: "string"},
        no_match: {default: "allow",enum: ["allow","deny"],type: "string"}},
        type: "object"}}}},
   400: {
     description: "",
     content: {
     application/json: {
     schema: {items: {$ref: "#/components/schemas/emqx_swagger_api.authorization"},
     type: "array"}}}},
   401: {description: "",content: {application/json: {schema: {required: ["total_count"],
         properties: {
         artifacts: {items: {$ref: "#/components/schemas/emqx_swagger_api.authorization"},type: "array"},
         total_count: {example: 100,type: "integer"}},
         type: "object"}}}},  
   422: {description: "",content: 
         {application/json: {schema: {$ref: "#/components/schemas/emqx_swagger_api.validation_failed"}}}}}
}.
```

Only json format is needed for now

1. The developer writes the specific implementation code, due to the entry check has been done by the code SPEC above, so the specific implementation code can be used directly without parameter verification.

   ```erlang
   user(put, #{body := Params}) ->
       #{<<"ip">> := {IP, Port} = Params, %% the {IP Port} has already converted by schema.
        ....
       {200, #{...response json..}}.
   
   ```

We no longer need to update swagger.json manually. 

We don't check response schema, the repsonse schema only use for generate swagger.json.

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

