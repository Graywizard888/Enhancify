backup_app() {
    local apps="$HOME/Enhancify/apps"
    local dst="$HOME/storage/Enhancify/stock"

    if [[ ! -d "$apps" ]]; then
        notify msg "Apps Folder Is Empty\nDownload App and try again"
        return 1
    fi

    local apk_count
    apk_count=$(find "$apps" -mindepth 2 -maxdepth 2 -type f -name "*.apk" 2>/dev/null | wc -l)

    if [[ $apk_count -eq 0 ]]; then
        notify msg "Apps Folder Is Empty\nDownload App and try again"
        return 1
    fi

    mkdir -p "$dst"

    notify info "Backing up apps"

    sleep 1

    if find "$apps" -mindepth 2 -maxdepth 2 -type f -name "*.apk" -exec cp -f {} "$dst"/ \; 2>/dev/null; then
        notify msg "Backup completed\nBacked up at Internal storage/Enhancify/stock"
        return 0
    else
        notify msg "Backup failed"
        return 1
    fi
}