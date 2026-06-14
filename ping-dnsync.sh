#!/bin/bash
# ============================================================================
#  Ping-DNSync
#  基于 Ping/TCPing 检活的 Cloudflare DNS 自动同步工具
#  依赖: bash / curl / ping (ping模式) 或 tcping二进制 (tcping模式)
# ============================================================================

# ──────────────────── Cloudflare 配置 ─────────────────────
CF_API_TOKEN="xxxxxxxxxxxxxxxxxx"
DOMAIN="example.com"                # 根域名 (自动查询 Zone ID)
SUBDOMAIN="lb.example.com"         # 负载均衡子域名
PROXIED=false
TTL=60

# ──────────────────── 检测模式 ─────────────────────────────
# ping   = ICMP Ping (需要 ping 命令)
# tcping = TCP Ping  (需要 tcping 二进制, 放在脚本同目录)
CHECK_MODE="ping"

# ──────────────────── 检测参数 ─────────────────────────────
CHECK_COUNT=5          # 每个目标发送探测次数
CHECK_TIMEOUT=2        # 单次探测超时 (秒)
PING_DEADLINE=18       # ping 总时限 (秒, 仅 ping 模式)
ALIVE_THRESHOLD=4      # 至少成功 N 次才算存活

# ──────────────────── 质量门槛 (0=不过滤) ─────────────────
MAX_LATENCY=0          # 最高平均延迟 (ms)
MAX_LOSS=0             # 最高丢包率 (%)

# ──────────────────── 安全阀 ──────────────────────────────
SAFETY_ENABLED=true    # 是否启用安全阀 (true/false)
SAFETY_THRESHOLD=20    # 可达率低于此百分比时中止同步, 防止误删 (%)

# ──────────────────── 并发/日志 ────────────────────────────
PARALLEL=10            # 同时检测多少个目标

# ============================================================================
# 以下内容无需修改
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TCPING_BIN="${SCRIPT_DIR}/tcping"
LOG_FILE="${SCRIPT_DIR}/sync.log"
DATA_DIR="${SCRIPT_DIR}/data"
LOCK_FILE="${DATA_DIR}/.sync.lock"
LOCK_OWNED=false
PING_RESULT_DIR=""
CF_ZONE_ID=""

# 根据模式选择 IP 列表文件
if [ "$CHECK_MODE" = "tcping" ]; then
    IP_LIST="${SCRIPT_DIR}/tcping_ip_list.txt"
else
    IP_LIST="${SCRIPT_DIR}/ping_ip_list.txt"
fi

# ──────────────────── 工具函数 ────────────────────────────

log() {
    local level="$1"; shift
    local msg
    msg=$(printf '[%s] [%-5s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*")
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()    { log "OK"    "$@"; }

die() { log_error "$@"; cleanup; exit 1; }

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            die "另一个实例正在运行 (PID: $old_pid)"
        else
            log_warn "清理残留锁文件 (PID: $old_pid 已不存在)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_OWNED=true
}

release_lock() { [ "$LOCK_OWNED" = "true" ] && rm -f "$LOCK_FILE"; }

cleanup() {
    trap '' INT TERM EXIT
    kill $(jobs -p) 2>/dev/null
    wait 2>/dev/null
    [ -n "$PING_RESULT_DIR" ] && rm -rf "$PING_RESULT_DIR"
    release_lock
}

trap cleanup EXIT INT TERM

# ──────────────────── 前置检查 ────────────────────────────

preflight_check() {
    local missing=""
    command -v curl >/dev/null 2>&1 || missing="${missing} curl"

    if [ "$CHECK_MODE" = "tcping" ]; then
        if [ ! -f "$TCPING_BIN" ]; then
            die "tcping 模式需要 tcping 二进制, 请放到 ${SCRIPT_DIR}/"
        fi
        [ -x "$TCPING_BIN" ] || chmod +x "$TCPING_BIN"
    else
        command -v ping >/dev/null 2>&1 || missing="${missing} ping"
    fi

    [ -n "$missing" ] && die "缺少必要工具:${missing}"
    [ -f "$IP_LIST" ] || die "IP 列表不存在: $IP_LIST"

    if [ "$CF_API_TOKEN" = "xxxxxxxxxxxxxxxxxx" ] || [ -z "$CF_API_TOKEN" ]; then
        die "请先配置 CF_API_TOKEN"
    fi
    if [ "$DOMAIN" = "example.com" ] || [ -z "$DOMAIN" ]; then
        die "请先配置 DOMAIN"
    fi
}

# ──────────────────── Zone ID 查询 ────────────────────────

cf_lookup_zone_id() {
    log_info "查询 ${DOMAIN} 的 Zone ID..."
    local resp
    resp=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}&status=active" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" 2>/dev/null)

    local success
    success=$(echo "$resp" | grep -o '"success": *[a-z]*' | head -1 | grep -o 'true\|false')
    [ "$success" != "true" ] && die "查询 Zone ID 失败, 请检查 API Token"

    CF_ZONE_ID=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$CF_ZONE_ID" ] && die "未找到域名 ${DOMAIN} 的 Zone"
    log_info "Zone ID: ${CF_ZONE_ID}"
}

