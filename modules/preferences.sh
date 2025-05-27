#!/usr/bin/bash

configure() {
    local CONFIG_OPTS UPDATED_CONFIG THEME
    CONFIG_OPTS=("DARK_THEME" "$DARK_THEME" "PREFER_SPLIT_APK" "$PREFER_SPLIT_APK" "LAUNCH_APP_AFTER_MOUNT" "$LAUNCH_APP_AFTER_MOUNT" ALLOW_APP_VERSION_DOWNGRADE "$ALLOW_APP_VERSION_DOWNGRADE" "USE_PRE_RELEASE" "$USE_PRE_RELEASE")

    readarray -t UPDATED_CONFIG < <(
        "${DIALOG[@]}" \
            --title '| Configure |' \
            --no-items \
            --separate-output \
            --no-cancel \
            --ok-label 'Save' \
            --checklist "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "${CONFIG_OPTS[@]}" \
            2>&1 > /dev/tty
    )

    sed -i "s|='on'|='off'|" .config

    for CONFIG_OPT in "${UPDATED_CONFIG[@]}"; do
        setEnv "$CONFIG_OPT" on update .config
    done

    source .config

    [ "$DARK_THEME" == "on" ] && THEME="DARK" || THEME="GREEN"
    export DIALOGRC="config/.DIALOGRC_$THEME"
}
