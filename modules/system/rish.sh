#!/usr/bin/bash

applyBackgroundWhitelist() {
    local PKG="$1"

    local CONFIG_FILE="$HOME/Enhancify/.config"
    local FORCE_BACKGROUND_WHITELIST="off"

    if [ -f "$CONFIG_FILE" ]; then
        FORCE_BACKGROUND_WHITELIST=$(grep "^FORCE_BACKGROUND_WHITELIST=" "$CONFIG_FILE" | cut -d"'" -f2)
        FORCE_BACKGROUND_WHITELIST=${FORCE_BACKGROUND_WHITELIST:-off}
    fi

    log "Config: FORCE_BACKGROUND_WHITELIST='$FORCE_BACKGROUND_WHITELIST'"

    if [ "$FORCE_BACKGROUND_WHITELIST" != "on" ]; then
        log "Background whitelist is disabled, skipping."
        return 0
    fi

    log "Applying background whitelist for $PKG..."

    local WL_OUTPUT
    WL_OUTPUT=$(rish -c "cmd deviceidle whitelist +$PKG" 2>&1)
    log "deviceidle whitelist output: $WL_OUTPUT"

    local RIB_OUTPUT
    RIB_OUTPUT=$(rish -c "cmd appops set $PKG RUN_IN_BACKGROUND allow" 2>&1)
    log "appops RUN_IN_BACKGROUND output: $RIB_OUTPUT"

    local RAIB_OUTPUT
    RAIB_OUTPUT=$(rish -c "cmd appops set $PKG RUN_ANY_IN_BACKGROUND allow" 2>&1)
    log "appops RUN_ANY_IN_BACKGROUND output: $RAIB_OUTPUT"

    if rish -c "cmd deviceidle whitelist" 2>/dev/null | grep -q "$PKG"; then
        log "Background whitelist: $PKG confirmed in device-idle whitelist."
        return 0
    else
        log "WARNING: $PKG may not have been added to the device-idle whitelist."
        return 1
    fi
}

runDexOptimization() {
    local PKG="$1"
    local APP_DISPLAY_NAME="$2"
    local INSTALL_TYPE="$3"
    
    local PROFILE_NAME=""
    local PROFILE_MODE=""
    local FORCE_FLAG=""
    
    if [ "$INSTALL_TYPE" == "new" ]; then
        PROFILE_MODE="quicken"
        PROFILE_NAME="Quicken (Lightweight)"
        FORCE_FLAG=""
    elif [ "$INSTALL_TYPE" == "update" ]; then
        PROFILE_MODE="speed"
        PROFILE_NAME="Speed (Maximum Performance)"
        FORCE_FLAG="-f"
    else
        PROFILE_MODE="quicken"
        PROFILE_NAME="Quicken (Default)"
        FORCE_FLAG=""
    fi
    
    log "Running dex optimization for $PKG with profile: $PROFILE_NAME"
    
    notify info "$APP_DISPLAY_NAME Installed Successfully using Rish\nInitiated Patched App Optimization via $PROFILE_NAME"
    
    log "Executing: cmd package compile -m $PROFILE_MODE $FORCE_FLAG $PKG"
    local OPT_OUTPUT
    OPT_OUTPUT=$(rish -c "cmd package compile -m $PROFILE_MODE $FORCE_FLAG $PKG" 2>&1)
    local OPT_EXIT_CODE=$?
    
    log "Optimization output: $OPT_OUTPUT"
    log "Optimization exit code: $OPT_EXIT_CODE"
    
    if echo "$OPT_OUTPUT" | grep -q "^Success"; then
        log "Dex optimization completed successfully for $PKG"
        
        if [ "$INSTALL_TYPE" == "update" ]; then
            log "Executing force-stop for updated app: $PKG"
            local FORCE_STOP_OUTPUT
            FORCE_STOP_OUTPUT=$(rish -c "am force-stop $PKG" 2>&1)
            log "Force-stop output: $FORCE_STOP_OUTPUT"
            log "Force-stop completed for $PKG after speed optimization"
        fi
        
        applyBackgroundWhitelist "$PKG"
        
        notify msg "$APP_DISPLAY_NAME Installed Successfully using Rish with $PROFILE_NAME Optimization"
        return 0
    elif echo "$OPT_OUTPUT" | grep -q "Error: Package not found:"; then
        log "Dex optimization failed: Package not found"
        notify msg "Optimization Failed\nError: Package not found\nFinishing"
        return 1
    elif [ $OPT_EXIT_CODE -ne 0 ]; then
        log "Dex optimization failed with exit code: $OPT_EXIT_CODE"
        notify msg "Optimization Failed\nExit Code: $OPT_EXIT_CODE\nFinishing"
        return 1
    else
        log "Dex optimization Done (no explicit status)"
        
        if [ "$INSTALL_TYPE" == "update" ]; then
            log "Executing force-stop for updated app: $PKG"
            local FORCE_STOP_OUTPUT
            FORCE_STOP_OUTPUT=$(rish -c "am force-stop $PKG" 2>&1)
            log "Force-stop output: $FORCE_STOP_OUTPUT"
            log "Force-stop completed for $PKG after speed optimization"
        fi
        
        applyBackgroundWhitelist "$PKG"
        
        notify msg "$APP_DISPLAY_NAME Installed Successfully using Rish with $PROFILE_NAME Optimization"
        return 0
    fi
}

