# Ping-DNSync

基于 Ping / TCPing 检活的 Cloudflare DNS 自动同步工具。

从 IP 列表读取目标 → 并发检测存活 → 自动增删 Cloudflare DNS A 记录，实现简易的 DNS 负载均衡。

## 功能

- **双模式** — ICMP Ping 或 TCP Ping，一个变量切换
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

### 4. 运行

```bash
bash ping-dnsync.sh
```

## 模式切换

修改 `CHECK_MODE` 变量：

```bash
CHECK_MODE="ping"      # ICMP Ping 模式, 读取 ping_ip_list.txt
CHECK_MODE="tcping"    # TCP Ping 模式, 读取 tcping_ip_list.txt, 需要 tcping 二进制
```

TCPing 模式需要 [pouriyajamshidi/tcping](https://github.com/pouriyajamshidi/tcping) 二进制在脚本同目录，仓库已自带amd64。其他架构请从 [Releases](https://github.com/pouriyajamshidi/tcping/releases) 下载替换。

## 配置说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CF_API_TOKEN` | - | Cloudflare API Token |
| `DOMAIN` | - | 根域名，用于自动查询 Zone ID |
| `SUBDOMAIN` | - | 负载均衡子域名 |
| `PROXIED` | `false` | Cloudflare 代理 (true=橙色云朵) |
| `TTL` | `60` | DNS 记录 TTL (秒) |
| `CHECK_MODE` | `ping` | 检测模式: `ping` 或 `tcping` |
| `CHECK_COUNT` | `5` | 每个目标发送探测次数 |
| `CHECK_TIMEOUT` | `2` | 单次探测超时 (秒) |
| `ALIVE_THRESHOLD` | `4` | 至少成功 N 次才算存活 |
| `MAX_LATENCY` | `0` | 最高平均延迟 ms (0=不过滤) |
| `MAX_LOSS` | `0` | 最高丢包率 % (0=不过滤) |
| `SAFETY_ENABLED` | `true` | 安全阀开关 (见下方说明) |
| `SAFETY_THRESHOLD` | `20` | 安全阀可达率阈值 (%) |
| `PARALLEL` | `10` | 并发检测数 |

## 安全阀

安全阀用于防止本机网络故障时误删所有 DNS 记录。当存活 IP 的比例低于阈值时，脚本会中止同步，不对 DNS 做任何改动。

```bash
SAFETY_ENABLED=true    # 开启安全阀
SAFETY_THRESHOLD=20    # 可达率低于 20% 时中止
```

例如你有 50 个 IP，检测后只有 8 个能通 (16%)，低于 20% 阈值，脚本判定大概率是本机网络有问题而不是 IP 全挂了，直接中止退出。

**什么时候该关掉：** 如果你的 IP 列表很少（比如只有 2-3 个），正常业务下就可能出现大部分不通的情况，这时安全阀会误拦，建议设为 `false`。

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
