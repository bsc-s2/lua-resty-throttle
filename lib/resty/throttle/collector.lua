local model = require('throttle.model')
local strutil = require('acid.strutil')
local tableutil = require('acid.tableutil')
local time = require('acid.time')

local _M = {}

local to_str = strutil.to_str


local valid_prefix = {
    [model.CONSUMPTION_PREFIX] = true,
    [model.REJECTION_PREFIX] = true,
}


local function expire_key(shared_dict, key, value)
    local _, err = shared_dict:set(key, value, 0.001)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to set exptime of key: %s, %s',
                key, err))
    end
end


local function collect_one_key(shared_dict, slot_number, container, key)
    -- consumption/1508985221/front/user_1/traffic_up
    local parts = strutil.split(key, '/', {plain=true})

    if #parts ~= 5 or not valid_prefix[parts[1]] then
        return 'ignore_key'
    end

    local key_slot_number = tonumber(parts[2])

    if key_slot_number < slot_number then
        expire_key(shared_dict, key, 0)
        return 'old_slot'
    elseif key_slot_number > slot_number then
        return 'next_slot'
    end

    local value, err = shared_dict:get(key)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to get key: %s, %s', key, err))
        return 'shared_dict_get_error'
    end

    if value == nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> key: %s not found', key))
        return 'not_found'
    end

    expire_key(shared_dict, key, 0)

    table.remove(parts, 2)
    local key_path = table.concat(parts, '.')

    local _, err, errmsg = tableutil.set(container, key_path, value)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to set: %s, %s, %s',
                key_path, err, errmsg))
        return 'table_set_error'
    end

    return 'collected'
end


function _M.collect(shared_dict, slot_number)
    local start_ms = time.get_ms()

    local all_keys = shared_dict:get_keys(1024)
    if #all_keys == 1024 then
        ngx.log(ngx.ERR, string.format('throttle=> too many keys: %d',
                                       #all_keys))
    end

    local worker_sum_data = {}

    local statistics = {
        totle = #all_keys,
        ignore_key = 0,
        old_slot = 0,
        next_slot = 0,
        shared_dict_get_error = 0,
        not_found = 0,
        table_set_error = 0,
        collected = 0,
    }

    for i, key in ipairs(all_keys) do
        local stat = collect_one_key(shared_dict, slot_number,
                                     worker_sum_data, key)
        statistics[stat] = statistics[stat] + 1
        if i % 50 == 0 then
            ngx.sleep(0.001)
        end
    end

    local flushed = shared_dict:flush_expired()
    ngx.log(ngx.INFO, string.format(
            'throttle=> flushed %d expired keys', flushed))

    local end_ms = time.get_ms()
    local used_ms = end_ms - start_ms
    if used_ms > 100 then
        ngx.log(ngx.ERR, string.format(
                'throttle=> time used for collecting: %d ms, too long',
                used_ms))
    end

    ngx.log(ngx.INFO, string.format(
            'throttle=> collect used %d ms, start: %d, end: %d, %s',
            used_ms, start_ms, end_ms, to_str(statistics)))

    return worker_sum_data
end


return _M
