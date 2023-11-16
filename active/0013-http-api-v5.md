# HTTP API V5.0 Design

## Changelog

* 2021-5-31: @DDDHuang

## Abstract

EMQ X Broker API for V5.0 . Follow Open Api.

## Motivation

Request parameters & Response normalization.

## Design

##### New HTTP Server:

###### 	Support CORS

###### 	Long Connection

###### 	Open API Doc

###### 	Parameter Validate

##### Resource (request path) :

| resource       | identify       | link                          | method                              |
| -------------- | -------------- | ----------------------------- | ----------------------------------- |
| /users         | `username`     |                               | `GET` `POST` `PUT` `DELETE` `PATCH` |
| /clients       | `clientid`     | `/acl-cache` `/subscriptions` | `GET` `POST` `PUT` `DELETE`         |
| /acl-cache     | `clientid`     |                               | `GET` `POST` `PUT` `DELETE`         |
| /subscriptions | `topic`        |                               | `GET` `POST` `PUT` `DELETE`         |
| /nodes         | `node_name`    | `/listeners ` `/plugins`      | `GET` `POST` `PUT` `DELETE`         |
| /listeners     | `listener_id`  |                               | `GET` `POST` `PUT` `DELETE`         |
| /plugins       | `plugin_name`  |                               | `GET` `POST` `PUT` `DELETE`         |
| /rules         | `rule_id`      |                               | `GET` `POST` `PUT` `DELETE`         |
| /actions       | `action_id`    |                               | `GET` `POST` `PUT` `DELETE`         |
| /resources     | `resources_id` |                               | `GET` `POST` `PUT` `DELETE`         |
| /banned        | single         |                               | `GET` `POST`  `DELETE`              |
| /metrics       | single         |                               | `GET`                               |
| /topic-metrics | single         |                               | `GET` `POST`  `DELETE`              |
| /stats         | single         |                               | `GET`                               |
| /alarms        | `name`         |                               | `GET` `POST`  `DELETE`              |
| /publish       | single         |                               | `POST`                              |

##### Resource Ddentify

​	If resource is multi instance, then should have identify.

​	Example:

``` 
## multi instance
/nodes/{nodename}

## single instance
/publish
```

##### Parameter

​	Use lowercase words for parameter name, no `_` prefix. Use `_` as delimiter .

​	Example:

```http
GET /clients?page=1&limit=10
```

```http
POST /users
application/json
{
	"user_name": "emqx_admin",
	"tag": "admin"
}
```

##### Use HTTP response status code

​	Use [HTTP response status code](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status) as much as possible. 

​	When the standard code can not meet the requirements, use  `code` field in the response body as an additional supplement.

##### Requets & Response body :

​	Must be a json.

###### Simple:

​	Success response body is request result. Failed request must have `code` and `message` field, should be debug info or user guide. 

​	`code` field must be all uppercase words and readability , not integer, separated by `_` , like `INTERNAL_ERROR` . If HTTP response code is `500`, then `code` field must be `INTERNAL_ERROR` and  `message`  must be error stack.

​	Example:

```json
// 200
	{"clientid": "e202100", "username": "emqx_admin"}
```

```json
// 404
	{
    "code": "UPDATE_ERROR",
    "message":"clientid e202101 no found"
  }
```

```json
// 500
{
  "code": "INTERNAL_ERROR" ,
 	"message": "exception error: bad argument in function  rpc:rpcify_exception/2 (rpc.erl, line 467)"
}
```

###### 	Bulk:

``` json
// Request: GET /resource/{id}?page=1&limit=10&key=value
// 200
{
  "meta":
  	{
      "page": 1,
      "limit": 10,
      "count": 200
    },
  "data": 
  [
  	{"result_key1": "result_value1"}, 
    {"result_key2": "result_value2"}
  ]
}
```

```json
// Request: POST /subscriptions
[
  {
  "clientId": "c1",
  "topic":"t/t1",
  "qos":1
  },
  {
  "clientId": "c2",
  "topic":"t/t2",
  "qos":1
  },
  {
  "clientId": "c3",
  "topic":"t/t3",
  "qos":1
  }
]

// Response
{
  "success": 1,
  "failed": 2,
	"detail": 
  [
    {
      "param": {
  							"clientId": "c2",
  							"topic":"t/t2",
  							"qos":1
  						 },
      "code": "SUBSCRIBTION_ALREADYY_EXISTED",
      "message": "client c2 already has subscripted topic t/t2"
    },
    {
      "param": {
  							"clientId": "c3",
  							"topic":"t/t3",
  							"qos":1
  						 },
      "code": "SUBSCRIBTION_FAILED",
      "message": "acl deny"
    }
  ]
}

```



## Configuration Changes

## Backwards Compatibility

V5.0 API version `api/v5` not support  `api/v4`

## Document Changes

See API define doc.

## Testing Suggestions

## Declined Alternatives

