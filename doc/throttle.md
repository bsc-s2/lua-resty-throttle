## 系统模块组成

系统由两个主要模块组成.

### 端节点模块

命名为throttle_node模块，对应的文件文throttle/node.lua, 该模块会将对应节点
上每个用户每秒所消耗的各种资源的数量保存在共享内存中，并在每秒结束后将这些
信息汇报给中心节点，同时接收中心节点返回的该节点上每个用户允许使用的各种资
源的数量。

### 中心节点模块

命名为throttle_central模块，由python代码实现, 该模块接收所有端节点汇报的信息,
在收到到汇报信息后返回对应端节点上允许使用的资源配额。

## 名词解释

### 中心节点

中心节点可能不只一个，但是同一时刻，只有其中一个在工作，其他的作为备份。中心
节点是安装了中心节点模块代码的节点。

### 端节点

端节点是指安装了端节点模块代码的节点，是接收处理用户请求的节点。

### slot_number

时间按秒划分成不同的slot，每秒为一个slot，slot_number为时间戳的整数部分。

### bucket

桶为一个存放资源的容器，桶的大小代表可存放资源数量的上限，也代表可积累
的资源的数量。桶可以用一个整数表示，该整数可以为负数，且没有下限。

## 数据结构定义

### consumption/rejection

consumption 和 rejection 均为字典类型。comsumption用于保存不同service中
不同用户消耗不同资源的数量。rejection用于保存不同service中，不同用户因为
某种资源不足而被拒绝的次数。

下面的'front'和'storage'是不同的service，service的名字可以随意取，不同
service之间的资源控制是完全独立的，通常情况只有一个service。

``` python
consumption/rejection = {
    'front': {
        'user_1': {
            'traffic_up': 0,
            'traffic_down': 0,
            'database_read': 0,
            'database_write': 0,
        },
        'user_2': {
        },
        ....
    },
    'storage': {
    }
}
```

### quota

quota 为字典类型，用于保存不同service中，每个slot中，不同用户可以使用的
每种资源的数量。

``` python
quota = {
    'front': {
        '1508985220': {
            'user_1': {
                'traffic_up': 100 * 1024 * 1024,
                'traffic_down': 50 * 1024 * 1024,
                'database_read': 2000,
                'database_write': 1000,
            },
            'user_2': {
            },
            ....
        },
        '1508985221': {
        },
    },
}
```

## 实现

### 端节点模块

#### 资源消耗信息的保存

在每个slot中，不同service中，不同用户所消耗的不同资源的数量以key-value对的
形式保存在共享内存中,使用的key为：
`consumption/<slot_number>/<service_name>/<user_name>/<resource_name>`,
保存的值为一个整数。使用'shared_dict:incr()'函数将实际消耗值不断累加到该值中。

#### 拒绝次数的保存

在每个slot中，不同service中，不同用户因某种资源不足而被拒绝的次数以key-value对
的形式保存在共享内存中，使用的key为：
`rejection/<slot_number>/<service_name>/<user_name>/<resource_name>`,
保存的值为一个整数。使用'shared_dict:incr()'函数更新该值，每拒绝一次，加1。

#### 信息收集汇总

当每秒结束进入下一个slot后，需要将上一个slot的信息收集汇总发送给中心节点。
收集汇总的方法为从共享内存中读取`<slot_number>`为上一个slot的所有key的值，
构建出consumption 和 rejection 结构字典。

#### 信息汇报，接收quota

在上一步构建出consumption 和 rejection 结构字典后，将其通过websocket协议发送
给中心节点，中心节点会返回一个quota结构字典，将quota字典保存在共享内存中，并
最终同步到每个nginx worker进程的内存中。

#### consume接口

在请求处理的log phase（log_by_lua_block中）调用consume接口将用户在此次请求
中所消耗的每种资源的数量累加到共享内存中对应的key中。

#### throttle接口

在开始处理用户请求之前，调用throttle接口判断当前slot中用户对某种资源的消耗
量是否超过了quota中所指定的值。如果超过，该接口会返回错误，不应当再继续
处理当前请求。

当前slot中用户对某种资源的消耗量为共享内存中key：
`consumption/<slot_number>/<service_name>/<user_name>/<resource_name>`
对应的值。

quota中指定的值为：
`quota[<service_name>][<slot_number>][<user_name>][<resource_name>]`

#### 设置ngx.timer

使用ngx.timer实现在每次进入新的slot后，完成上个slot中信息的收集，汇总，汇报
和接收中心节点返回的quota。设置ngx.timer的代码在
'throttle.communicate.init_report_and_fetch()'函数中，通过在
'init_worker_by_lua_block'中调用'throttle.node.init()'函数完成该timer设置。

### 中心节点模块

见[中心节点模块实现文档](https://github.com/baishancloud/throttle_central/blob/master/doc/throttle_central.md)
