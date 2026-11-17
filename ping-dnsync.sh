#!/bin/bash
# ============================================================================
#  Ping-DNSync
#  基于 Ping/TCPing/HTTPing 检活的 Cloudflare DNS 自动同步工具
#  依赖: bash / curl / ping (ping模式) 或 tcping二进制 (tcping模式)
# ============================================================================

# ──────────────────── Cloudflare 配置 ─────────────────────
CF_API_TOKEN="xxxxxxxxxxxxxxxxxx"
DOMAIN="example.com"                # 根域名 (自动查询 Zone ID)
SUBDOMAIN="lb.example.com"         # 负载均衡子域名
PROXIED=false                       # Cloudflare 代理开关 (true=橙色云朵, 流量经CF; false=灰色, DNS直连)
TTL=60                              # DNS 记录缓存时间 (秒), PROXIED=true 时此项无效

# ──────────────────── 检测模式 ─────────────────────────────
# ping    = ICMP Ping  (需要 ping 命令)
# tcping  = TCP Ping   (需要 tcping 二进制, 放在脚本同目录)
# httping = HTTP Ping  (需要 curl 命令)
CHECK_MODE="ping"

# ──────────────────── 检测参数 ─────────────────────────────
CHECK_COUNT=5          # 每个目标发送探测次数
CHECK_TIMEOUT=2        # 单次探测超时 (秒)
PING_DEADLINE=18       # ping 总时限 (秒, 仅 ping 模式)
ALIVE_THRESHOLD=4      # 至少成功 N 次才算存活

# ──────────────────── 多端口判定 (tcping/httping) ─────────
# or  = 同 IP 任一端口存活即算存活
# and = 同 IP 所有端口都存活才算存活
MULTI_PORT_LOGIC="or"

# ──────────────────── HTTPing 参数 (仅 httping 模式) ──────
# strict   = 仅 2xx 算存活 (服务完全正常)
# standard = 2xx + 3xx 算存活 (允许重定向)
# loose    = 任何 HTTP 响应算存活 (只要服务器有回应)
HTTPING_MODE="strict"
HTTPING_HOST=""        # 访问用的域名, 同时作为 Host 头和 TLS SNI (留空=直接访问 IP, 例: "example.com")
HTTPING_VERIFY_TLS=false  # TLS 证书验证 (true=证书域名不符/过期/不受信任判 dead; false=跳过验证)
                          # 开启且 HTTPING_HOST 留空时, https 目标用 SUBDOMAIN 作为 SNI 校验
HTTPING_CA_FILE=""     # 自定义 CA 证书文件 (留空=系统 CA; 源站用 Cloudflare Origin 证书等非公开 CA 时填写)

# ──────────────────── 质量门槛 (0=不过滤) ─────────────────
MAX_LATENCY=0          # 最高平均延迟 (ms)
MAX_LOSS=0             # 最高丢包率 (%)

# ──────────────────── DNS 记录上限 ─────────────────────────
MAX_DNS_RECORDS=0      # 最多同步多少条 A 记录 (0=不限制, 按延迟从低到高选取)

# ──────────────────── 安全阀 ──────────────────────────────
SAFETY_ENABLED=true    # 是否启用安全阀 (true/false)
SAFETY_THRESHOLD=20    # 可达率低于此百分比时中止同步, 防止误删 (%)

# ──────────────────── 自动清理 ────────────────────────────
AUTO_REMOVE_DEAD=false # 检测失败的目标自动从 IP 列表文件中删除 (true/false)

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
CLEANED_COUNT=0

# 根据模式选择 IP 列表文件
case "$CHECK_MODE" in
    tcping)  IP_LIST="${SCRIPT_DIR}/tcping_ip_list.txt" ;;
    httping) IP_LIST="${SCRIPT_DIR}/httping_ip_list.txt" ;;
    *)       IP_LIST="${SCRIPT_DIR}/ping_ip_list.txt" ;;
