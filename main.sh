#!/usr/bin/bash

main() {

    setEnv SOURCE "Anddea" init .config
    setEnv DARK_THEME "off" init .config
    setEnv OPTIMIZE_LIBS "on" init .config
    setEnv LAUNCH_APP_AFTER_MOUNT "on" init .config
    setEnv ALLOW_APP_VERSION_DOWNGRADE "off" init .config
    setEnv SKIP_VERIFICATION "off" init .config
    setEnv BYPASS_LOW_TARGET_SDK_BLOCK "off" init .config
    setEnv CLI_RIPLIB_ANTISPLIT "off" init .config
    setEnv USE_PARALLEL_GC "off" init .config
    source .config

    mkdir -p "assets" "apps" "$STORAGE" "$STORAGE/Patched" "$STORAGE/GmsCore"

    [ "$ROOT_ACCESS" == true ] && MENU_ENTRY=(10 "Unmount Patched app")

    [ "$GREEN_THEME" == "on" ] && THEME="GREEN" || THEME="DARK"
    export DIALOGRC="config/.DIALOGRC_$THEME"

    MSG+="\n"
    MSG+="Initiated Mode : $PRIVILEGE_STATUS\n"
    MSG+="Status : $ONLINE_STATUS\n"
    MSG+="Arch : $ARCH\n"
    MSG+="\n$NAVIGATION_HINT"

    while true; do
        MAIN=$(
            "${DIALOG[@]}" \
                --title '| Main Menu |' \
                --ok-label 'Select' \
                --cancel-label 'Exit' \
                --menu "$MSG" -1 -1 0 \
                1 "Patch App" \
                2 "Update Assets" \
                3 "Change Source" \
                4 "Configure" \
                5 "Fetch Gmscore" \
                6 "Delete Assets" \
                7 "Delete Apps" \
                8 "Specs & Changelog" \
                9 "ARSClib Sources" \
                "${MENU_ENTRY[@]}" \
                2>&1 > /dev/tty
        ) || break
        case "$MAIN" in
            1)
                initiateWorkflow
                ;;
            2)
                fetchAssetsInfo || break
                fetchAssets
                ;;
            3)
                changeSource
                ;;
            4)
                configure
                ;;
            5)
                Fetch_MicroG
                ;;
            6)
                deleteAssets
                ;;
            7)
                deleteApps
                ;;
            8)
                Specifications
                ;;
            9)
                arsclib
                ;;
            10)
                umountApp
                ;;
        esac
    done
}

tput civis
ROOT_ACCESS="$1"
RISH_ACCESS="$2"


for MODULE in $(find modules -type f -name "*.sh"); do
    source "$MODULE"
done

trap terminate SIGTERM SIGINT SIGABRT
main || terminate 1
terminate "$?"
