#!/bin/bash
set -e

# ================= Cloudflare R2 信息（运行时手动输入） =================
R2_ACCOUNT_ID=""
R2_ACCESS_KEY=""
R2_SECRET_KEY=""
R2_BUCKET_NAME=""
BACKUP_NAME="system_full_backup.tar.gz"
# ======================================================================

ask_required() {
    local var="$1"
    local text="$2"
    local secret="${3:-false}"
    local value=""

    while [ -z "$value" ]; do
        if [ "$secret" = "true" ]; then
            read -r -s -p "$text: " value
            echo
        else
            read -r -p "$text: " value
        fi

        if [ -z "$value" ]; then
            echo "不能为空，请重新输入。"
        fi
    done

    printf -v "$var" '%s' "$value"
}

collect_r2_config() {
    echo "====== 0. 输入 Cloudflare R2 信息 ======"
    ask_required R2_ACCOUNT_ID "Cloudflare Account ID"
    ask_required R2_ACCESS_KEY "R2 Access Key ID"
    ask_required R2_SECRET_KEY "R2 Secret Access Key" true
    ask_required R2_BUCKET_NAME "R2 Bucket Name"

    read -r -p "备份文件名 [$BACKUP_NAME]: " input_backup_name
    if [ -n "$input_backup_name" ]; then
        BACKUP_NAME="$input_backup_name"
    fi
}

collect_r2_config

echo "====== 1. 检查并安装必备工具 ======"
if ! command -v pv &> /dev/null; then
    apt-get update && apt-get install -y pv
fi
if ! command -v rclone &> /dev/null; then
    curl https://rclone.org/install.sh | bash
fi

echo "====== 2. 自动生成 rclone 配置文件 ======"
mkdir -p ~/.config/rclone
cat << EOF > ~/.config/rclone/rclone.conf
[cloudflare_r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
EOF

echo "====== 3. 正在从 Cloudflare R2 下载备份文件 ======"
rclone copy cloudflare_r2:${R2_BUCKET_NAME}/${BACKUP_NAME} /root/ --progress

echo "====== 4. 开始解压并恢复数据到 /root 目录 ======"
# 获取压缩包大小用于进度条
FILE_SIZE=$(stat -c%s "/root/${BACKUP_NAME}")

pv -p -t -e -r -s $FILE_SIZE "/root/${BACKUP_NAME}" | tar -xzf - --strip-components=1 -C /root/

echo "🎉 一键全盘数据恢复成功！你可以开始启动各个 Docker 容器了。"

