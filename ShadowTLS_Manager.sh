#!/usr/bin/env bash
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 颜色定义（保持原始一行格式）
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && RESET="\033[0m" && Yellow_font_prefix="\033[0;33m" && Cyan_font_prefix="\033[0;36m"

# 信息前缀
INFO="${Green_font_prefix}[信息]${RESET}"
ERROR="${Red_font_prefix}[错误]${RESET}"

# 配置文件路径
CONFIG_FILE="/etc/shadowtls/config"

# 全局变量
BACKEND_PORT=""
EXT_PORT=""
TLS_DOMAIN=""
TLS_PASSWORD=""
WILDCARD_SNI="false"
FASTOPEN="false"

# ===========================
# 通用交互提示函数
prompt_with_default() {
    local prompt_message="$1"
    local default_value="$2"
    local input
    read -rp "${prompt_message} (默认: ${default_value}): " input
    echo "${input:-$default_value}"
}

print_info() {
    echo -e "${Green_font_prefix}[信息]${RESET} $1"
}

print_error() {
    echo -e "${Red_font_prefix}[错误]${RESET} $1"
}

print_warning() {
    echo -e "${Yellow_font_prefix}[警告]${RESET} $1"
}

# ===========================
# 系统和权限检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Red_background_prefix}请使用sudo或root账户运行此脚本${RESET}"
        exit 1
    fi
}

check_system_type() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -q -E -i "debian|ubuntu" /etc/issue; then
        release="debian"
    elif grep -q -E -i "centos|red hat|redhat" /etc/issue; then
        release="centos"
    elif grep -q -E -i "debian|ubuntu" /proc/version; then
        release="debian"
    else
        release="unknown"
    fi
}

# 检查并安装依赖工具
install_tools() {
    local missing_tools=()
    for tool in wget curl openssl jq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        print_info "所有依赖工具已安装"
        return 0
    fi

    print_info "检测到缺少工具: ${missing_tools[*]}，开始安装..."
    check_system_type
    print_info "检测到发行版: ${release}"
    case "$release" in
        debian)
            apt update && apt install -y "${missing_tools[@]}" || { print_error "安装依赖失败"; exit 1; }
            ;;
        centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${missing_tools[@]}" || { print_error "安装依赖失败"; exit 1; }
            else
                yum install -y "${missing_tools[@]}" || { print_error "安装依赖失败"; exit 1; }
            fi
            ;;
        *)
            print_warning "未知发行版，尝试使用 apt 安装..."
            apt update && apt install -y "${missing_tools[@]}" || { print_error "安装依赖失败"; exit 1; }
            ;;
    esac
    print_info "依赖工具安装完成"
}

# ===========================
# 系统架构与软件管理
get_system_architecture() {
    case "$(uname -m)" in
        x86_64) echo "shadow-tls-x86_64-unknown-linux-musl" ;;
        aarch64) echo "shadow-tls-aarch64-unknown-linux-musl" ;;
        armv7l) echo "shadow-tls-armv7-unknown-linux-musleabihf" ;;
        armv6l) echo "shadow-tls-arm-unknown-linux-musleabi" ;;
        *) echo -e "${Red_font_prefix}不支持的系统架构: $(uname -m)${RESET}"; exit 1 ;;
    esac
}

