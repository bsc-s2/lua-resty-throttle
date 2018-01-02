local json = require('acid.json')
local tableutil = require('acid.tableutil')


local _M = {}


function _M.get_quota_key(slot_number)
    return string.format('quota_%d', slot_number)
end


function _M.get_shared_dict_key(prefix, slot_number, service_name,
                                user_name, resource_name)
    local key = string.format(
            '%s/%d/%s/%s/%s', prefix, slot_number,
            service_name, user_name, resource_name)
    return key
end


function _M.shared_dict_write(shared_dict, key, value, opts)
    opts = opts or {}
    local exptime = opts.exptime or 60 --in seconds

    local json_str, err = json.enc(value)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to json encode value of: %s, %s',
                key, err))
        return false
    end

    local ok, err = shared_dict:set(key, json_str, exptime)
    if not ok then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to set shared dict key: %s, %s',
                key, err))
        return false
    end

    return true
end


function _M.shared_dict_read(shared_dict, key)
    local json_str, err = shared_dict:get(key)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to get shared dict key: %s, %s', key, err))
        return nil
    end

    if json_str == nil then
        return nil
    end

    local value, err = json.dec(json_str)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to json decode value of: %s, %s',
                key, err))
        return nil
    end

    return value
end


function _M.remove_outdated_slot(container, curr_slot_number, nr_slot)
    local slot_to_delete = curr_slot_number - nr_slot

    container[slot_to_delete] = nil

    local keys = tableutil.keys(container)

    -- if exceed nr_slot, we do not clean immediately, only clean when
    -- exceed nr_slot * 2
    if #keys < nr_slot * 2 then
        return
    end

    ngx.log(ngx.ERR, string.format(
            'throttle=> too many slot: %d in container', #keys))

    for _, slot_number in ipairs(keys) do
        if slot_number < curr_slot_number - nr_slot then
            container[slot_number] = nil
        end
    end

    return
end


return _M
