#!/bin/bash

# 设置错误处理
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 获取当前用户
get_current_user() {
    if [ "$EUID" -eq 0 ]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "无法获取用户名"
    exit 1
fi

# 定义配置文件路径
STORAGE_FILE="$HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"

# 定义 Cursor 应用程序路径
CURSOR_APP_PATH="/Applications/Cursor.app"

# 检查权限
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本"
        echo "示例: sudo $0"
        exit 1
    fi
}

# 检查并关闭 Cursor 进程
check_and_kill_cursor() {
    log_info "检查 Cursor 进程..."
    
    local attempt=1
    local max_attempts=5
    
    while [ $attempt -le $max_attempts ]; do
        CURSOR_PIDS=$(pgrep -i "cursor" || true)
        
        if [ -z "$CURSOR_PIDS" ]; then
            return 0
        fi
        
        if [ $attempt -eq 1 ]; then
            log_warn "发现 Cursor 进程正在运行，尝试关闭..."
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi
        
        sleep 1
        
        if ! pgrep -i "cursor" > /dev/null; then
            log_info "Cursor 进程已关闭"
            return 0
        fi
        
        ((attempt++))
    done
    
    log_error "无法关闭 Cursor 进程，请手动关闭后重试"
    exit 1
}

# 生成随机 ID
generate_random_id() {
    # 生成32字节(64个十六进制字符)的随机数
    openssl rand -hex 32
}

# 生成随机 UUID
generate_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# 修改现有文件
modify_or_add_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    if [ ! -f "$file" ]; then
        log_error "文件不存在: $file"
        return 1
    fi
    
    # 确保文件可写
    chmod 644 "$file" || {
        log_error "无法修改文件权限: $file"
        return 1
    }
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 检查key是否存在
    if grep -q "\"$key\":" "$file"; then
        # key存在,执行替换
        sed "s/\"$key\":[[:space:]]*\"[^\"]*\"/\"$key\": \"$value\"/" "$file" > "$temp_file" || {
            log_error "修改配置失败: $key"
            rm -f "$temp_file"
            return 1
        }
    else
        # key不存在,添加新的key-value对
        sed "s/}$/,\n    \"$key\": \"$value\"\n}/" "$file" > "$temp_file" || {
            log_error "添加配置失败: $key"
            rm -f "$temp_file"
            return 1
        }
    fi
    
    # 检查临时文件是否为空
    if [ ! -s "$temp_file" ]; then
        log_error "生成的临时文件为空"
        rm -f "$temp_file"
        return 1
    fi
    
    # 使用 cat 替换原文件内容
    cat "$temp_file" > "$file" || {
        log_error "无法写入文件: $file"
        rm -f "$temp_file"
        return 1
    }
    
    rm -f "$temp_file"
    
    # 恢复文件权限
    chmod 444 "$file"
    
    return 0
}

# 生成新的配置
generate_new_config() {
  
    # 修改系统 ID
    log_info "正在修改系统 ID..."
    
    # 生成新的系统 UUID
    local new_system_uuid=$(uuidgen)
    
    # 修改系统 UUID
    sudo nvram SystemUUID="$new_system_uuid"
    printf "${YELLOW}系统 UUID 已更新为: $new_system_uuid${NC}\n"
    printf "${YELLOW}请重启系统以使更改生效${NC}\n"
    
    # 将 auth0|user_ 转换为字节数组的十六进制
    local prefix_hex=$(echo -n "auth0|user_" | xxd -p)
    local random_part=$(generate_random_id)
    local machine_id="${prefix_hex}${random_part}"
    
    local mac_machine_id=$(generate_random_id)
    local device_id=$(generate_uuid | tr '[:upper:]' '[:lower:]')
    local sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    
    log_info "正在修改配置文件..."
    # 检查配置文件是否存在
    if [ ! -f "$STORAGE_FILE" ]; then
        log_error "未找到配置文件: $STORAGE_FILE"
        log_warn "请先安装并运行一次 Cursor 后再使用此脚本"
        exit 1
    fi
    
    # 确保配置文件目录存在
    mkdir -p "$(dirname "$STORAGE_FILE")" || {
        log_error "无法创建配置目录"
        exit 1
    }
    
    # 如果文件不存在，创建一个基本的 JSON 结构
    if [ ! -s "$STORAGE_FILE" ]; then
        echo '{}' > "$STORAGE_FILE" || {
            log_error "无法初始化配置文件"
            exit 1
        }
    fi
    
    # 修改现有文件
    modify_or_add_config "telemetry.machineId" "$machine_id" "$STORAGE_FILE" || exit 1
    modify_or_add_config "telemetry.macMachineId" "$mac_machine_id" "$STORAGE_FILE" || exit 1
    modify_or_add_config "telemetry.devDeviceId" "$device_id" "$STORAGE_FILE" || exit 1
    modify_or_add_config "telemetry.sqmId" "$sqm_id" "$STORAGE_FILE" || exit 1
    
    # 设置文件权限和所有者
    chmod 444 "$STORAGE_FILE"  # 改为只读权限
    chown "$CURRENT_USER" "$STORAGE_FILE"
    
    # 验证权限设置
    if [ -w "$STORAGE_FILE" ]; then
        log_warn "无法设置只读权限，尝试使用其他方法..."
        chattr +i "$STORAGE_FILE" 2>/dev/null || true
    else
        log_info "成功设置文件只读权限"
    fi
    
    echo
    log_info "已更新配置: $STORAGE_FILE"
    log_debug "machineId: $machine_id"
    log_debug "macMachineId: $mac_machine_id"
    log_debug "devDeviceId: $device_id"
    log_debug "sqmId: $sqm_id"
}

