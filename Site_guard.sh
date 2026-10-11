#!/bin/bash
# 检测Linux系统文件变化
[ $(id -u) != "0" ] && { echo -e "\033[31mError:This script must be run as root!\033[0m"; exit 1; } 
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
# ================= 配置区域 =================
TARGET_PATHS=(
    "/Data/Public_Root/iewb.net/public_html" 
    "/etc/passwd" 
    "/etc/shadow" 
    "/etc/group" 
    "/etc/sudoers" 
    "/etc/ssh/sshd_config" 
    "/etc/crontab"
)

EXCLUDE_LIST=(
    "/Data/Public_Root/iewb.net/public_html/writable" 
    "/Data/Public_Root/iewb.net/public_html/public/uploads"
)

DB_DIR="/var/log/integrity_db"
CURRENT_DB="$DB_DIR/current_md5.txt"
PREV_DB="$DB_DIR/prev_md5.txt"

TG_BOT_TOKEN="你的Telegram_Bot_Token"
TG_CHAT_ID="你的Telegram_Chat_ID"
# ============================================

mkdir -p "$DB_DIR"
[ -f "$CURRENT_DB" ] && cp "$CURRENT_DB" "$PREV_DB"

# 动态构建 find 的排除参数
FIND_EXCLUDE_ARGS=()
for exclude in "${EXCLUDE_LIST[@]}"; do
    FIND_EXCLUDE_ARGS+=( -path "$exclude" -prune -o )
done

# 生成当前 MD5 数据库
> "$CURRENT_DB"
for path in "${TARGET_PATHS[@]}"; do
    if [ -d "$path" ]; then
        find "$path" "${FIND_EXCLUDE_ARGS[@]}" -type f -print0 2>/dev/null | xargs -0 -P 4 md5sum >> "$CURRENT_DB"
    elif [ -f "$path" ]; then
        md5sum "$path" >> "$CURRENT_DB"
    fi
done

# 【核心修复】：对生成的指纹库按文件路径（第2列）进行稳定排序
# 彻底消除由于 find 每次遍历顺序不同而导致的“假性变动”误报
sort -k 2,2 -o "$CURRENT_DB" "$CURRENT_DB"

# 首次运行初始化
if [ ! -f "$PREV_DB" ]; then
    echo "初始化完成：已成功建立基准 MD5 数据库。"
    exit 0
fi

# 对比新旧 MD5 指纹
CHANGES=$(diff "$PREV_DB" "$CURRENT_DB" || true)

# 发送 Telegram 消息
if [ -n "$CHANGES" ]; then
    CHANGED_FILES=$(echo "$CHANGES" | grep '^[><]' | awk '{for(i=2;i<=NF;i++) printf $i " "; print ""}' | sort -u | head -n 10)
    
    MSG="⚠️ 【安全警告】检测到系统或网站文件发生变动！%0A%0A变动文件清单：%0A$CHANGED_FILES"
    
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$MSG" > /dev/null
else
    MSG="✅ 【安全巡检】所有监控文件及目录无变化，系统运行正常。"
    
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$MSG" > /dev/null
fi