# 域名校验：仅验证域名是否有效（利用 getent hosts 检查解析情况）
check_domain_validity() {
    local domain="$1"
    if nslookup "$domain" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 循环提示用户输入有效的伪装域名
prompt_valid_domain() {
    local domain
    while true; do
        domain=$(prompt_with_default "请输入用于伪装的 TLS 域名（请确保该域名支持 TLS 1.3）" "www.tesla.com")
        if [[ "$domain" == "www.tesla.com" ]]; then
            # 默认域名跳过验证
            echo -e "${Green_font_prefix}默认域名 www.tesla.com 验证通过。${RESET}" >&2
            echo "$domain"
            return 0
        fi
        
        echo -e "${Cyan_font_prefix}正在验证域名 ${domain} 的有效性，请稍候...${RESET}" >&2
        if check_domain_validity "$domain"; then
            echo -e "${Green_font_prefix}域名 ${domain} 验证通过。${RESET}" >&2
            echo "$domain"
            return 0
        else
            echo -e "${Red_font_prefix}域名 ${domain} 无效或无法解析，请重新输入。${RESET}" >&2
        fi
    done
}

# 检查端口是否被占用
check_port_in_use() {
    # 使用 -ltnH 参数列出所有监听状态的 tcp 套接字（不显示标题），过滤条件为 sport = :$1
    if [ -n "$(ss -ltnH "sport = :$1")" ]; then
        return 0  # 端口已被占用
    else
        return 1  # 端口未被占用
    fi
}

get_latest_version() {
    if command -v jq >/dev/null; then
        curl -s "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r '.tag_name'
    else
        curl -s "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | grep -oP '"tag_name": "\K[^"]+'
    fi || { print_error "获取最新版本失败，使用默认版本 v0.2.25"; echo "v0.2.25"; }
}

# 修改 download_shadowtls 函数，增加 force 参数用于升级时强制下载
download_shadowtls() {
    local force_download="${1:-false}"
    if [[ "$force_download" != "true" ]]; then
        if command -v shadow-tls >/dev/null; then
            print_warning "ShadowTLS已安装，跳过下载"
            return 0
        fi
    else
        print_info "升级时强制下载最新版本"
    fi
    LATEST_RELEASE=$(get_latest_version)
    ARCH_STR=$(get_system_architecture)
    DOWNLOAD_URL="https://github.com/ihciah/shadow-tls/releases/download/${LATEST_RELEASE}/${ARCH_STR}"
    wget -O /usr/local/bin/shadow-tls "$DOWNLOAD_URL" || { print_error "下载失败"; exit 1; }
    chmod a+x /usr/local/bin/shadow-tls
}

# 创建服务单元配置文件时询问是否开启泛域名SNI和fastopen选项
create_service() {
    SERVICE_FILE="/etc/systemd/system/shadow-tls.service"
    local wildcard_sni_option=""
    local fastopen_option=""
    local reply

    # 使用 inline prompt 方式询问是否开启泛域名SNI
    read -rp "是否开启泛域名SNI？(开启后客户端伪装域名无需与服务端一致) (y/n, 回车不开启): " reply
    if [[ "${reply,,}" == "y" ]]; then
        wildcard_sni_option="--wildcard-sni=authed "
    else
        wildcard_sni_option=""
    fi

    # 使用 inline prompt 方式询问是否开启 fastopen
    read -rp "是否开启 fastopen？(y/n, 回车不开启): " reply
    if [[ "${reply,,}" == "y" ]]; then
        fastopen_option="--fastopen "
    else
        fastopen_option=""
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/shadow-tls $fastopen_option--v3 --strict server $wildcard_sni_option--listen [::]:${EXT_PORT} --server 127.0.0.1:${BACKEND_PORT} --tls ${TLS_DOMAIN}:443 --password ${TLS_PASSWORD}

[Install]
WantedBy=multi-user.target
EOF
    print_info "系统服务已配置完成"
}

# 从本机网络配置中读取第一个IP地址
get_server_ip() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-无法获取IP}"
}

write_config() {
    mkdir -p /etc/shadowtls
    {
        echo "local_ip=$(get_server_ip)"
        echo "password=${TLS_PASSWORD}"
        echo "external_listen_port=${EXT_PORT}"
        echo "disguise_domain=${TLS_DOMAIN}"
        echo "backend_port=${BACKEND_PORT}"
        echo "wildcard_sni=${WILDCARD_SNI}"
        echo "fastopen=${FASTOPEN}"
    } > "$CONFIG_FILE"
    print_info "配置文件已更新"
}

read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        TLS_PASSWORD="$password"
        EXT_PORT="$external_listen_port"
        TLS_DOMAIN="$disguise_domain"
        BACKEND_PORT="$backend_port"
        WILDCARD_SNI="${wildcard_sni:-false}"
        FASTOPEN="${fastopen:-false}"
    else
        print_error "未找到配置文件"
        return 1
    fi
}