# 显示文件树结构
show_file_tree() {
    local base_dir=$(dirname "$STORAGE_FILE")
    echo
    log_info "文件结构:"
    echo -e "${BLUE}$base_dir${NC}"
    echo "└── globalStorage"
    echo "    └── storage.json (已修改)"
    echo
}

# 生成随机MAC地址
generate_random_mac() {
    # 生成随机MAC地址,保持第一个字节的第二位为0(保证是单播地址)
    printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# 获取网络接口列表
get_network_interfaces() {
    networksetup -listallhardwareports | awk '/Hardware Port|Ethernet Address/ {print $NF}' | paste - - | grep -v 'N/A'
}

# 修改MAC地址
modify_mac_address() {
    log_info "正在获取网络接口信息..."
    
    # 获取所有网络接口
    local interfaces=$(get_network_interfaces)
    
    if [ -z "$interfaces" ]; then
        log_error "未找到可用的网络接口"
        return 1
    fi
    
    echo
    log_info "发现以下网络接口:"
    echo "$interfaces" | nl -w2 -s') '
    echo
    
    echo -n "请选择要修改的接口编号 (按回车跳过): "
    read -r choice
    
    if [ -z "$choice" ]; then
        log_info "跳过MAC地址修改"
        return 0
    fi
    
    # 获取选择的接口名称
    local selected_interface=$(echo "$interfaces" | sed -n "${choice}p" | awk '{print $1}')
    
    if [ -z "$selected_interface" ]; then
        log_error "无效的选择"
        return 1
    fi
    
    # 生成新的MAC地址
    local new_mac=$(generate_random_mac)
    
    log_info "正在修改接口 $selected_interface 的MAC地址..."
    
    # 关闭网络接口
    sudo ifconfig "$selected_interface" down || {
        log_error "无法关闭网络接口"
        return 1
    }
    
    # 修改MAC地址
    if sudo ifconfig "$selected_interface" ether "$new_mac"; then
        # 重新启用网络接口
        sudo ifconfig "$selected_interface" up
        log_info "成功修改MAC地址为: $new_mac"
        echo
        log_warn "请注意: MAC地址修改可能需要重新连接网络才能生效"
    else
        log_error "修改MAC地址失败"
        # 尝试恢复网络接口
        sudo ifconfig "$selected_interface" up
        return 1
    fi
}

# 主函数
main() {
    # 新增环境检查
    if [[ $(uname) != "Darwin" ]]; then
        log_error "本脚本仅支持 macOS 系统"
        exit 1
    fi
    
    clear
    # 显示 Logo
    echo -e "
   █████████                                                     █████ █████            ███████████  
  ███░░░░░███                                                   ░░███ ░░███            ░░███░░░░░███ 
 ███     ░░░  █████ ████ ████████   █████   ██████  ████████     ░░███ ███              ░███    ░███ 
░███         ░░███ ░███ ░░███░░███ ███░░   ███░░███░░███░░███     ░░█████    ██████████ ░██████████  
░███          ░███ ░███  ░███ ░░░ ░░█████ ░███ ░███ ░███ ░░░       ███░███  ░░░░░░░░░░  ░███░░░░░███ 
░░███     ███ ░███ ░███  ░███      ░░░░███░███ ░███ ░███          ███ ░░███             ░███    ░███ 
 ░░█████████  ░░████████ █████     ██████ ░░██████  █████     ██ █████ █████            █████   █████
  ░░░░░░░░░    ░░░░░░░░ ░░░░░     ░░░░░░   ░░░░░░  ░░░░░     ░░ ░░░░░ ░░░░░            ░░░░░   ░░░░░                                                                                                                                                                                             
    "
echo
    
    check_permissions
    check_and_kill_cursor
    generate_new_config
    
    # 添加MAC地址修改选项
    echo
    log_warn "是否要修改MAC地址？"
    echo "0) 否 - 保持默认设置 (默认)"
    echo "1) 是 - 修改MAC地址"
    echo -n "请输入选择 [0-1] (默认 0): "
    read -r choice
    
    # 处理用户输入（包括空输入和无效输入）
    case "$choice" in
        1)
            if modify_mac_address; then
                log_info "MAC地址修改完成！"
            else
                log_error "MAC地址修改失败"
            fi
            ;;
        *)
            log_info "已跳过MAC地址修改"
            ;;
    esac
    
    show_file_tree
  
    # 启动选项
    echo
    log_warn "是否要启动 Cursor？"
    echo "1) 是 - 立即启动 (默认)"
    echo "0) 否 - 稍后手动启动"
    echo -n "请输入选择 [0-1] (默认 1): "
    read -r choice
    
    case "$choice" in
        0)
            log_info "已跳过启动"
            ;;
        *)
            open -b com.todesktop.230313mzl4w4u92 &>/dev/null
            log_info "已启动 Cursor"
            ;;
    esac
    
    log_info "全部操作完成"
    clear
}
# 执行主函数
main
