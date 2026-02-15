#!/usr/bin/bash

CLI_DETECTION_FILE="$HOME/Enhancify/cli_detection.json"

antisplit_apks() {
    if [[ "$CLI_RIPLIB_ANTISPLIT" == "on" ]]; then
        cli_arg_detector >/dev/null 2>&1
        
        if [[ -f "$CLI_DETECTION_FILE" ]]; then
            local striplibs_support riplib_support
            striplibs_support=$(jq -r '.striplibs // false' "$CLI_DETECTION_FILE")
            riplib_support=$(jq -r '.riplib // false' "$CLI_DETECTION_FILE")
            
            if [[ "$striplibs_support" == "true" ]]; then
                notify info "Antisplit Support Detected\nOverrided to CLI based Antisplit\nSkipping ..."
                sleep 2
                return 0
            elif [[ "$riplib_support" == "true" ]]; then
                notify info "Antisplit Support Detected\nOverrided to CLI based Antisplit\nSkipping ..."
                sleep 2
                return 0
            else
                notify info "Critical !!\n$SOURCE Incompatible with CLI Antisplit support\nOverride canceled"
                sleep 2
            fi
        fi
    fi

    local APP_DIR LOCALE

    notify info "Please Wait !!\nProcessing Apks File ..."

    APP_DIR="apps/$APP_NAME/$APP_VER"

    if [ ! -e "$APP_DIR" ]; then
        LOCALE=$(getprop persist.sys.locale | sed 's/-.*//g')
        unzip -qqo \
            "apps/$APP_NAME/$APP_VER.apks" \
            "base.apk" \
            "split_config.${ARCH//-/_}.apk" \
            "split_config.${LOCALE}.apk" \
            split_config.*dpi.apk \
            -d "$APP_DIR" 2> /dev/null
    fi

    java -jar bin/APKEditor.jar m -i "$APP_DIR" -o "apps/$APP_NAME/$APP_VER.apk" &> /dev/null

    if [ ! -e "apps/$APP_NAME/$APP_VER.apk" ]; then
        rm -rf "$APP_DIR" &> /dev/null
        notify msg "Unable to run merge splits!!\nApkEditor is not working properly."
        return 1
    fi
    rm "apps/$APP_NAME/$APP_VER.apks" &> /dev/null

    if [ "$ROOT_ACCESS" == false ]; then
        rm -rf "apps/$APP_NAME/$APP_VER"
    fi
    setEnv "APP_SIZE" "$(stat -c %s "apps/$APP_NAME/$APP_VER.apk")" update "apps/$APP_NAME/.data"
}
