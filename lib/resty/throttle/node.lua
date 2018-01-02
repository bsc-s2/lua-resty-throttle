local aws_signer = require('resty.awsauth.aws_signer')
local communicate = require('throttle.communicate')
local model = require('throttle.model')
local time = require('acid.time')
local util = require('throttle.util')


local _M = {}


function _M.init(opts)
    opts = opts or {}

    local context = {
        central = {
            port = opts.central_port or 22347,
            -- master ip is the ip of the central node which have got lock
            master_ip = nil,
            ips = nil,

            access_key = opts.access_key,
            secret_key = opts.secret_key,

            -- signer of aws signature version 4
            signer = nil,
        },
        get_central_ips = opts.get_central_ips,

        shared_dict_name = opts.shared_dict_name,
        shared_dict = nil,

        node_id = opts.node_id,
        worker_id = ngx.worker.id(),

        -- the services this nginx using, one nginx may not use all the services
        -- defined in model.services
        active_services = opts.active_services,

        -- quota save resource quota for this node,
        -- received from central node
        quota = {},
    }

    context.shared_dict = ngx.shared[context.shared_dict_name]
    if context.shared_dict == nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> shared dict: %s not exist',
                context.shared_dict_name))
        return
    end

    local signer, err, errmsg = aws_signer.new(
            context.central.access_key, context.central.secret_key)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to new aws signer: %s, %s',
                err, errmsg))
        return
    end

    context.central.signer = signer

    for _, service_name in ipairs(context.active_services) do
        context.quota[service_name] = {}
    end

    _M.context = context

    communicate.init_report_and_fetch(context)

    return
end


local function shared_dict_incr(key, value)
    local shared_dict = _M.context.shared_dict
    if shared_dict == nil then
        return nil, 'SharedDictError', string.format(
                'shared dict: %s not exist', _M.context.shared_dict_name)
    end

    local new_value, err = shared_dict:incr(key, value, 0)
    if err ~= nil then
        return nil, 'SharedDictError', string.format(
                'failed to incr key: %s, %s', key, err)
    end

    return new_value, nil, nil
end


function _M.consume(service_name, user_name, consumed)
    local slot_number = math.floor(time.get_ms() / 1000)

    for resource_name, value in pairs(consumed) do
        if value ~= 0 then
            local key = util.get_shared_dict_key(
                    model.CONSUMPTION_PREFIX, slot_number,
                    service_name, user_name, resource_name)

            local _, err, errmsg = shared_dict_incr(key, value)
            if err ~= nil then
                return nil, err, errmsg
            end
        end
    end
end


local function incr_rejection(slot_number, service_name,
                              user_name, resource_name)
    local key = util.get_shared_dict_key(
            model.REJECTION_PREFIX, slot_number,
            service_name, user_name, resource_name)

    local _, err, errmsg = shared_dict_incr(key, 1)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to incr rejection key: %s, %s, %s',
                key, err, errmsg))
    end

    return
end


function _M.throttle(service_name, user_name)
    local ms = time.get_ms()
    local slot_number = math.floor(ms / 1000)

    local service_quota = _M.context.quota[service_name][slot_number]
    if service_quota == nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> at ms: %d, no %s quota, for slot: %d',
                ms, service_name, slot_number))
        return true, nil, nil
    end

    local user_quota = service_quota[user_name]
    if user_quota == nil then
        ngx.log(ngx.INFO, string.format(
                'at ms: %d, no %s-%s quota, in slot: %d',
                ms, service_name, user_name, slot_number))
        return true, nil, nil
    end

    local shared_dict = _M.context.shared_dict
    if shared_dict == nil then
        ngx.log(ngx.ERR, string.format('shared dict: %s not exist',
                                       _M.context.shared_dict_name))
        return true, nil, nil
    end

    for resource_name, resource_quota in pairs(user_quota) do
        if resource_quota < 1 then
            incr_rejection(slot_number, service_name,
                           user_name, resource_name)
            return nil, 'Throttled', string.format(
                    'quota: %s-%s-%s-%d: %s is less than 1',
                    service_name, user_name, resource_name,
                    slot_number, tostring(resource_quota))
        end

        local key = util.get_shared_dict_key(
                model.CONSUMPTION_PREFIX, slot_number,
                service_name, user_name, resource_name)

        local value, err = shared_dict:get(key)
        if err ~= nil then
            ngx.log(ngx.ERR, string.format(
                    'throttle=> failed to get key: %s, %s, %s', key, err))
        end
        if value ~= nil and value > resource_quota then
            incr_rejection(slot_number, service_name,
                           user_name, resource_name)
            return nil, 'Throttled', string.format(
                    'user: %s, resource: %s exhausted, quota: %d, used: %d',
                    user_name, resource_name, resource_quota, value)
        end
    end

    return true, nil, nil
end


return _M