esac

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

    case "$CHECK_MODE" in
        tcping)
            if [ ! -f "$TCPING_BIN" ]; then
                die "tcping 模式需要 tcping 二进制, 请放到 ${SCRIPT_DIR}/"
            fi
            [ -x "$TCPING_BIN" ] || chmod +x "$TCPING_BIN"
            ;;
        httping)
            # httping 依赖 curl, 已在上面检查
            if [ "$HTTPING_VERIFY_TLS" = "true" ]; then
                if [ -z "$HTTPING_HOST" ] && [ -z "$SUBDOMAIN" ]; then
                    die "HTTPING_VERIFY_TLS 需要 HTTPING_HOST 或 SUBDOMAIN"
                fi
                if [ -n "$HTTPING_CA_FILE" ] && [ ! -f "$HTTPING_CA_FILE" ]; then
                    die "HTTPING_CA_FILE 不存在: $HTTPING_CA_FILE"
                fi
            fi
            ;;
        *)
            command -v ping >/dev/null 2>&1 || missing="${missing} ping"
            ;;
    esac

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

# 注释行/空行: 以 # 或 // 开头, 或全是空白
COMMENT_RE='^[[:space:]]*(#|//|$)'

# 从 stdin 解析目标 (不过滤注释, 不排序), 每行输出一个目标
parse_targets() {
    case "$CHECK_MODE" in
        tcping)
            # tcping: 提取 ip:port 格式
            grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+'
            ;;
        httping)
            # httping: 提取 http(s)://ip 或 http(s)://ip:port 格式
            grep -oE 'https?://([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?'
            ;;
        *)
            # ping: 提取纯 IPv4
            grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
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
                done
            ;;
    esac
}

extract_targets() {
    local targets
    targets=$(grep -vE "$COMMENT_RE" "$IP_LIST" | parse_targets)
    [ -z "$targets" ] && return 0
    case "$CHECK_MODE" in
        tcping)  printf '%s\n' "$targets" | sort -t: -k1,1 -k2,2n | uniq ;;
        httping) printf '%s\n' "$targets" | sort -u ;;
        *)       printf '%s\n' "$targets" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | uniq ;;
    esac
}

# 从 IP 列表文件中删除指定目标
# 逐行解析, 只有当一行解析出的目标全部在删除列表中 (精确匹配) 时才删除该行
# 注释行/空行/解析不出目标的行原样保留
remove_dead_targets() {
    local dead_list="$1"
    local tmp
    tmp=$(mktemp "${DATA_DIR}/ip_list.XXXXXX") || { log_error "自动清理: 无法创建临时文件"; return 1; }

    local line removed=0
    while IFS= read -r line || [ -n "$line" ]; do
        if printf '%s\n' "$line" | grep -qE "$COMMENT_RE"; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi

        local line_targets t all_dead=true
        line_targets=$(printf '%s\n' "$line" | parse_targets)
        if [ -z "$line_targets" ]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        for t in $line_targets; do
            if ! printf '%s\n' "$dead_list" | grep -qxF -- "$t"; then
                all_dead=false
                break
            fi
        done

        if [ "$all_dead" = "true" ]; then
            log_warn "  [x] CLEANED  $line"
            removed=$((removed + 1))
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$IP_LIST"

    # 用 cat 覆盖而不是 mv, 保留原文件的权限和属主
    cat "$tmp" > "$IP_LIST"
    rm -f "$tmp"
    CLEANED_COUNT=$removed
}

