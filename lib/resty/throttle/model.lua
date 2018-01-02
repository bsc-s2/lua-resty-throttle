local _M = {}

_M.CONSUMPTION_PREFIX = 'consumption'
_M.REJECTION_PREFIX = 'rejection'

_M.TRAFFIC_UP = 'traffic_up'
_M.TRAFFIC_DOWN = 'traffic_down'
_M.DATABASE_READ = 'database_read'
_M.DATABASE_WRITE = 'database_write'

_M.nr_quota_slot = 10

local front_service = {
    resource_dict = {
        [_M.TRAFFIC_UP] = 0,
        [_M.TRAFFIC_DOWN] = 0,
        [_M.DATABASE_READ] = 0,
        [_M.DATABASE_WRITE] = 0,
    },
}

_M.services= {
    front = front_service,
}

return _M
