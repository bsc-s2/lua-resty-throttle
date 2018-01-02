local collector = require('throttle.collector')
local json = require('acid.json')
local model = require('throttle.model')
local time = require('acid.time')
local util = require('throttle.util')
local websocket_client = require('resty.websocket.client')


local _M = {}


local subjects = {
    model.CONSUMPTION_PREFIX,
    model.REJECTION_PREFIX,
}


local function update_quota(quota, new_quota, slot_number)
    for service_name, new_service_quotas in pairs(new_quota) do
        local service_quotas = quota[service_name]

        for new_slot, new_service_quota in pairs(new_service_quotas) do
            new_slot = tonumber(new_slot)
            service_quotas[new_slot] = new_service_quota
        end

        util.remove_outdated_slot(service_quotas, slot_number,
                                  model.nr_quota_slot)
    end

    ngx.log(ngx.INFO, string.format(
            'throttle=> %d at ms: %d, updated quota',
            slot_number, time.get_ms(), slot_number))
    return
end


local function fetch_from_shared_dict(context, slot_number)
    local quota_key = util.get_quota_key(slot_number)

    for _ = 1, 6 do
        ngx.sleep(0.1)

        local new_quota = util.shared_dict_read(context.shared_dict,
                                                quota_key)
        if new_quota ~= nil then
            update_quota(context.quota, new_quota, slot_number)
            return
        end
    end

    ngx.log(ngx.ERR, string.format(
            'throttle=> %d at ms: %f, new quota still not in shared dict',
            slot_number, time.get_ms(), quota_key))
    return
end


local function connect_one_ip(signer, ws, ip, port)
    local request = {
        verb = 'GET',
        uri = '/throttle',
        headers = {
            Host = string.format('%s:%d', ip, port),
        },
    }

    local auth_ctx, err, errmsg = signer:add_auth_v4(
            request, {query_auth=true})
    if err ~= nil then
        return nil, err, errmsg
    end

    local uri = string.format('wss://%s:%d%s', ip, port, request.uri)

    local ok, err = ws:connect(uri)
    if not ok then
        return nil, 'WebsocketConnectError', string.format(
                'failed to connect to: %s, %s', uri, err)
    end

    local ws_conn = {
        ws = ws,
        uri = uri,
        auth_ctx = auth_ctx,
    }

    return ws_conn, nil, nil
end


local function communicate_one_ip(signer, ip, port, message)
    local ws, err = websocket_client:new()
    if err ~= nil then
        return nil, 'NewWebsocketError', string.format(
                'failed to new websocket client: %s', err)
    end

    ws:set_timeout(200) --200 ms

    local ws_conn, err, errmsg = connect_one_ip(signer, ws, ip, port)
    if err ~= nil then
        return nil, err, errmsg
    end

    local text_message, err = json.enc(message)
    if err ~= nil then
        return nil, 'JsonEncodeError', string.format(
                'failed to json encode message: %s', err)
    end

    ngx.log(ngx.INFO, string.format(
            'throttle=> at ms: %d start to report to %s',
            time.get_ms(), ws_conn.uri))

    local _, err = ws_conn.ws:send_text(text_message)
    if err ~= nil then
        return nil, 'WebsocketSendTextError', string.format(
                'failed to send text to %s: %s', ws_conn.uri, err)
    end

    local data, typ, err  = ws_conn.ws:recv_frame()
    if err ~= nil then
        return nil, 'WebsocketRecvFrameError', string.format(
                'failed to recv frame from %s: %s, %s',
                ws_conn.uri, err, ws_conn.auth_ctx.canonical_request)
    end

    if typ == 'close' then
        ws_conn.ws:send_close()
        return nil, 'WebsocketPeerClosed', string.format(
                'peer: %s closed websocket', ws_conn.uri)
    end

    if typ ~= 'text' then
        return nil, 'WebsocketRecvTypeError', string.format(
                'received unexpected type: %s, from: %s', typ, ws_conn.uri)
    end

    ngx.log(ngx.INFO, string.format(
            'throttle=> at ms: %d, received quota from %s',
            time.get_ms(), ws_conn.uri))

    local new_quota, err = json.dec(data)
    if err ~= nil then
        return nil, 'JsonDecodeError', string.format(
                'failed to json decode new quota: %s', err)
    end

    ws_conn.ws:set_keepalive(20 * 1000, 64)
    return new_quota, nil, nil
