#!/bin/bash
# AppPorts Auto Re-Sign LaunchAgent
# Runs at user login to re-sign migrated apps whose ad-hoc signatures
# may have been invalidated by macOS Gatekeeper after restart.
#
# Installed by AppPorts → ~/Library/Application Support/AppPorts/re-sign-at-login.sh
# Triggered by      → ~/Library/LaunchAgents/com.shimoko.AppPorts.re-sign.plist

set -euo pipefail

BACKUP_DIR="$HOME/Library/Application Support/AppPorts/signature-backups"
LOG_DIR="$HOME/Library/Application Support/AppPorts"

# 读取 AppPorts 设置中的自定义日志路径，无则用默认路径
CUSTOM_LOG_PATH=$(defaults read com.shimoko.AppPorts LogFilePath 2>/dev/null || true)
if [ -n "$CUSTOM_LOG_PATH" ] && [ -d "$(dirname "$CUSTOM_LOG_PATH")" ]; then
    LOG_FILE="$CUSTOM_LOG_PATH"
else
    LOG_FILE="$LOG_DIR/AppPorts_Log.txt"
fi

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RE-SIGN] $1" >> "$LOG_FILE"
}

log "=== 开机重签名任务开始 ==="

if [ ! -d "$BACKUP_DIR" ]; then
    log "签名备份目录不存在，跳过: $BACKUP_DIR"
    exit 0
fi

shopt -s nullglob
backup_files=("$BACKUP_DIR"/*.plist)
shopt -u nullglob

if [ ${#backup_files[@]} -eq 0 ]; then
    log "无签名备份文件，跳过"
    exit 0
fi

log "发现 ${#backup_files[@]} 个签名备份文件"

signed_count=0
skipped_count=0
failed_count=0

for plist in "${backup_files[@]}"; do
    # 跳过 stub portal 备份（bundleIdentifier 含 .appports.stub）
    bundle_id=$(/usr/libexec/PlistBuddy -c "Print :bundleIdentifier" "$plist" 2>/dev/null || true)
    if [[ "$bundle_id" == *.appports.stub ]]; then
        log "SKIP stub: $(basename "$plist")"
        ((skipped_count++)) || true
        continue
    fi

    # 跳过非 ad-hoc 签名备份（有开发者证书的不需要重签）
    signing_id=$(/usr/libexec/PlistBuddy -c "Print :signingIdentity" "$plist" 2>/dev/null || true)
    if [ "$signing_id" != "ad-hoc" ] && [ -n "$signing_id" ]; then
        log "SKIP 非 ad-hoc: $(basename "$plist") ($signing_id)"
        ((skipped_count++)) || true
        continue
    fi

    app_path=$(/usr/libexec/PlistBuddy -c "Print :originalPath" "$plist" 2>/dev/null || true)
    if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
        log "SKIP 路径不存在: $(basename "$plist") → $app_path"
        ((skipped_count++)) || true
        continue
    fi

    # 检查是否可写（root 所有的跳过）
    if [ ! -w "$app_path" ]; then
        log "SKIP 不可写: $app_path"
        ((skipped_count++)) || true
        continue
    fi

    # 清理隔离属性
    /usr/bin/xattr -cr "$app_path" 2>/dev/null || true

    # 清理 bundle 根目录杂物
    for stray in .DS_Store __MACOSX .git .svn; do
        if [ -e "$app_path/$stray" ]; then
            rm -rf "$app_path/$stray" 2>/dev/null || true
        fi
    done

    # Ad-hoc 重签名
    if /usr/bin/codesign --force --deep --sign - "$app_path" 2>>"$LOG_FILE"; then
        log "OK  签名成功: $app_path"
        ((signed_count++)) || true
    else
        # 回退无 --deep 的浅层签名
        if /usr/bin/codesign --force --sign - "$app_path" 2>>"$LOG_FILE"; then
            log "OK  浅层签名: $app_path"
            ((signed_count++)) || true
        else
            log "FAIL 签名失败: $app_path"
            ((failed_count++)) || true
        fi
    fi
done

log "=== 完成: 成功=$signed_count 跳过=$skipped_count 失败=$failed_count ==="