# ──────────────────── IP/目标 提取 ────────────────────────

extract_targets() {
    if [ "$CHECK_MODE" = "tcping" ]; then
        # tcping: 提取 ip:port 格式
        grep -vE '^\s*(#|//|$)' "$IP_LIST" \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' \
            | sort -t: -k1,1 -k2,2n | uniq
    else
        # ping: 提取纯 IPv4
        grep -vE '^\s*(#|//|$)' "$IP_LIST" \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | while IFS='.' read -r a b c d; do
                if [ "$a" -ge 0 ] 2>/dev/null && [ "$a" -le 255 ] && \
                   [ "$b" -ge 0 ] 2>/dev/null && [ "$b" -le 255 ] && \
                   [ "$c" -ge 0 ] 2>/dev/null && [ "$c" -le 255 ] && \
                   [ "$d" -ge 0 ] 2>/dev/null && [ "$d" -le 255 ]; then
                    local ip="${a}.${b}.${c}.${d}"
                    [ "$ip" = "0.0.0.0" ] && continue
                    [ "$ip" = "255.255.255.255" ] && continue
                    echo "$ip"
                fi
            done \
            | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | uniq
    fi
}

# 从目标中提取纯 IP (去掉端口)
get_ip() {
    echo "$1" | cut -d: -f1
}

# ──────────────────── 检测函数 ────────────────────────────

# ICMP Ping 检测
do_ping() {
    local target="$1" result_file="$2"
    local output
    output=$(ping -c "$CHECK_COUNT" -W "$CHECK_TIMEOUT" -w "$PING_DEADLINE" "$target" 2>/dev/null)

    local ok_count
    ok_count=$(echo "$output" | grep -ci 'ttl=' || true)
    ok_count=${ok_count:-0}

    local loss
    loss=$(awk "BEGIN { if ($CHECK_COUNT > 0) printf \"%.2f\", (1 - $ok_count/$CHECK_COUNT) * 100; else print \"100.00\" }")

    local avg_ms
    avg_ms=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 | cut -d'/' -f2)
    avg_ms=${avg_ms:-"-"}

    local status="dead"
    [ "$ok_count" -ge "$ALIVE_THRESHOLD" ] && status="alive"

    echo "${status}|${CHECK_COUNT}|${ok_count}|${loss}|${avg_ms}" > "$result_file"
}

# TCP Ping 检测
do_tcping() {
    local target="$1" result_file="$2"
    local output
    output=$("$TCPING_BIN" --no-color --non-interactive -c "$CHECK_COUNT" -t "$CHECK_TIMEOUT" "$target" 2>/dev/null)

    local ok_count
    ok_count=$(echo "$output" | grep -c "Reply from" || true)
    ok_count=${ok_count:-0}

    local loss
    loss=$(awk "BEGIN { if ($CHECK_COUNT > 0) printf \"%.2f\", (1 - $ok_count/$CHECK_COUNT) * 100; else print \"100.00\" }")

    # rtt min/avg/max: 0.398/0.527/0.626 ms
    local avg_ms
    avg_ms=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 | cut -d'/' -f2)
    avg_ms=${avg_ms:-"-"}

    local status="dead"
    [ "$ok_count" -ge "$ALIVE_THRESHOLD" ] && status="alive"

    echo "${status}|${CHECK_COUNT}|${ok_count}|${loss}|${avg_ms}" > "$result_file"
}

# 分发到对应检测函数
do_check() {
    if [ "$CHECK_MODE" = "tcping" ]; then
        do_tcping "$@"
    else
        do_ping "$@"
    fi
}

# ──────────────────── 表格输出 ────────────────────────────

