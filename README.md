<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
#   Table of Content

- [Name](#name)
- [Status](#status)
- [Description](#description)
- [Synopsis](#synopsis)
- [Methods](#methods)
  - [init](#init)
  - [consume](#consume)
  - [throttle](#throttle)
- [Author](#author)
- [Copyright and License](#copyright-and-license)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

Name
====

lua-resty-throttle


Status
======

This library is considered production ready.

Description
===========

This Lua library must be used with module [throttle_central](https://github.com/baishancloud/throttle_central).
This library mainly save the amount of resource consumed by each user
in every second on this node, and report such info to a central node
periodically, on response of report, it receive the quota of each resource
for each user on this node.

Before actually process request of customer, compare the quota with amount
of resource actually consumed, if exceed, request will be rejected.

Synopsis
========

```lua
    http {
        lua_shared_dict throttle 100m;

        init_worker_by_lua_block {
            local get_central_ips = function()
                return {'1.2.3.4', '3.4.5.6'}
            end

            local opts = {
                active_services = {'front'},
                shared_dict_name = 'throttle',
                get_central_ips = get_central_ips,
                central_port = 7070,
                node_id = 'id_of_this_node',
                access_key = 'access key of wsjobd proxy',
                secret_key = 'secret key of wsjobd proxy',
            }

            local throttle_node = require('resty.throttle.node')
            throttle_node.init(opts)
        }

        server {

            log_by_lua_block {
                local throttle_node = require('resty.throttle.node')
                local consumed = {
                    traffic_up = 1024 * 1024,
                    traffic_down = 0,
                    database_read = 3,
                    database_write = 4,
                }
                throttle_node.consume('front', 'user_foo', consumed)
            }

            location /test {
                rewrite_by_lua_block {
                    local throttle_node = require('resty.throttle.node')
                    local _, err, err_msg = throttle_node.throttle('front', 'user_foo')
                    if err ~= nil then
                        ngx.status = 429
                        ngx.say('too many request')
                        ngx.exit(ngx.HTTP_OK)
                    end

                    ...
                }
            }
        }
```

Methods
=======

[Back to TOC](#table-of-contents)

init
---
`syntax: throttle.node.init(opts)`

init report timer

The `opts` is a Lua table holding the following optional keys:

* `central_port`

    the socket port use which to connect to central node proxy.

* `access_key`

    the aws v4 auth access key to use when communicating with central node proxy.
    if you do not authenticate request on server side, set it to any string.

* `secret_key`

    the aws v4 auth secret key to use when communicating with central node proxy.
    if you do not authenticate request on server side, set it to any string.

* `get_central_ips`

    a callback function used to get ips of central nodes.

* `shared_dict_name`

    the name of ngx shared dict, which will be used to save consumption info.

* `node_id`

    the id of the current node.

* `active_services`

    a list of service names that are currently in use.


consume
---
`syntax: throttle.node.consume(service_name, user_name, consumed)`

The `service_name` is the name of the service, such as 'front'.

The `user_name` specify who sent this request, or the request belongs to
    which user.

The `consumed` is a Lua table holding the following optional keys:

* `traffic_up`

    specify how many bytes in this request sent from client to server.

* `traffic_down`

    specify how many bytes in this request sent from server to client.

* `database_read`

    specify how many times in this request read from database.

* `database_write`

    specify how many bytes in this request wrote to database.


throttle
---
`syntax: _, err, err_msg = throttle.node.throttle(service_name, user_name)`

The `service_name` is the name of the service, such as 'front'.

The `user_name` specify who sent this request, or the request belongs to
    which user.

This function check if the user have used more resource than the amount
allowed in this second, return error if true.


Author
======

Renzhi (任稚) <zhi.ren@baishancloud.com>.

[Back to TOC](#table-of-contents)

Copyright and License
=====================

The MIT License (MIT)

Copyright (c) 2016 Renzhi (任稚) <zhi.ren@baishancloud.com>

[Back to TOC](#table-of-contents)