# 从目标中提取纯 IP (去掉协议和端口)
get_ip() {
    echo "$1" | sed -E 's|https?://||' | sed 's|:[0-9]*$||'
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

# HTTP Ping 检测
do_httping() {
    local target="$1" result_file="$2"
    local ok_count=0 total_ms=0 tls_errors=0
    local i

    # curl 参数只构造一次
    local curl_args=(-o /dev/null -s -w '%{http_code} %{time_total}'
        --connect-timeout "$CHECK_TIMEOUT" -m "$CHECK_TIMEOUT")
    local ip port proto
    ip=$(get_ip "$target")
    proto=$(echo "$target" | grep -oE '^https?')
    port=$(echo "$target" | grep -oE ':[0-9]+$' | tr -d ':')
    [ -z "$port" ] && { [ "$proto" = "https" ] && port=443 || port=80; }

    # 访问用的域名 (Host + SNI); 开启证书校验但未设置时, https 目标回退到 SUBDOMAIN
    local domain="$HTTPING_HOST"
    if [ -z "$domain" ] && [ "$proto" = "https" ] && [ "$HTTPING_VERIFY_TLS" = "true" ]; then
        domain="$SUBDOMAIN"
    fi

    local curl_url="$target"
    if [ -n "$domain" ]; then
        # 用域名访问 (发送 SNI, 按域名校验证书), 但连接固定打到该 IP
        curl_args+=(--resolve "${domain}:${port}:${ip}")
        curl_url="${proto}://${domain}:${port}/"
    fi
    if [ "$HTTPING_VERIFY_TLS" = "true" ]; then
        [ -n "$HTTPING_CA_FILE" ] && curl_args+=(--cacert "$HTTPING_CA_FILE")
    else
        curl_args+=(-k)
    fi

    for i in $(seq 1 "$CHECK_COUNT"); do
        local output rc
        output=$(curl "${curl_args[@]}" "$curl_url" 2>/dev/null)
        rc=$?
        # 51/60 = 证书校验失败 (域名不匹配 / 不受信任 / 已过期)
        if [ "$rc" -eq 60 ] || [ "$rc" -eq 51 ]; then
            tls_errors=$((tls_errors + 1))
            continue
        fi
        local code time_s
        code=$(echo "$output" | awk '{print $1}')
        time_s=$(echo "$output" | awk '{print $2}')

        local is_ok=false
        if [ -n "$code" ] && [ "$code" -gt 0 ] 2>/dev/null; then
            case "$HTTPING_MODE" in
                strict)   [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && is_ok=true ;;
                loose)    is_ok=true ;;
                *)        [ "$code" -ge 200 ] && [ "$code" -lt 400 ] && is_ok=true ;;
            esac
        fi
        if [ "$is_ok" = "true" ]; then
            ok_count=$((ok_count + 1))
            local ms
            ms=$(awk "BEGIN { printf \"%.3f\", $time_s * 1000 }")
            total_ms=$(awk "BEGIN { printf \"%.3f\", $total_ms + $ms }")
        fi
    done

    local loss
    loss=$(awk "BEGIN { if ($CHECK_COUNT > 0) printf \"%.2f\", (1 - $ok_count/$CHECK_COUNT) * 100; else print \"100.00\" }")

    local avg_ms="-"
    if [ "$ok_count" -gt 0 ]; then
        avg_ms=$(awk "BEGIN { printf \"%.3f\", $total_ms / $ok_count }")
    fi

    local status="dead"
    [ "$ok_count" -ge "$ALIVE_THRESHOLD" ] && status="alive"

    local note=""
    [ "$tls_errors" -gt 0 ] && note="证书校验失败x${tls_errors}"

    echo "${status}|${CHECK_COUNT}|${ok_count}|${loss}|${avg_ms}|${note}" > "$result_file"
}

# 分发到对应检测函数
do_check() {
    case "$CHECK_MODE" in
        tcping)  do_tcping "$@" ;;
        httping) do_httping "$@" ;;
        *)       do_ping "$@" ;;
    esac
}

# ──────────────────── 表格输出 ────────────────────────────