# ===========================
# 主操作函数
install_shadowtls() {
    install_tools
    while true; do
        read -rp "请输入后端服务端口 (适用于 SS2022、Trojan、Snell 等，端口范围为1-65535): " BACKEND_PORT
        if [[ -z "$BACKEND_PORT" ]]; then
            print_error "错误：必须输入后端服务端口！"
        elif ! [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || [ "$BACKEND_PORT" -lt 1 ] || [ "$BACKEND_PORT" -gt 65535 ]; then
            print_error "端口号必须在1到65535之间，且为数字"
        else
            break
        fi
    done

    # 确保域名已经有效（已通过prompt_valid_domain验证）
    TLS_DOMAIN=$(prompt_valid_domain)

    # 密码输入不显示默认提示
    read -rp "请输入 Shadow-TLS 的密码 (回车则自动生成): " input_password
    if [[ -z "$input_password" ]]; then
        TLS_PASSWORD=$(openssl rand -base64 16)
        echo -e "${Cyan_font_prefix}自动生成的 Shadow-TLS 密码为: ${TLS_PASSWORD}${RESET}"
    else
        TLS_PASSWORD="$input_password"
    fi

    while true; do
        read -rp "请输入 Shadow-TLS 外部监听端口 (端口范围为1-65535, 回车则随机生成): " EXT_PORT
        if [[ -z "$EXT_PORT" ]]; then
            # 生成1024到65535之间的随机端口
            EXT_PORT=$(( RANDOM % 64512 + 1024 ))
            echo "随机生成的端口为: ${EXT_PORT}"
            break
        elif ! [[ "$EXT_PORT" =~ ^[0-9]+$ ]] || [ "$EXT_PORT" -lt 1 ] || [ "$EXT_PORT" -gt 65535 ]; then
            print_error "端口号必须在1到65535之间，且为数字"
        elif check_port_in_use "$EXT_PORT"; then
            print_error "端口 ${EXT_PORT} 已被占用，请更换端口"
        else
            break
        fi
    done

    create_service  # 这里调用create_service函数，确保在输入端口之后

    print_info "外部监听端口设置完毕，正在下载 Shadow-TLS 并生成系统服务配置，请稍候..."

    download_shadowtls "false"
    systemctl daemon-reload
    systemctl enable --now shadow-tls
    sleep 2
    if systemctl is-active --quiet shadow-tls; then
        print_info "Shadow-TLS 服务运行正常，监听外网端口: ${EXT_PORT}"
    else
        print_error "Shadow-TLS 服务未正常运行，请检查日志。"
        systemctl status shadow-tls
    fi
    write_config
    echo -e "${Cyan_font_prefix}Shadow-TLS 配置信息已保存至 ${CONFIG_FILE}${RESET}"
}

check_service_status() {
    if systemctl is-active --quiet shadow-tls; then
        print_info "Shadow-TLS 服务运行正常，监听外网端口: ${EXT_PORT}"
    else
        print_error "Shadow-TLS 服务未正常运行，请检查日志。"
        systemctl status shadow-tls
    fi
}

start_service() {
    if command -v shadow-tls >/dev/null && systemctl is-active --quiet shadow-tls; then
        print_info "Shadow-TLS 已在运行"
    else
        systemctl start shadow-tls
        sleep 2
        check_service_status
    fi
}

stop_service() {
    if systemctl is-active --quiet shadow-tls; then
        systemctl stop shadow-tls
        sleep 2
        print_info "Shadow-TLS 已停止"
    else
        print_error "Shadow-TLS 未运行"
    fi
}

restart_service() {
    systemctl daemon-reload
    systemctl restart shadow-tls
    sleep 2
    check_service_status
}

upgrade_shadowtls() {
    local current_version latest_version
    if command -v shadow-tls >/dev/null; then
        # 获取当前版本
        current_version=$(shadow-tls --version 2>/dev/null | grep -oP 'shadow-tls \K[0-9.]+')
        if [[ -z "$current_version" ]]; then
            current_version="unknown"
        else
            current_version="v$current_version"
        fi
    else
        current_version="none"
    fi
    latest_version=$(get_latest_version)

    # 比较版本号
    if [[ "$current_version" == "$latest_version" ]]; then
        print_info "当前已是最新版本 ($current_version)，无需升级。"
    else
        print_info "检测到新版本：当前版本 $current_version，最新版本 $latest_version。"
        read -rp "是否升级到最新版本？(y/n): " choice
        if [[ "${choice,,}" != "y" ]]; then
            print_info "取消升级"
            return
        fi
        
        install_tools
        print_info "正在升级 Shadow-TLS，从 $current_version 升级到 $latest_version..."
        systemctl stop shadow-tls
        download_shadowtls "true"
        systemctl start shadow-tls
        sleep 2
        check_service_status
    fi
}

uninstall_shadowtls() {
    print_warning "正在卸载 Shadow-TLS..."
    read -rp "确认卸载吗？(y/n): " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        systemctl stop shadow-tls
        systemctl disable shadow-tls
        rm -f /usr/local/bin/shadow-tls /etc/systemd/system/shadow-tls.service "$CONFIG_FILE"
        rm -rf /etc/shadowtls
        systemctl daemon-reload
        print_info "Shadow-TLS 已成功卸载"
    else
        print_warning "取消卸载"
    fi
}

view_config() {
    if read_config; then
        echo -e "${Cyan_font_prefix}Shadow-TLS 配置信息：${RESET}"
        echo -e "本机 IP：${local_ip}"
        echo -e "外部监听端口：${external_listen_port}"
        echo -e "伪装域名：${disguise_domain}"
        echo -e "密码：${password}"
        echo -e "后端服务端口：${backend_port}"
        echo -e "泛域名 SNI：${wildcard_sni}"
        echo -e "Fastopen：${fastopen}"
    else
        print_error "未找到 Shadow-TLS 配置信息，请确认已安装 Shadow-TLS"
    fi
}

set_disguise_domain() {
    local new_domain
    new_domain=$(prompt_valid_domain)
    if [[ -n "$new_domain" ]]; then
        TLS_DOMAIN="$new_domain"
        return 0
    else
        return 1
    fi
}

set_external_port() {
    local current_port="${EXT_PORT:-未设置}"
    local new_port
    read -rp "请输入新的外部监听端口 (当前: $current_port): " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        print_error "端口号必须在1到65535之间，且为数字"
        return 1
    fi
    if check_port_in_use "$new_port"; then
        print_error "端口 ${new_port} 已被占用，请更换端口"
        return 1
    fi
    EXT_PORT="$new_port"
    write_config
    print_info "外部监听端口已更新为: $EXT_PORT"
    return 0
}

set_backend_port() {
    local current_port="${BACKEND_PORT:-未设置}"
    local new_port
    while true; do
        read -rp "请输入新的后端服务端口 (当前: $current_port): " new_port
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            print_error "端口号必须在1到65535之间，且为数字"
        else
            BACKEND_PORT="$new_port"
            write_config  # 保存新配置到文件中
            update_service_file  # 更新服务文件
            print_info "后端服务端口已更新为: $BACKEND_PORT"
            return 0
        fi
    done
}

set_password() {
    local new_password
    read -rp "请输入新的 Shadow-TLS 密码:" new_password
    if [[ -z "$new_password" ]]; then
        new_password=$(openssl rand -base64 16)
        echo -e "${Cyan_font_prefix}自动生成的 Shadow-TLS 密码为: ${new_password}${RESET}"
    fi
    TLS_PASSWORD="$new_password"
    return 0
}

update_service_file() {
    SERVICE_FILE="/etc/systemd/system/shadow-tls.service"
    if [[ -f "$SERVICE_FILE" ]]; then
        local wildcard_sni_option=""
        local fastopen_option=""
        [[ "$WILDCARD_SNI" == "true" ]] && wildcard_sni_option="--wildcard-sni=authed "
        [[ "$FASTOPEN" == "true" ]] && fastopen_option="--fastopen "
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/shadow-tls $fastopen_option--v3 --strict server $wildcard_sni_option--listen [::]:${EXT_PORT} --server 127.0.0.1:${BACKEND_PORT} --tls ${TLS_DOMAIN}:443 --password ${TLS_PASSWORD}

[Install]
WantedBy=multi-user.target
EOF
        print_info "服务单元配置文件已更新。"
    else
        print_error "服务单元配置文件不存在，无法更新。"
    fi
}

set_config() {
    read_config || print_warning "未找到现有配置，将使用默认值"
    echo -e "你要修改什么？
==================================
 ${Green_font_prefix}1.${RESET}  修改 全部配置
 ${Green_font_prefix}2.${RESET}  修改 伪装域名
 ${Green_font_prefix}3.${RESET}  修改 ShadowTLS 密码
 ${Green_font_prefix}4.${RESET}  修改 后端服务端口
 ${Green_font_prefix}5.${RESET}  修改 外部监听端口
=================================="
    read -rp "(默认：取消): " modify
    [[ -z "${modify}" ]] && { echo "已取消..."; return; }
    case $modify in
        1) 
            set_disguise_domain && set_external_port && set_password && set_backend_port && write_config && update_service_file && systemctl daemon-reload && restart_service || print_error "修改配置失败"
            ;;
        2) 
            set_disguise_domain && write_config && update_service_file && systemctl daemon-reload && restart_service || print_error "修改伪装域名失败"
            ;;
        3) 
            set_password && write_config && update_service_file && systemctl daemon-reload && restart_service || print_error "修改密码失败"
            ;;
        4) 
            set_backend_port && write_config && update_service_file && systemctl daemon-reload && restart_service || print_error "修改后端服务端口失败"
            ;;
        5) 
            set_external_port && write_config && update_service_file && systemctl daemon-reload && restart_service || print_error "修改外部监听端口失败"
            ;;
        *) 
            print_error "请输入正确的数字(1-5)"
            return
            ;;
    esac
}

