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
    setEnv FORCE_BACKGROUND_WHITELIST "off" init .config
    setEnv CACHE_CLI "off" init .config
    setEnv ENABLE_MULTIPATCHER "off" init .config
    source .config

    mkdir -p "assets" "apps" "$STORAGE" "$STORAGE/Patched" "$STORAGE/GmsCore"

    [ "$ROOT_ACCESS" == true ] && MENU_ENTRY=(9 "Unmount Patched app")

    [ "$GREEN_THEME" == "on" ] && THEME="GREEN" || THEME="DARK"
    export DIALOGRC="config/.DIALOGRC_$THEME"

    MSG+="Initiated Mode : $PRIVILEGE_STATUS ⚙️\n"
    MSG+="Status : $ONLINE_STATUS 🌐\n"
    MSG+="Arch : $ARCH 🤖\n"
    MSG+="\n$NAVIGATION_HINT"

    while true; do
        MAIN=$(
            "${DIALOG[@]}" \
                --title '| Main Menu |' \
                --ok-label 'Select' \
                --cancel-label 'Exit' \
                --menu "$MSG" -1 -1 0 \
                1 "🚀 Patch App" \
                2 "📝 Change Source" \
                3 "🚀 Bundle Patcher (Experimental)" \
                4 "🔧 Configure" \
                5 "🔌 Fetch Gmscore" \
                6 "❌ Delete Assets" \
                7 "❌ Delete Apps" \
                8 "📋 Specs & Changelog" \
                "${MENU_ENTRY[@]}" \
                2>&1 > /dev/tty
        ) || break
        case "$MAIN" in
            1)
                initiateWorkflow
                ;;
            2)
                changeSource
                ;;
            3)
                bundleParser
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
                umountApp
                ;;
        esac
    done
}

tput civis
ROOT_ACCESS="$1"
RISH_ACCESS="$2"

# Android 17 (dev preview) with the thedjchi Shizuku fork prints an
# "Entering shell..." banner (to stdout, and possibly stderr) before every
# command. It is emitted via println(), so it is always on its own line and
# the real command output follows it. We delete that banner line, and also
# strip the banner as a prefix if anything follows it on the same line, so
# captured output (e.g. `$(rish -c "...")`) is never polluted and real
# success/error output keeps priority. The real rish exit code is preserved.
rish() {
    local _rish_err _rish_rc _rish_del _rish_strip
    _rish_del='/^[[:space:]]*Entering shell\.\.*[[:space:]]*$/d'
    _rish_strip='s/^[[:space:]]*Entering shell\.\.*[[:space:]]*//'
    _rish_err=$(mktemp) 2>/dev/null
    if [ -n "$_rish_err" ]; then
        command rish "$@" 2>"$_rish_err" | sed -e "$_rish_del" -e "$_rish_strip"
        _rish_rc=${PIPESTATUS[0]}
        sed -e "$_rish_del" -e "$_rish_strip" "$_rish_err" >&2
        rm -f "$_rish_err"
    else
        command rish "$@" | sed -e "$_rish_del" -e "$_rish_strip"
        _rish_rc=${PIPESTATUS[0]}
    fi
    return "$_rish_rc"
}

for MODULE in $(find modules -type f -name "*.sh"); do
    source "$MODULE"
done

trap terminate SIGTERM SIGINT SIGABRT
main || terminate 1
terminate "$?"
