# Ping-DNSync

基于 Ping / TCPing / HTTPing 检活的 Cloudflare DNS 自动同步工具。

从 IP 列表读取目标 → 并发检测存活 → 自动增删 Cloudflare DNS A 记录，实现简易的 DNS 负载均衡。

## 功能

- **三模式** — ICMP Ping、TCP Ping、HTTP Ping，一个变量切换
- **并发检测** — 可配置并发数，批量 IP 快速完成
- **质量过滤** — 可选的延迟和丢包率门槛，不达标自动排除
- **智能同步** — 只增删有变化的记录，保持不变的不动
- **安全阀** — 存活率过低时中止操作，防止网络故障导致误删

## 文件结构

```
Ping-DNSync/
├── ping-dnsync.sh        # 主脚本
├── ping_ip_list.txt      # Ping 模式 IP 列表
├── tcping_ip_list.txt    # TCPing 模式 IP 列表
├── httping_ip_list.txt   # HTTPing 模式 IP 列表
├── tcping                # TCPing 二进制 (仅 tcping 模式需要)
├── LICENSE               # GPL-3.0
├── LICENSE-tcping        # tcping 许可证
├── data/                 # 运行时数据 (自动创建)
└── sync.log              # 当次运行日志 (自动创建)
```

## 快速开始

### 1. 下载

```bash
git clone https://github.com/mintdesu/Ping-DNSync.git
cd Ping-DNSync
chmod +x ping-dnsync.sh
```

### 2. 配置

编辑 `ping-dnsync.sh` 顶部的配置区：

```bash
CF_API_TOKEN="你的_API_Token"    # Cloudflare API Token (权限: Zone.DNS.Edit + Zone.Read)
DOMAIN="example.com"              # 根域名
SUBDOMAIN="lb.example.com"        # 负载均衡子域名
```

### 3. 填写 IP 列表

**Ping 模式** — 编辑 `ping_ip_list.txt`，每行一个 IP：

```
1.1.1.1
1.0.0.1
8.8.8.8
```

**TCPing 模式** — 编辑 `tcping_ip_list.txt`，每行一个 IP:端口：

```
1.1.1.1:443
1.0.0.1:80
8.8.8.8:53
```

**HTTPing 模式** — 编辑 `httping_ip_list.txt`，每行一个 URL：

```
https://1.2.3.4
https://5.6.7.8:8443
http://1.2.3.4
http://9.10.11.12:8080
```

不带端口时 https 默认 443，http 默认 80。

#### 判定模式

通过 `HTTPING_MODE` 控制什么样的 HTTP 响应算"存活"：

| 模式 | 存活条件 | 适用场景 |
|------|----------|----------|
| `strict` | 仅 2xx | 要求服务完全正常响应（默认） |
| `standard` | 2xx + 3xx | 允许重定向 |
| `loose` | 任何 HTTP 响应 | 只要服务器有回应就算存活 |

#### Host 头

```bash
HTTPING_HOST=""              # 留空: 不附带 Host 头
HTTPING_HOST="example.com"   # 附带 Host: example.com
```

**为什么需要这个？** 很多服务器上同一个 IP 会托管多个网站（虚拟主机）。当你用 `https://1.2.3.4` 直接访问 IP 时，服务器不知道你想访问哪个网站，通常会返回 403、404 或者一个默认页面，而不是你期望的 200。

设置 `HTTPING_HOST="example.com"` 后，请求会带上 `Host: example.com` 头，服务器就能正确路由到对应的网站并返回正常响应。

**什么时候不需要设？** 如果每个 IP 上只有一个网站，或者你只关心服务器是否有响应（配合 `loose` 模式），就不用设。

### 4. 运行

```bash
bash ping-dnsync.sh
```

## 模式切换

修改 `CHECK_MODE` 变量：

```bash
CHECK_MODE="ping"      # ICMP Ping 模式, 读取 ping_ip_list.txt
CHECK_MODE="tcping"    # TCP Ping 模式, 读取 tcping_ip_list.txt, 需要 tcping 二进制
CHECK_MODE="httping"   # HTTP Ping 模式, 读取 httping_ip_list.txt, 需要 curl
```

