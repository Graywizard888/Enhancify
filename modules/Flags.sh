toggle_flags() {
    local FLAG_OPTS UPDATED_FLAGS
    FLAG_OPTS=("SKIP_VERIFICATION" "$SKIP_VERIFICATION" "BYPASS_LOW_TARGET_SDK_BLOCK" "$BYPASS_LOW_TARGET_SDK_BLOCK")

    readarray -t UPDATED_FLAGS < <(
        "${DIALOG[@]}" \
            --title '| Rish Installer Flags |' \
            --no-items \
            --separate-output \
            --no-cancel \
            --ok-label 'Save' \
            --checklist "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "${FLAG_OPTS[@]}" \
            2>&1 > /dev/tty
    )

    sed -i "s|^SKIP_VERIFICATION='on'|SKIP_VERIFICATION='off'|" .config
    sed -i "s|^BYPASS_LOW_TARGET_SDK_BLOCK='on'|BYPASS_LOW_TARGET_SDK_BLOCK='off'|" .config

    for FLAG_OPT in "${UPDATED_FLAGS[@]}"; do
        sed -i "s|^${FLAG_OPT}='off'|${FLAG_OPT}='on'|" .config
    done

    source .config
}
