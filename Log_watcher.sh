#!/bin/bash
# 检测apache/nginx日志变化，当出现CRITICAL, ERROR, FATAL这些错误记录时进行告警

[ $(id -u) != "0" ] && { echo -e "\033[31mError:This script must be run as root!\033[0m"; exit 1; } 
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
# ================= 配置区域 =================
# 获取当前脚本所在的目录
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 1. 动态匹配当日日志文件路径（以你的项目日志命名规则为准）
LOG_FILE="/Public_Root/test.com/public_html/logs/log-$(date +%Y-%m-%d).log"

# 2. 记录上次读取位置的偏移量文件
OFFSET_FILE="$DIR/last_position.txt"

# 3. Telegram Bot 配置
BOT_TOKEN="你的Telegram_Bot_Token"
CHAT_ID="你的Telegram_Chat_ID"
# ============================================

# 1. 如果当日日志文件不存在，直接退出
[ ! -f "$LOG_FILE" ] && exit 0

# 2. 获取当前日志文件的字节大小 (兼容 Linux 的 stat 命令)
current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null)
[ -z "$current_size" ] && exit 0

# 3. 读取上一次记录的偏移量
last_offset=0
[ -f "$OFFSET_FILE" ] && last_offset=$(cat "$OFFSET_FILE")

# 4. 如果发生日志轮转或被清空（文件变小了），重置偏移量
if [ "$current_size" -lt "$last_offset" ]; then
    last_offset=0
fi

# 5. 如果大小没变，说明没有新内容，直接退出
if [ "$current_size" -eq "$last_offset" ]; then
    exit 0
fi

# 6. 从上次断点之后开始读取新增的内容 (tail -c 从 1 开始计数，所以偏移量 + 1)
start_byte=$((last_offset + 1))
new_content=$(tail -c +$start_byte "$LOG_FILE")

# 7. 立即更新偏移量文件，记录当前位置
echo "$current_size" > "$OFFSET_FILE"

# 8. 过滤新增内容中是否包含严重错误关键字 (CRITICAL, ERROR, FATAL)
errors=$(echo "$new_content" | grep -E -i '\b(CRITICAL|ERROR|FATAL|CRIT|ALERT|EMERG)\b')

# 9. 如果发现了错误，通过 Telegram 发送告警
if [ -n "$errors" ]; then
    msg="🚨 【服务器故障告警】 🚨

$errors"

    # 使用 curl 的 --data-urlencode 自动处理中文和特殊字符转义，完美避开复杂的 JSON 拼写
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$msg" > /dev/null 2>&1
fi
