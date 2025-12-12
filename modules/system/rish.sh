#!/usr/bin/bash

# Function to run dex optimization and show appropriate notifications
runDexOptimization() {
    local PKG="$1"
    local APP_DISPLAY_NAME="$2"
    local INSTALL_TYPE="$3"
    
    local PROFILE_NAME=""
    local PROFILE_MODE=""
    local FORCE_FLAG=""
    
    # Determine profile name and mode based on install type
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
    
    log "Running dex optimization for $PKG with profile: $PROFILE_NAME ($PROFILE_MODE)"
    
    # Show initiated notification
    notify info "$APP_DISPLAY_NAME Installed Successfully using Rish\nInitiated Patched App Optimization via $PROFILE_NAME"
    
    # Run optimization in foreground and capture output
    log "Executing: cmd package compile -m $PROFILE_MODE $FORCE_FLAG $PKG"
    local OPT_OUTPUT
    OPT_OUTPUT=$(rish -c "cmd package compile -m $PROFILE_MODE $FORCE_FLAG $PKG" 2>&1)
    local OPT_EXIT_CODE=$?
    
    log "Optimization output: $OPT_OUTPUT"
    log "Optimization exit code: $OPT_EXIT_CODE"
    
    # Check optimization result
    if echo "$OPT_OUTPUT" | grep -q "^Success"; then
        log "Dex optimization completed successfully for $PKG"
        
        # Force stop app after update optimization (before notification)
        if [ "$INSTALL_TYPE" == "update" ]; then
            log "Executing force-stop for updated app: $PKG"
            local FORCE_STOP_OUTPUT
            FORCE_STOP_OUTPUT=$(rish -c "am force-stop $PKG" 2>&1)
            log "Force-stop output: $FORCE_STOP_OUTPUT"
            log "Force-stop completed for $PKG after speed optimization"
        fi
        
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
        # If no explicit success but also no error, assume success
        log "Dex optimization completed (no explicit status)"
        
        # Force stop app after update optimization (before notification)
        if [ "$INSTALL_TYPE" == "update" ]; then
            log "Executing force-stop for updated app: $PKG"
            local FORCE_STOP_OUTPUT
            FORCE_STOP_OUTPUT=$(rish -c "am force-stop $PKG" 2>&1)
            log "Force-stop output: $FORCE_STOP_OUTPUT"
            log "Force-stop completed for $PKG after speed optimization"
        fi
        
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
    log "START INSTALL"

    local UNINSTALL_CURRENT_INSTALLATION=false
    local HIDDEN_APP_INSTALL=false
    local INSTALL_TYPE="new"

    # Case 1: App is installed in a different user with a different signature, we might need to uninstall the app from all users (if the system allows it)
    # Case 2: App is installed in the current user with a different signature, we might need to uninstall the app from all users or just the current user (if the system doesn't allow uninstalling from all users)
    # Case 3: We're installing a downgrade, no matter the signature, we need to uninstall the current app first, from current user, if it fails we can try to uninstall from all users
    # Case 4: Clean install, no app installed, we can proceed with the installation

    notify info "Please Wait !!\nInstalling $APP_NAME using Rish..."

    # Obtain the pkg name and version of the patched APK
    local PATCHED_APP_INFO
    if ! PATCHED_APP_INFO=$(./bin/aapt2 dump badging "apps/$APP_NAME/$APP_VER-$SOURCE.apk"); then
        notify msg "The patched Apk is not valid. Patch again and retry."
        return 1
    fi
    PATCHED_APP_PKG_NAME=$(grep -oP "(?<=package: name=')[^']+" <<< "$PATCHED_APP_INFO")
    local PATCHED_APP_APP_NAME=$(grep -oP "(?<=application-label:')[^']+" <<< "$PATCHED_APP_INFO" | sed -E 's/[.: ]+/-/g')
    local PATCHED_APP_VERSION=$(grep -oP "(?<=versionName=')[^']+" <<< "$PATCHED_APP_INFO")

    log "Patched APK info: Package Name: $PATCHED_APP_PKG_NAME, App Name: $PATCHED_APP_APP_NAME, Version: $PATCHED_APP_VERSION"

    if [ "$PATCHED_APP_PKG_NAME" != "$PKG_NAME" ]; then
        log "Package name mismatch: $PATCHED_APP_PKG_NAME != $PKG_NAME, selected APK has a different package name than patched apk."
    fi

    # Copy the patched APK to the storage
    CANONICAL_VER=${APP_VER//:/}
    local EXPORTED_APK_NAME="$APP_NAME-$CANONICAL_VER-$SOURCE"
    cp -f "apps/$APP_NAME/$APP_VER-$SOURCE.apk" "$STORAGE/Patched/$EXPORTED_APK_NAME.apk" &> /dev/null

    # Verify current installed version and signatures
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

    # Check if we're already due for uninstallation
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
    
    # Pass install type as 5th parameter to rish-install.sh
    if bash system/rish-install.sh "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME" "$EXPORTED_APK_NAME" "$STORAGE" "$INSTALL_TYPE"; then
        log "Installation command executed successfully."
        
        # Read install type from file (in case it was auto-detected differently)
        if [ -f "$STORAGE/install_type.txt" ]; then
            INSTALL_TYPE=$(cat "$STORAGE/install_type.txt")
            log "Read install type from file: $INSTALL_TYPE"
        fi
        
        # Run dex optimization with notifications
        runDexOptimization "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME $PATCHED_APP_VERSION" "$INSTALL_TYPE"
        
    elif [ "$HIDDEN_APP_INSTALL" == true ] ; then
        log "First installation attempt failed, trying again after uninstallation."
    else
        log "Installation of $PATCHED_APP_APP_NAME $PATCHED_APP_VERSION failed."
        notify msg "Installation Failed !!\nShare logs to developer."
        termux-open --send "$STORAGE/rish_log.txt"
        return 1
    fi

    if [ "$HIDDEN_APP_INSTALL" = true ]; then
        log "Getting second attempt, this can happen in Cases 1, 2, 3, if we have multiple users in the device with the app..."
        
        dialog --backtitle 'Enhancify' --defaultno \
            --yesno "We coudn't install the App.\nA different user probably has an incompatible $PATCHED_APP_APP_NAME app.\n\nDo you want to uninstall $PATCHED_APP_APP_NAME from all users and proceed?\nWe cannot guarantee this will succeed..." 12 45
        if [ $? -eq 0 ]; then
            log "User accepted to uninstall the app from all users."
            notify info "Please Wait !!\nUninstalling $PATCHED_APP_APP_NAME from all users using Rish..."
            if uninstallAppRish true true "$STORAGE"; then
                log "Uninstallation from all users successful, proceeding with installation."
                notify info "Please Wait !!\nInstalling $PATCHED_APP_APP_NAME $PATCHED_APP_VERSION using Rish..."
                
                if bash system/rish-install.sh "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME" "$EXPORTED_APK_NAME" "$STORAGE" "$INSTALL_TYPE"; then
                    log "Installation command executed successfully after uninstallation from all users."
                    
                    # Read install type from file
                    if [ -f "$STORAGE/install_type.txt" ]; then
                        INSTALL_TYPE=$(cat "$STORAGE/install_type.txt")
                        log "Read install type from file: $INSTALL_TYPE"
                    fi
                    
                    # Run dex optimization with notifications
                    runDexOptimization "$PATCHED_APP_PKG_NAME" "$PATCHED_APP_APP_NAME $PATCHED_APP_VERSION" "$INSTALL_TYPE"
                    
                else
                    log "Installation failed after uninstallation from all users."
                    notify msg "Installation Failed !!\nShare logs to developer. \n\nCopied patched $PATCHED_APP_APP_NAME apk to Internal Storage..."
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
    
    # Clean up install type file
    rm -f "$STORAGE/install_type.txt"
    
    # If we reach this point, the installation was successful
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