print_row() {
    local target="$1" sent="$2" recv="$3" loss="$4" avg="$5" note="$6"
    local line
    line=$(printf '  %-24s %-8s %-8s %-8s %-10s %s' "$target" "$sent" "$recv" "$loss" "$avg" "$note")
    line="${line%"${line##*[! ]}"}"   # 去掉行尾空格
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

# ──────────────────── 并发检测 ────────────────────────────

# 目标对应的结果文件路径 (: 和 / 都替换为 _, 否则 https://ip 会变成子目录路径)
result_file() {
    echo "${PING_RESULT_DIR}/$(printf '%s' "$1" | tr ':/' '__')"
}

parallel_check_all() {
    local targets="$1"
    PING_RESULT_DIR=$(mktemp -d "${DATA_DIR}/check_results.XXXXXX")
    local running=0

    local mode_label="Ping"
    [ "$CHECK_MODE" = "tcping" ] && mode_label="TCPing"
    [ "$CHECK_MODE" = "httping" ] && mode_label="HTTPing"
    log_info "开始并发 ${mode_label} 检测 (并发数: $PARALLEL)..."

    print_row "Target" "Sent" "Recv" "Loss%" "Avg(ms)" "Note"

    for target in $targets; do
        (
            local rfile
            rfile=$(result_file "$target")
            do_check "$target" "$rfile"

            local data
            data=$(cat "$rfile" 2>/dev/null)
            IFS='|' read -r _status sent recv loss avg note <<< "$data"
            print_row "$target" "$sent" "$recv" "$loss" "$avg" "$note"
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
    local data
    data=$(cat "$(result_file "$target")" 2>/dev/null || echo "dead|0|0|100.00|-")
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
    [ "$CHECK_MODE" = "httping" ] && mode_label="HTTPing"

    log_info "================================================="
    log_info "  Ping-DNSync - ${mode_label} 模式"
    log_info "  域名: $SUBDOMAIN"
    local gate_info=""
    [ "$MAX_LATENCY" != "0" ] && gate_info="latency<=${MAX_LATENCY}ms"
    [ "$MAX_LOSS" != "0" ] && gate_info="${gate_info:+${gate_info} }loss<=${MAX_LOSS}%"
    [ -n "$gate_info" ] && log_info "  过滤: ${gate_info}"
    if [ "$CHECK_MODE" = "httping" ]; then
        log_info "  HTTPing 判定: ${HTTPING_MODE}"
        [ -n "$HTTPING_HOST" ] && log_info "  HTTPing Host: ${HTTPING_HOST}"
        [ "$HTTPING_VERIFY_TLS" = "true" ] && log_info "  TLS 验证: 开启 (校验域名: ${HTTPING_HOST:-$SUBDOMAIN})"
    fi
    if [ "$CHECK_MODE" != "ping" ]; then
        log_info "  多端口判定: ${MULTI_PORT_LOGIC}"
    fi
    if [ "$MAX_DNS_RECORDS" != "0" ] && [ "$MAX_DNS_RECORDS" -gt 0 ] 2>/dev/null; then
        log_info "  DNS 上限: ${MAX_DNS_RECORDS} 条 (按延迟择优)"
    fi
    if [ "$SAFETY_ENABLED" = "true" ]; then
        log_info "  安全阀: 开启 (阈值${SAFETY_THRESHOLD}%)"
    else
        log_info "  安全阀: 关闭"
    fi
    if [ "$AUTO_REMOVE_DEAD" = "true" ]; then
        log_info "  自动清理: 开启"
    else
        log_info "  自动清理: 关闭"
    fi
    log_info "================================================="

    preflight_check
    acquire_lock
    cf_lookup_zone_id

    # 1. 提取目标列表
    log_info "[1/4] 读取: $IP_LIST"
    local target_list
    target_list=$(extract_targets)
    local target_count
    # grep -c 无匹配时会输出 0 并返回 1, 用 || true 避免再追加一个 0
    target_count=$(printf '%s\n' "$target_list" | grep -c . || true)
    [ "${target_count:-0}" -eq 0 ] && die "未提取到有效目标, 请检查 $IP_LIST 的内容和格式"
    log_info "提取到 $target_count 个目标"

    # 2. 并发检测
    log_info "[2/4] ${mode_label} 检测 (x${CHECK_COUNT}, >=${ALIVE_THRESHOLD} 才算存活)"
    parallel_check_all "$target_list"

    # 统计结果 & 构建存活 IP 列表 (去重)
    local alive_count=0 dead_count=0 filtered_count=0
    local alive_ips=""
    local dead_ips=""

    for target in $target_list; do
        local result
        result=$(get_check_result "$target")
        local ip
        ip=$(get_ip "$target")

        case "$result" in
            alive)
                alive_count=$((alive_count + 1))
                if ! echo "$alive_ips" | grep -qx "$ip" 2>/dev/null; then
                    alive_ips="${alive_ips}${alive_ips:+
}${ip}"
                fi
                ;;
            filtered) filtered_count=$((filtered_count + 1)) ;;
            *)
                dead_count=$((dead_count + 1))
                if ! echo "$dead_ips" | grep -qx "$ip" 2>/dev/null; then
                    dead_ips="${dead_ips}${dead_ips:+
}${ip}"
                fi
                ;;
        esac
    done

    # AND 模式: 同 IP 有任一端口失败则移除该 IP
    # and_rejected_ips 单独记录, 供自动清理使用 (不能用 alive_ips 反推, 它之后还会被 DNS 上限截断)
    local and_rejected_ips=""
    if [ "$MULTI_PORT_LOGIC" = "and" ] && [ -n "$dead_ips" ] && [ -n "$alive_ips" ]; then
        local filtered_alive=""
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            if echo "$dead_ips" | grep -qx "$ip"; then
                log_warn "AND 模式: $ip 部分端口不通, 整体判定为不存活"
                and_rejected_ips="${and_rejected_ips}${and_rejected_ips:+
}${ip}"
            else
                filtered_alive="${filtered_alive}${filtered_alive:+
}${ip}"
            fi
        done <<< "$alive_ips"
        alive_ips="$filtered_alive"
    fi

    log_info "结果: ${alive_count} 存活 / ${dead_count} 不通"
    [ "$filtered_count" -gt 0 ] && log_info "质量过滤: ${filtered_count} 个未达标被排除"

    # 安全阀
    if [ "$SAFETY_ENABLED" = "true" ]; then
        local reachable=$((alive_count + filtered_count))
        local threshold_count
        threshold_count=$(awk "BEGIN { v = $target_count * $SAFETY_THRESHOLD / 100; printf \"%d\", (v > int(v)) ? int(v)+1 : v }")
        if [ "$reachable" -lt "$threshold_count" ]; then
            die "可达率过低 (${reachable}/${target_count}, 阈值${SAFETY_THRESHOLD}%)! 可能是本机网络故障"
        fi
    fi

    # DNS 记录上限: 按延迟排序截取前 N 个
    if [ "$MAX_DNS_RECORDS" != "0" ] && [ "$MAX_DNS_RECORDS" -gt 0 ] 2>/dev/null && [ -n "$alive_ips" ]; then
        unique_ip_count=$(printf '%s\n' "$alive_ips" | grep -c . || true)
        if [ "$unique_ip_count" -gt "$MAX_DNS_RECORDS" ]; then
            log_info "存活 IP (${unique_ip_count}) 超过上限 (${MAX_DNS_RECORDS}), 按延迟择优..."
            local ip_latency_pairs=""
            for target in $target_list; do
                local ip
                ip=$(get_ip "$target")
                echo "$alive_ips" | grep -qx "$ip" || continue
                local rfile
                rfile=$(result_file "$target")
                [ -f "$rfile" ] || continue
                local avg_ms
                avg_ms=$(cut -d'|' -f5 < "$rfile")
                [ "$avg_ms" = "-" ] && avg_ms="999999"
                ip_latency_pairs="${ip_latency_pairs}${avg_ms} ${ip}
