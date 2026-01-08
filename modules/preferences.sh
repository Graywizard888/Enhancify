configure() {
    while true; do
        local MAIN_CHOICE
        MAIN_CHOICE=$("${DIALOG[@]}" \
            --title '| Settings |' \
            --cancel-label 'Back' \
            --ok-label 'Select' \
            --menu "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "Toggle Options" "Modify Toggle Settings" \
            "Custom Sources" "(Experimental)" \
            "Auto Upgrade" "Fix Dependency Issues" \
            "Custom Keystore Management" "Manage Your Keystore" \
            "Custom Token Management" "Manage Github Token" \
            "Backup Apps" "Backup Stock Apps" \
            "Installer Flags" "Toggle Installer Flags" \
            "Apkmirror Configurations" "Manage Scraper configs" \
            2>&1 > /dev/tty)

        case $MAIN_CHOICE in
            "Toggle Options")
                toggle_options
                ;;
            "Custom Sources")
                custom_source_management
                ;;
            "Auto Upgrade")
                auto_update
                ;;
            "Custom Keystore Management")
                ManageKeystore
                ;;
            "Custom Token Management")
                custom_token
                ;;
            "Backup Apps")
                backup_app
                ;;
           "Installer Flags")
                toggle_flags
                ;;
           "Apkmirror Configurations")
                apkmirror_management
                ;;
            *)
                break
                ;;
        esac
    done
}

toggle_options() {
    local CONFIG_OPTS UPDATED_CONFIG THEME
    CONFIG_OPTS=("GREEN_THEME" "$GREEN_THEME" "PREFER_SPLIT_APK" "$PREFER_SPLIT_APK" "OPTIMIZE_LIBS" "$OPTIMIZE_LIBS" "LAUNCH_APP_AFTER_MOUNT" "$LAUNCH_APP_AFTER_MOUNT" "ALLOW_APP_VERSION_DOWNGRADE" "$ALLOW_APP_VERSION_DOWNGRADE" "USE_PRE_RELEASE" "$USE_PRE_RELEASE" "DISABLE_NETWORK_ACCELERATION" "$DISABLE_NETWORK_ACCELERATION" "Use_CUSTOM_KEYSTORE" "$Use_CUSTOM_KEYSTORE" "CLI_RIPLIB_ANTISPLIT" "$CLI_RIPLIB_ANTISPLIT")

    local PREVIOUS_PRE_RELEASE="$USE_PRE_RELEASE"

    readarray -t UPDATED_CONFIG < <(
        "${DIALOG[@]}" \
            --title '| Toggle Options |' \
            --no-items \
            --separate-output \
            --no-cancel \
            --ok-label 'Save' \
            --checklist "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "${CONFIG_OPTS[@]}" \
            2>&1 > /dev/tty
    )

    sed -i "s|^GREEN_THEME='on'|GREEN_THEME='off'|" .config
    sed -i "s|^PREFER_SPLIT_APK='on'|PREFER_SPLIT_APK='off'|" .config
    sed -i "s|^OPTIMIZE_LIBS='on'|OPTIMIZE_LIBS='off'|" .config
    sed -i "s|^LAUNCH_APP_AFTER_MOUNT='on'|LAUNCH_APP_AFTER_MOUNT='off'|" .config
    sed -i "s|^ALLOW_APP_VERSION_DOWNGRADE='on'|ALLOW_APP_VERSION_DOWNGRADE='off'|" .config
    sed -i "s|^USE_PRE_RELEASE='on'|USE_PRE_RELEASE='off'|" .config
    sed -i "s|^DISABLE_NETWORK_ACCELERATION='on'|DISABLE_NETWORK_ACCELERATION='off'|" .config
    sed -i "s|^Use_CUSTOM_KEYSTORE='on'|Use_CUSTOM_KEYSTORE='off'|" .config
    sed -i "s|^CLI_RIPLIB_ANTISPLIT='on'|CLI_RIPLIB_ANTISPLIT='off'|" .config

    for CONFIG_OPT in "${UPDATED_CONFIG[@]}"; do
        setEnv "$CONFIG_OPT" on update .config
    done

    source .config

    if [[ "$USE_PRE_RELEASE" == "on" && "$PREVIOUS_PRE_RELEASE" == "off" ]]; then
        notify msg "WARNING: \nPre-release patches are enabled. \nThis Patches Are Under Development And Can Cause Issues While Patching And App Runtime"
    fi

    [ "$GREEN_THEME" == "on" ] && THEME="GREEN" || THEME="DARK"
    export DIALOGRC="config/.DIALOGRC_$THEME"
}
