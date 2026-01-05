#!/usr/bin/bash

antisplit_apkm() {
    if [ "$CLI_RIPLIB_ANTISPLIT" = "on" ]; then
        cli_arg_detector >/dev/null 2>&1

        if [ "$SUPPORTS_RIP_LIB" = "true" ]; then
            notify info "Antisplit Support Detected Overrided to CLI based Antisplit\nSkipping ..."
            sleep 2
            return 0
        else
            notify info "Critical !!\n$SOURCE Incompatible with CLI Antisplit\nOverride canceled"
            sleep 2
        fi
    fi

    local APP_DIR LOCALE

    notify info "Please Wait !!\nProcessing Apkm File ..."

    APP_DIR="apps/$APP_NAME/$APP_VER"

    if [ ! -e "$APP_DIR" ]; then
        LOCALE=$(getprop persist.sys.locale | sed 's/-.*//g')
        unzip -qqo \
            "apps/$APP_NAME/$APP_VER.apkm" \
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
    rm "apps/$APP_NAME/$APP_VER.apkm" &> /dev/null

    if [ "$ROOT_ACCESS" == false ]; then
        rm -rf "apps/$APP_NAME/$APP_VER"
    fi
    setEnv "APP_SIZE" "$(stat -c %s "apps/$APP_NAME/$APP_VER.apk")" update "apps/$APP_NAME/.data"
}