TCPing 模式需要 [pouriyajamshidi/tcping](https://github.com/pouriyajamshidi/tcping) 二进制在脚本同目录，仓库已自带amd64。其他架构请从 [Releases](https://github.com/pouriyajamshidi/tcping/releases) 下载替换。

HTTPing 模式只需要 curl（一般系统自带）。

## 配置说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CF_API_TOKEN` | - | Cloudflare API Token |
| `DOMAIN` | - | 根域名，用于自动查询 Zone ID |
| `SUBDOMAIN` | - | 负载均衡子域名 |
| `PROXIED` | `false` | Cloudflare 代理 (true=橙色云朵) |
| `TTL` | `60` | DNS 记录 TTL (秒) |
| `CHECK_MODE` | `ping` | 检测模式: `ping` / `tcping` / `httping` |
| `HTTPING_MODE` | `strict` | HTTPing 判定模式: `strict` / `standard` / `loose` |
| `HTTPING_HOST` | (空) | HTTPing 请求的 Host 头 (见下方说明) |
| `CHECK_COUNT` | `5` | 每个目标发送探测次数 |
| `CHECK_TIMEOUT` | `2` | 单次探测超时 (秒) |
| `ALIVE_THRESHOLD` | `4` | 至少成功 N 次才算存活 |
| `MAX_LATENCY` | `0` | 最高平均延迟 ms (0=不过滤) |
| `MAX_LOSS` | `0` | 最高丢包率 % (0=不过滤) |
| `SAFETY_ENABLED` | `true` | 安全阀开关 (见下方说明) |
| `SAFETY_THRESHOLD` | `20` | 安全阀可达率阈值 (%) |
| `AUTO_REMOVE_DEAD` | `false` | 自动清理开关 (见下方说明) |
| `PARALLEL` | `10` | 并发检测数 |

## 安全阀

安全阀用于防止本机网络故障时误删所有 DNS 记录。当存活 IP 的比例低于阈值时，脚本会中止同步，不对 DNS 做任何改动。

```bash
SAFETY_ENABLED=true    # 开启安全阀
SAFETY_THRESHOLD=20    # 可达率低于 20% 时中止
```

例如你有 50 个 IP，检测后只有 8 个能通 (16%)，低于 20% 阈值，脚本判定大概率是本机网络有问题而不是 IP 全挂了，直接中止退出。

**什么时候该关掉：** 如果你的 IP 列表很少（比如只有 2-3 个），正常业务下就可能出现大部分不通的情况，这时安全阀会误拦，建议设为 `false`。

## 自动清理

开启后，检测失败（dead）的目标会被自动从 IP 列表文件中删除。默认关闭。

```bash
AUTO_REMOVE_DEAD=true    # 开启自动清理
```

适合 IP 列表经常变动、需要自动淘汰失效 IP 的场景。脚本会在 DNS 同步完成后，逐行匹配并移除不通的目标（ping 模式删 IP，tcping 模式删 IP:端口）。

**注意：** 删除是不可逆的，建议配合安全阀一起使用。如果本机网络故障导致全部检测失败，安全阀会先拦住，不会误清整个列表。

## 定时运行

### crontab

```bash
# 每 12 小时运行一次
0 */12 * * * /你的路径/Ping-DNSync/ping-dnsync.sh
```

### NAS 任务计划

控制面板 → 任务计划 → 新增计划的任务 → 用户自定义脚本：

```bash
bash /你的路径/Ping-DNSync/ping-dnsync.sh
```

## 运行示例

```
[2026-06-07 19:31:00] [INFO ] =================================================
[2026-06-07 19:31:00] [INFO ]   Ping-DNSync - Ping 模式
[2026-06-07 19:31:00] [INFO ]   域名: lb.example.com
[2026-06-07 19:31:00] [INFO ] =================================================
[2026-06-07 19:31:01] [INFO ] Zone ID: 99452965616b485fbf35a342871258e0
[2026-06-07 19:31:01] [INFO ] [2/4] Ping 检测 (x5, >=4 才算存活)
  Target                   Sent     Recv     Loss%    Avg(ms)
  1.1.1.1                  5        5        0.00     2.219
  1.0.0.1                  5        5        0.00     2.445
  8.8.8.8                  5        0        100.00   -
[2026-06-07 19:31:20] [INFO ] 结果: 2 存活 / 1 不通
[2026-06-07 19:31:21] [INFO ]   [=] KEEP     1.1.1.1
[2026-06-07 19:31:21] [INFO ]   [+] ADDED    1.0.0.1
[2026-06-07 19:31:21] [INFO ] =================================================
[2026-06-07 19:31:21] [INFO ]   Ping-DNSync 同步完成
[2026-06-07 19:31:21] [INFO ] =================================================
```

## 依赖

- **bash** / **curl** / **ping** — 系统基础工具
- **[tcping](https://github.com/pouriyajamshidi/tcping)** — TCPing 模式需要，仓库已自带 linux-amd64 版本

## 致谢

- [pouriyajamshidi/tcping](https://github.com/pouriyajamshidi/tcping) — TCP Ping 工具
- [Claude Opus 4.6](https://claude.ai) — 脚本开发协助

## 许可证

本项目: [GPL-3.0](LICENSE)

内置的 tcping 二进制: [MIT License](LICENSE-tcping) — [pouriyajamshidi/tcping](https://github.com/pouriyajamshidi/tcping)