"
            done
            alive_ips=$(printf '%s' "$ip_latency_pairs" | sort -k1,1n | awk '!seen[$2]++{print $2}' | head -n "$MAX_DNS_RECORDS")
            local trimmed=$((unique_ip_count - MAX_DNS_RECORDS))
            log_info "已截取延迟最低的 ${MAX_DNS_RECORDS} 个 IP, 排除 ${trimmed} 个"
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
    cf_count=$(printf '%s\n' "$cf_records" | grep -c '|' || true)
    log_info "现有 ${cf_count} 条 A 记录"

    # 4. 同步 DNS
    log_info "[4/4] 同步 DNS..."
    local stat_kept=0 stat_added=0 stat_removed=0
    local unique_ip_count=0

    # 处理存活 IP
    if [ -n "$alive_ips" ]; then
        unique_ip_count=$(printf '%s\n' "$alive_ips" | grep -c . || true)
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

    # 自动清理: 从 IP 列表中删除不存活的目标
    local stat_cleaned=0
    if [ "$AUTO_REMOVE_DEAD" = "true" ] && [ "$dead_count" -gt 0 ]; then
        log_info "自动清理: 从 $IP_LIST 中移除不通的目标..."
        local clean_targets=""
        for target in $target_list; do
            local should_clean=false
            if [ "$(get_check_result "$target")" = "dead" ]; then
                should_clean=true
            elif [ -n "$and_rejected_ips" ] && \
                 printf '%s\n' "$and_rejected_ips" | grep -qxF -- "$(get_ip "$target")"; then
                # AND 模式下被整体判死的 IP, 其存活端口也一并清理
                should_clean=true
            fi
            if [ "$should_clean" = "true" ]; then
                clean_targets="${clean_targets}${clean_targets:+
}${target}"
            fi
        done
        if remove_dead_targets "$clean_targets"; then
            stat_cleaned=$CLEANED_COUNT
        fi
        log_info "自动清理: 已移除 ${stat_cleaned} 行"
    fi

    # 汇总
    log_info "-------- 同步汇总 --------"
    log_info "  目标总数:  $target_count"
    log_info "  存活:      $alive_count"
    log_info "  不通:      $dead_count"
    [ "$filtered_count" -gt 0 ] && log_info "  过滤:      $filtered_count"
    [ "$stat_cleaned" -gt 0 ] && log_info "  已清理:    $stat_cleaned"
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