print_row() {
    local target="$1" sent="$2" recv="$3" loss="$4" avg="$5"
    local line
    line=$(printf '  %-24s %-8s %-8s %-8s %s' "$target" "$sent" "$recv" "$loss" "$avg")
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

# ──────────────────── 并发检测 ────────────────────────────

parallel_check_all() {
    local targets="$1"
    PING_RESULT_DIR=$(mktemp -d "${DATA_DIR}/check_results.XXXXXX")
    local running=0

    local mode_label="Ping"
    [ "$CHECK_MODE" = "tcping" ] && mode_label="TCPing"
    log_info "开始并发 ${mode_label} 检测 (并发数: $PARALLEL)..."

    print_row "Target" "Sent" "Recv" "Loss%" "Avg(ms)"

    for target in $targets; do
        (
            # 用 target 做文件名 (: 替换为 _)
            local safe_name
            safe_name=$(echo "$target" | tr ':' '_')
            do_check "$target" "${PING_RESULT_DIR}/${safe_name}"

            local data
            data=$(cat "${PING_RESULT_DIR}/${safe_name}" 2>/dev/null)
            IFS='|' read -r _status sent recv loss avg <<< "$data"
            print_row "$target" "$sent" "$recv" "$loss" "$avg"
        ) &

        running=$((running + 1))
        if [ "$running" -ge "$PARALLEL" ]; then
            wait -n 2>/dev/null || wait
            running=$((running - 1))
        fi
    done
    wait
    echo ""
    log_info "${mode_label} 检测完成"
}

# 读取检测结果 (返回 alive/dead/filtered)
get_check_result() {
    local target="$1"
    local safe_name
    safe_name=$(echo "$target" | tr ':' '_')
    local data
    data=$(cat "${PING_RESULT_DIR}/${safe_name}" 2>/dev/null || echo "dead|0|0|100.00|-")
    local status loss avg_ms
    status=$(echo "$data" | cut -d'|' -f1)
    loss=$(echo "$data" | cut -d'|' -f4)
    avg_ms=$(echo "$data" | cut -d'|' -f5)

    [ "$status" != "alive" ] && echo "dead" && return

    if [ "$MAX_LATENCY" != "0" ] && [ "$avg_ms" != "-" ]; then
        local over
        over=$(awk "BEGIN { print ($avg_ms > $MAX_LATENCY) }")
        [ "$over" = "1" ] && echo "filtered" && return
    fi
    if [ "$MAX_LOSS" != "0" ]; then
        local over
        over=$(awk "BEGIN { print ($loss > $MAX_LOSS) }")
        [ "$over" = "1" ] && echo "filtered" && return
    fi

    echo "alive"
}

# ──────────────────── Cloudflare API ─────────────────────

cf_api() {
    local method="$1" endpoint="$2" data="$3"
    local args=(-s -X "$method"
        "https://api.cloudflare.com/client/v4${endpoint}"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json"
    )
    [ -n "$data" ] && args+=(--data "$data")
    curl "${args[@]}" 2>/dev/null
}

cf_is_success() {
    local success
    success=$(echo "$1" | grep -o '"success": *[a-z]*' | head -1 | grep -o 'true\|false')
    [ "$success" = "true" ] && echo "yes" || echo "no"
}

cf_get_error() {
    echo "$1" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4
}

cf_get_all_records() {
    local page=1
    while true; do
        local resp
        resp=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${SUBDOMAIN}&page=${page}&per_page=100")

        if [ "$(cf_is_success "$resp")" != "yes" ]; then
            log_error "API 获取记录失败: $(cf_get_error "$resp")"
            return 1
        fi

        echo "$resp" | grep -o '"id":"[^"]*"[^}]*"type":"A"[^}]*"content":"[^"]*"' | \
        while IFS= read -r line; do
            local rid rip
            rid=$(echo "$line" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
            rip=$(echo "$line" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
            [ -n "$rid" ] && [ -n "$rip" ] && echo "${rid}|${rip}"
        done

        local total_pages
        total_pages=$(echo "$resp" | grep -o '"total_pages":[0-9]*' | grep -o '[0-9]*')
        total_pages=${total_pages:-1}
        [ "$page" -ge "$total_pages" ] && break
        page=$((page + 1))
        sleep 0.3
    done
}

cf_add_record() {
    local ip="$1"
    local resp
    resp=$(cf_api POST "/zones/${CF_ZONE_ID}/dns_records" \
        "$(printf '{"type":"A","name":"%s","content":"%s","ttl":%d,"proxied":%s}' "$SUBDOMAIN" "$ip" "$TTL" "$PROXIED")")
    if [ "$(cf_is_success "$resp")" = "yes" ]; then
        return 0
    else
        log_error "添加失败 ($ip): $(cf_get_error "$resp")"
        return 1
    fi
}

cf_delete_record() {
    local resp
    resp=$(cf_api DELETE "/zones/${CF_ZONE_ID}/dns_records/$1")
    [ "$(cf_is_success "$resp")" = "yes" ]
}

# ══════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════

main() {
    mkdir -p "$DATA_DIR" "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"

    local mode_label="Ping"
    [ "$CHECK_MODE" = "tcping" ] && mode_label="TCPing"

    log_info "================================================="
    log_info "  Ping-DNSync - ${mode_label} 模式"
    log_info "  域名: $SUBDOMAIN"
    local gate_info=""
    [ "$MAX_LATENCY" != "0" ] && gate_info="latency<=${MAX_LATENCY}ms"
    [ "$MAX_LOSS" != "0" ] && gate_info="${gate_info:+${gate_info} }loss<=${MAX_LOSS}%"
    [ -n "$gate_info" ] && log_info "  过滤: ${gate_info}"
    log_info "================================================="

    preflight_check
    acquire_lock
    cf_lookup_zone_id

    # 1. 提取目标列表
    log_info "[1/4] 读取: $IP_LIST"
    local target_list
    target_list=$(extract_targets)
    local target_count
    target_count=$(echo "$target_list" | grep -c . || echo 0)
    [ "$target_count" -eq 0 ] && die "未提取到有效目标"
    log_info "提取到 $target_count 个目标"

    # 2. 并发检测
    log_info "[2/4] ${mode_label} 检测 (x${CHECK_COUNT}, >=${ALIVE_THRESHOLD} 才算存活)"
    parallel_check_all "$target_list"

    # 统计结果 & 构建存活 IP 列表 (去重)
    local alive_count=0 dead_count=0 filtered_count=0
    local alive_ips=""

    for target in $target_list; do
        local result
        result=$(get_check_result "$target")
        local ip
        ip=$(get_ip "$target")

        case "$result" in
            alive)
                alive_count=$((alive_count + 1))
                # 去重: 同一 IP 不同端口只记一次
                if ! echo "$alive_ips" | grep -qx "$ip" 2>/dev/null; then
                    alive_ips="${alive_ips}${alive_ips:+
}${ip}"
                fi
                ;;
            filtered) filtered_count=$((filtered_count + 1)) ;;
            *)        dead_count=$((dead_count + 1)) ;;
        esac
    done

    log_info "结果: ${alive_count} 存活 / ${dead_count} 不通"
    [ "$filtered_count" -gt 0 ] && log_info "质量过滤: ${filtered_count} 个未达标被排除"

    # 安全阀
    if [ "$SAFETY_ENABLED" = "true" ]; then
        local reachable=$((alive_count + filtered_count))
        local threshold_count
        threshold_count=$(awk "BEGIN { printf \"%d\", $target_count * $SAFETY_THRESHOLD / 100 }")
        if [ "$reachable" -lt "$threshold_count" ]; then
            die "可达率过低 (${reachable}/${target_count}, 阈值${SAFETY_THRESHOLD}%)! 可能是本机网络故障"
        fi
    fi

    # 3. 获取 Cloudflare 现有记录
    log_info "[3/4] 获取 Cloudflare DNS 记录..."
    local cf_records
    cf_records=$(cf_get_all_records)
    if [ $? -ne 0 ]; then
        die "获取 DNS 记录失败"
    fi
    local cf_count
    cf_count=$(echo "$cf_records" | grep -c '|' 2>/dev/null || echo 0)
    log_info "现有 ${cf_count} 条 A 记录"

    # 4. 同步 DNS
    log_info "[4/4] 同步 DNS..."
    local stat_kept=0 stat_added=0 stat_removed=0
    local unique_ip_count=0

    # 处理存活 IP
    if [ -n "$alive_ips" ]; then
        unique_ip_count=$(echo "$alive_ips" | grep -c . || echo 0)
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            if echo "$cf_records" | grep -q "|${ip}$"; then
                log_info "  [=] KEEP     $ip"
                stat_kept=$((stat_kept + 1))
            else
                log_info "  [+] ADD      $ip"
                if cf_add_record "$ip"; then
                    log_ok "  [+] ADDED    $ip"
                    stat_added=$((stat_added + 1))
                else
                    log_error "  [!] FAIL     $ip"
                fi
                sleep 0.2
            fi
        done <<< "$alive_ips"
    fi

    # 删除: CF 中有记录但不在存活列表中的 IP
    if [ -n "$cf_records" ]; then
        while IFS='|' read -r rid rip; do
            [ -z "$rid" ] && continue
            if [ -z "$alive_ips" ] || ! echo "$alive_ips" | grep -qx "$rip"; then
                log_warn "  [-] REMOVE   $rip"
                if cf_delete_record "$rid"; then
                    log_ok "  [-] REMOVED  $rip"
                    stat_removed=$((stat_removed + 1))
                else
                    log_error "  [!] FAIL     $rip"
                fi
                sleep 0.2
            fi
        done <<< "$cf_records"
    fi

    # 汇总
    log_info "-------- 同步汇总 --------"
    log_info "  目标总数:  $target_count"
    log_info "  存活:      $alive_count"
    log_info "  不通:      $dead_count"
    [ "$filtered_count" -gt 0 ] && log_info "  过滤:      $filtered_count"
    log_info "  --------"
    log_info "  DNS IP数:  $unique_ip_count"
    log_info "  保持:      $stat_kept"
    log_info "  新增:      $stat_added"
    log_info "  删除:      $stat_removed"
    log_info "================================================="
    log_info "  Ping-DNSync 同步完成"
    log_info "================================================="
}

main "$@"
