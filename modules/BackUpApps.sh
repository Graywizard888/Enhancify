backup_app() {
    local Apps="$HOME/Enhancify/apps"
    local dst="$HOME/storage/shared/Enhancify/Stock"

    if [[ ! -d "$Apps" ]]; then
        notify msg "Apps Folder Is Empty\nDownload App and try again"
        return 1
    fi

    local apk_count
    apk_count=$(find "$Apps" -mindepth 2 -maxdepth 2 -type f -name "*.apk" 2>/dev/null | wc -l)

    if [[ $apk_count -eq 0 ]]; then
        notify msg "Apps Folder Is Empty\nDownload App and try again"
        return 1
    fi

    if ! mkdir -p "$dst" 2>&1; then
        notify msg "Failed to create backup directory\nRun: termux-setup-storage"
        return 1
    fi

    notify info "Backing up $apk_count apps..."

    local copied=0
    while IFS= read -r -d '' apk; do
        if cp -f "$apk" "$dst/" 2>/dev/null; then
            ((copied++))
        fi
    done < <(find "$Apps" -mindepth 2 -maxdepth 2 -type f -name "*.apk" -print0)

    if [[ $copied -gt 0 ]] && [[ -d "$dst" ]]; then
        local actual_count
        actual_count=$(find "$dst" -maxdepth 1 -type f -name "*.apk" 2>/dev/null | wc -l)

        if [[ $actual_count -gt 0 ]]; then
            notify msg "Backup completed\n$actual_count apps backed up at Internal storage/Enhancify/Stock"
            return 0
        fi
    fi

    notify msg "Backup failed\nCheck storage permissions"
    return 1
}