end


local function communicate(context, message)
    local port = context.central.port

    local master_ip = context.central.master_ip
    if master_ip ~= nil then
        local new_quota, err, errmsg = communicate_one_ip(
                context.central.signer, master_ip, port, message)
        if err ~= nil then
            ngx.log(ngx.INFO, string.format(
                    'throttle=> failed to get new quota from: %s, %s, %s',
                    master_ip, err, errmsg))
        else
            return new_quota, nil, nil
        end
    end

    local ips, err, errmsg = context.get_central_ips()
    if err ~= nil then
        return nil, err, errmsg
    end

    context.central.ips = ips

    for _, ip in ipairs(ips) do
        local new_quota, err, errmsg = communicate_one_ip(
                context.central.signer, ip, port, message)
        if err ~= nil then
            ngx.log(ngx.INFO, string.format(
                    'throttle=> failed to get new quota from: %s, %s, %s',
                    ip, err, errmsg))
        else
            context.central.master_ip = ip
            return new_quota, nil, nil
        end
    end

    return nil, 'NoCentralAvailable', string.format(
            'throttle=> failed to get new quota from any of central: %s',
            table.concat(ips, ' ,'))
end


local function set_keys_if_not_exist(worker_sum_data, active_services)
    for _, subject in ipairs(subjects) do
        if worker_sum_data[subject] == nil then
            worker_sum_data[subject] = {}
        end

        local subject_table = worker_sum_data[subject]

        for _, service_name in ipairs(active_services) do
            if subject_table[service_name] == nil then
                subject_table[service_name] = {}
            end
        end
    end
end


local function _report_and_fetch(context)
    local ms = time.get_ms()
    local slot_number = math.floor(ms / 1000)
    ngx.log(ngx.INFO, string.format(
            'throttle=> %d at ms: %d, start to report', slot_number, ms))

    if context.worker_id ~= 0 then
        return fetch_from_shared_dict(context, slot_number)
    end

    local worker_sum_data = collector.collect(context.shared_dict,
                                              slot_number - 1)

    set_keys_if_not_exist(worker_sum_data, context.active_services)

    worker_sum_data.slot_number = slot_number
    worker_sum_data.node_id = context.node_id

    local new_quota, err, errmsg = communicate(context, worker_sum_data)
    if err ~= nil then
        ngx.log(ngx.ERR, string.format(
                'throttle=> %d failed to get new quota: %s, %s',
                slot_number, err, errmsg))
        return
    end

    ngx.log(ngx.INFO, string.format(
            'throttle=> %d at ms: %d, got new quota',
            slot_number, time.get_ms()))

    local quota_key = util.get_quota_key(slot_number)
    util.shared_dict_write(context.shared_dict, quota_key,
                           new_quota, {exptime=3})

    update_quota(context.quota, new_quota, slot_number)
    return
end


local function get_report_delay_time()
    local ms = time.get_ms()
    -- delay extra 50 ms
    local delay_time_ms = (1000 - (ms % 1000)) + 50
    return delay_time_ms / 1000
end


local function report_and_fetch(premature, context)
    if premature then
        ngx.log(ngx.INFO, 'throttle=> report and fetch timer premature')
        return
    end

    local ok, err = pcall(_report_and_fetch, context)
    if not ok then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to report and fetch: %s', err))
    end

    local delay_time = get_report_delay_time()

    local ok, err = ngx.timer.at(delay_time, report_and_fetch, context)
    if not ok then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to init report and fetch timer: %s', err))
    end
end


function _M.init_report_and_fetch(context)
    local delay_time = get_report_delay_time()

    local ok, err = ngx.timer.at(delay_time, report_and_fetch, context)
    if not ok then
        ngx.log(ngx.ERR, string.format(
                'throttle=> failed to init report and fetch timer: %s', err))
    end
end


return _M