installAppRish() {
    log() {
        echo "- $1" >> "$STORAGE/rish_log.txt"
    }
    rm -f "$STORAGE/rish_log.txt"
    rm -f "$STORAGE/install_type.txt"
    rm -f "$STORAGE/install_error.txt"
    log "         Enhancify Rish Log"
    log ""

    local UNINSTALL_CURRENT_INSTALLATION=false
    local HIDDEN_APP_INSTALL=false
    local INSTALL_TYPE="new"

    notify info "Please Wait !!\nInstalling $APP_NAME using Rish..."

    local PATCHED_APP_INFO
    if ! PATCHED_APP_INFO=$(./bin/aapt2 dump badging "apps/$APP_NAME/$APP_VER-$SOURCE.apk"); then
        notify msg "The patched Apk is not valid. Patch again and retry."
        return 1
    fi
    PATCHED_APP_PKG_NAME=$(grep -oP "(?<=package: name=')[^']+" <<< "$PATCHED_APP_INFO")
    local PATCHED_APP_APP_NAME=$(grep -oP "(?<=application-label:')[^']+" <<< "$PATCHED_APP_INFO" | sed -E 's/[.: ]+/-/g')
    local PATCHED_APP_VERSION=$(grep -oP "(?<=versionName=')[^']+" <<< "$PATCHED_APP_INFO")

    log "Patched APK info: "
    log "Package Name: $PATCHED_APP_PKG_NAME"
    log "App Name: $PATCHED_APP_APP_NAME"
    log "Version: $PATCHED_APP_VERSION"
    log ""

    if [ "$PATCHED_APP_PKG_NAME" != "$PKG_NAME" ]; then
        log "Package name mismatch: $PATCHED_APP_PKG_NAME != $PKG_NAME, selected APK has a different package name than patched apk."
    fi

    CANONICAL_VER=${APP_VER//:/}
    local EXPORTED_APK_NAME="$APP_NAME-$CANONICAL_VER-$SOURCE"
    cp -f "apps/$APP_NAME/$APP_VER-$SOURCE.apk" "$STORAGE/Patched/$EXPORTED_APK_NAME.apk" &> /dev/null

    log "Checking if $PATCHED_APP_PKG_NAME is installed"
    local INSTALLED_PATCHED_VERSION=$(rish -c "dumpsys package $PATCHED_APP_PKG_NAME" | sed -n '/versionName/s/.*=//p' | sed -n '1p')

    if [ "$INSTALLED_PATCHED_VERSION" != "" ]; then
        INSTALL_TYPE="update"
        log "Installed version of $PATCHED_APP_APP_NAME is $INSTALLED_PATCHED_VERSION"
        log "Install type determined: UPDATE"
        log "Verifying signatures..."
        local STOCK_APP_PATH
        if [ "$(rish -c "pm list packages --user current | grep -q $PATCHED_APP_PKG_NAME && echo Installed")" == "Installed" ]; then
            STOCK_APP_PATH=$(rish -c "pm path --user current $PATCHED_APP_PKG_NAME | sed -n '/base/s/package://p'")
        else
            STOCK_APP_PATH=$(rish -c "dumpsys package $PATCHED_APP_PKG_NAME | sed -n 's/^[[:space:]]*path: \(.*base\.apk\)/\1/p'")
            log "Dumpsys used to get stock app path, that means the app is installed but in a different user."
            HIDDEN_APP_INSTALL=true
        fi
        local STOCK_APP_SIGNATURE=$(keytool -printcert -jarfile "$STOCK_APP_PATH" 2>/dev/null | awk '/SHA256:/{print $2}' | tr -d ':')
        local PATCHED_APP_SIGNATURE=$(keytool -printcert -jarfile "apps/$APP_NAME/$APP_VER-$SOURCE.apk" 2>/dev/null | awk '/SHA256:/{print $2}' | tr -d ':')
        if [ "$STOCK_APP_SIGNATURE" != "$PATCHED_APP_SIGNATURE" ]; then
            log "Signature mismatch: We need to uninstall the current APP."
            if [ "$HIDDEN_APP_INSTALL" == true ]; then
                log "Case 1: App installed in a different user with a different signature, we'll try to install the app in current user."
            else
                dialog --backtitle 'Enhancify' --defaultno \
                    --yesno "The current app has a different signature than the patched one.\n\nDo you want to uninstall the current app and proceed?" 12 45
                if [ $? -eq 0 ]; then
                    log "Case 2: User accepted to uninstall the current app for current user."
                    UNINSTALL_CURRENT_INSTALLATION=true
                else
                    log "Case 2: User declined to uninstall the current app."
                    notify msg "User declined to uninstall the current app.\n\nAborting installation...\n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
                    return 1
                fi
            fi
        else
            log "Signature match, we can upgrade the app."
        fi
    else
        INSTALL_TYPE="new"
        log "No installed version found for $PATCHED_APP_APP_NAME found, proceeding with installation."
        log "Install type determined: NEW INSTALL"
    fi

    if [ "$UNINSTALL_CURRENT_INSTALLATION" == false ]; then
        log "Checking if it's a downgrade..."
        if jq -e '.[0] > .[1]' <<< "[\"${INSTALLED_PATCHED_VERSION:-0}\", \"$PATCHED_APP_VERSION\"]" &> /dev/null; then
            log "Case 3: Installed version $INSTALLED_PATCHED_VERSION is greater than the new version $PATCHED_APP_VERSION, we are downgrading."
            if [ "$ALLOW_APP_VERSION_DOWNGRADE" == "on" ]; then
                log "Case 3: Downgrades are allowed, asking user for permission to uninstall the current app."
                
                dialog --backtitle 'Enhancify' --defaultno \
                    --yesno "The current app version $INSTALLED_PATCHED_VERSION is greater than the new version $PATCHED_APP_VERSION.\n\nDo you want to uninstall the current version and proceed with the downgrade?" 12 45

                if [ $? -eq 0 ]; then
                    log "Case 3: User agreed to uninstall for clean reinstall."
                    UNINSTALL_CURRENT_INSTALLATION=true
                else
                    log "Case 3: User decided not to uninstall to continue the downgrade. Aborting..."
                    notify msg "User declined to uninstall the current version.\n\nAborting installation...\n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
                    return 1
                fi
            else
                log "Case 3: Downgrades are not allowed, exiting."
                notify msg "Downgrades are not allowed in Configuration, exiting.\n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
                return 1
            fi
        else
            log "Case 4: No version conflict detected or signatures, proceeding with installation."
        fi
    fi

    if [ "$UNINSTALL_CURRENT_INSTALLATION" == true ]; then
        notify info "Please Wait !!\nUninstalling $PATCHED_APP_APP_NAME using Rish..."
        if uninstallAppRish false true "$STORAGE"; then
            log "Uninstallation successful, proceeding with installation."
            if ! rish -c "dumpsys package $PATCHED_APP_PKG_NAME" 2>&1 | grep -q "Unable to find package"; then
                log "Found hidden installation post uninstallation. This might be a different user."
                HIDDEN_APP_INSTALL=true
            fi
        else
            log "Uninstallation failed."
            message="Failed to uninstall the current app.\n\nAborting installation...\n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
            notify msg "$message"
            return 1
        fi
    fi

    notify info "Please Wait !!\nInstalling $PATCHED_APP_APP_NAME $PATCHED_APP_VERSION using Rish..."

    log "Attempting to install the patched APK..."
    log "Passing install type to rish-install.sh: $INSTALL_TYPE"
    
    if bash system/rish-install.sh "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME" "$EXPORTED_APK_NAME" "$STORAGE" "$INSTALL_TYPE"; then
        log "Installation command executed successfully."
        
        if [ -f "$STORAGE/install_type.txt" ]; then
            INSTALL_TYPE=$(cat "$STORAGE/install_type.txt")
            log "Read install type from file: $INSTALL_TYPE"
        fi
        
        runDexOptimization "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME $PATCHED_APP_VERSION" "$INSTALL_TYPE"
        
    elif [ "$HIDDEN_APP_INSTALL" == true ] ; then
        log "First installation attempt failed, trying again after uninstallation."
        if [ -f "$STORAGE/install_error.txt" ]; then
            local FAIL_REASON=$(cat "$STORAGE/install_error.txt")
            log "Install error detail: $FAIL_REASON"
        fi
    else
        log "Installation of $PATCHED_APP_APP_NAME $PATCHED_APP_VERSION failed."
        local FAIL_REASON=""
        if [ -f "$STORAGE/install_error.txt" ]; then
            FAIL_REASON=$(cat "$STORAGE/install_error.txt")
            log "Install error detail: $FAIL_REASON"
        fi
        if [ -n "$FAIL_REASON" ]; then
            notify msg "Installation Failed !!\nReason: $FAIL_REASON\nShare logs to developer."
        else
            notify msg "Installation Failed !!\nShare logs to developer."
        fi
        termux-open --send "$STORAGE/rish_log.txt"
        return 1
    fi

    if [ "$HIDDEN_APP_INSTALL" = true ]; then
        log "Getting second attempt, this can happen in Cases 1, 2, 3, if we have multiple users in the device with the app..."
        
        local FIRST_FAIL_REASON=""
        if [ -f "$STORAGE/install_error.txt" ]; then
            FIRST_FAIL_REASON=$(cat "$STORAGE/install_error.txt")
        fi
        
        dialog --backtitle 'Enhancify' --defaultno \
            --yesno "We coudn't install the App.\nReason: ${FIRST_FAIL_REASON:-Unknown}\n\nA different user probably has an incompatible $PATCHED_APP_APP_NAME app.\n\nDo you want to uninstall $PATCHED_APP_APP_NAME from all users and proceed?\nWe cannot guarantee this will succeed..." 14 50
        if [ $? -eq 0 ]; then
            log "User accepted to uninstall the app from all users."
            notify info "Please Wait !!\nUninstalling $PATCHED_APP_APP_NAME from all users using Rish..."
            if uninstallAppRish true true "$STORAGE"; then
                log "Uninstallation from all users successful, proceeding with installation."
                notify info "Please Wait !!\nInstalling $PATCHED_APP_APP_NAME $PATCHED_APP_VERSION using Rish..."
                
                if bash system/rish-install.sh "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME" "$EXPORTED_APK_NAME" "$STORAGE" "$INSTALL_TYPE"; then
                    log "Installation command executed successfully after uninstallation from all users."
                    
                    if [ -f "$STORAGE/install_type.txt" ]; then
                        INSTALL_TYPE=$(cat "$STORAGE/install_type.txt")
                        log "Read install type from file: $INSTALL_TYPE"
                    fi
                    
                    runDexOptimization "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME $PATCHED_APP_VERSION" "$INSTALL_TYPE"
                    
                else
                    log "Installation failed after uninstallation from all users."
                    local SECOND_FAIL_REASON=""
                    if [ -f "$STORAGE/install_error.txt" ]; then
                        SECOND_FAIL_REASON=$(cat "$STORAGE/install_error.txt")
                        log "Install error detail: $SECOND_FAIL_REASON"
                    fi
                    if [ -n "$SECOND_FAIL_REASON" ]; then
                        notify msg "Installation Failed !!\nReason: $SECOND_FAIL_REASON\nShare logs to developer. \n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
                    else
                        notify msg "Installation Failed !!\nShare logs to developer. \n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
                    fi
                    termux-open --send "$STORAGE/rish_log.txt"
                    return 1
                fi
            else
                log "Uninstallation from all users failed, aborting installation."
                notify msg "Failed to uninstall the app from all users.\n\nAborting installation...\n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
                return 1
            fi
        else
            log "User declined to uninstall the app from all users, aborting installation."
            notify msg "User declined to uninstall the app from all users.\n\nAborting installation...\n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
            return 1
        fi
    fi

    rm -f "$STORAGE/install_type.txt"
    rm -f "$STORAGE/install_error.txt"
    
    log "Installation of $PATCHED_APP_APP_NAME $PATCHED_APP_VERSION completed successfully, finalized code."
    if [ "$LAUNCH_APP_AFTER_MOUNT" == "on" ]; then
        rish -c "settings list secure | sed -n -e 's/\/.*//' -e 's/default_input_method=//p' | xargs am force-stop && pm resolve-activity --brief $PKG_NAME | tail -n 1 | xargs am start -n && am force-stop com.termux"  &> /dev/null
    fi
    return 0
}

uninstallAppRish() {
    local UNINSTALL_FROM_ALL_USERS="$1"
    local KEEP_LOG="$2"

    log () {
        echo "- $1" >> "$STORAGE/rish_log.txt"
    }
    if [ "$KEEP_LOG" != true ] && [ -f "$STORAGE/rish_log.txt" ]; then
        rm "$STORAGE/rish_log.txt"
    fi

    if [ -z "$PATCHED_APP_PKG_NAME" ]; then
        log "PATCHED_APP_PKG_NAME is not set. Aborting uninstallation."
        return 1
    fi

    if [ "$UNINSTALL_FROM_ALL_USERS" = true ]; then
        log "Uninstalling from all users..."
        if bash system/rish-uninstall.sh "$PATCHED_APP_PKG_NAME" true "$STORAGE"; then
            return 0
        else
            return 1
        fi
    else
        log "Uninstalling from current user..."
        if bash system/rish-uninstall.sh "$PATCHED_APP_PKG_NAME" false "$STORAGE"; then
            return 0
        else
            return 1
        fi
    fi
}