main_menu() {
    while true; do
        clear
        echo -e "\n${Cyan_font_prefix}Shadow-TLS 管理菜单${RESET}"
        echo -e "=================================="
        echo -e " 安装与更新"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}1. 安装 Shadow-TLS${RESET}"
        echo -e "${Yellow_font_prefix}2. 升级 Shadow-TLS${RESET}"
        echo -e "${Yellow_font_prefix}3. 卸载 Shadow-TLS${RESET}"
        echo -e "=================================="
        echo -e " 配置管理"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}4. 查看 Shadow-TLS 配置信息${RESET}"
        echo -e "${Yellow_font_prefix}5. 修改 Shadow-TLS 配置${RESET}"
        echo -e "=================================="
        echo -e " 服务控制"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}6. 启动 Shadow-TLS${RESET}"
        echo -e "${Yellow_font_prefix}7. 停止 Shadow-TLS${RESET}"
        echo -e "${Yellow_font_prefix}8. 重启 Shadow-TLS${RESET}"
        echo -e "=================================="
        echo -e " 退出"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}0. 退出${RESET}"
        if [[ -e /usr/local/bin/shadow-tls ]]; then
            if systemctl is-active --quiet shadow-tls; then
                echo -e " 当前状态：${Green_font_prefix}已安装并已启动${RESET}"
            else
                echo -e " 当前状态：${Green_font_prefix}已安装${RESET} 但 ${Red_font_prefix}未启动${RESET}"
            fi
        else
            echo -e " 当前状态：${Red_font_prefix}未安装${RESET}"
        fi
        read -rp "请选择操作 [0-8]: " choice
        case "$choice" in
            1) install_shadowtls ;;
            2) upgrade_shadowtls ;;
            3) uninstall_shadowtls ;;
            4) view_config ;;
            5) set_config ;;
            6) start_service ;;
            7) stop_service ;;
            8) restart_service ;;
            0) exit 0 ;;
            *) print_error "无效的选择" ;;
        esac
        echo -e "\n按任意键返回主菜单..."
        read -n1 -s
    done
}

# 脚本启动
check_root
check_system_type
main_menu
