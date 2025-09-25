ManageKeystore() {
    while true; do
        keystore_dir="/data/data/com.termux/files/home/Enhancify/keystore"
        has_keystore="false"
        if [ -d "$keystore_dir" ] && [ -n "$(ls -A "$keystore_dir" 2>/dev/null)" ]; then
            has_keystore="true"
        fi

        menu_options=()
        menu_options+=("1" "Add Custom Keystore" "Import a new keystore file")

        if [ "$has_keystore" = "true" ]; then
            menu_options+=("2" "Delete Custom Keystore" "Remove all imported keystores")
        fi

        choice=$("${DIALOG[@]}" \
            --begin 2 0 \
            --title '| Custom Keystore Management |' \
            --item-help \
            --ok-label "Select" \
            --cancel-label "Back" \
            --menu "Choose an action to manage keystores" \
            $(( $(tput lines) - 3 )) -1 15 \
            "${menu_options[@]}" \
            2>&1 >/dev/tty)

        exitstatus=$?
        [ "$exitstatus" -eq 1 ] && return 1

        case "$choice" in
            1)
                addCustomKeystore
                ;;
            2)
                if [ "$has_keystore" = "true" ]; then
                        "${DIALOG[@]}" \
                        --title "| Confirm Deletion |" \
                        --yesno "Are you sure you want to delete all imported keystores?\n\nThis action cannot be undone." \
                        -1 -1 \
                        2>&1 >/dev/tty

                    exitstatus=$?
                    if [ "$exitstatus" -eq 0 ]; then
                        rm -rf "$keystore_dir"
                        notify msg "All keystores deleted successfully!" 2>&1 >/dev/tty
                    fi
                fi
                ;;
        esac
    done
}

addCustomKeystore() {
    keystore_dir="/data/data/com.termux/files/home/Enhancify/keystore"
    if [ -d "$keystore_dir" ] && [ -n "$(ls -A "$keystore_dir" 2>/dev/null)" ]; then
            "${DIALOG[@]}" \
            --title "| Warning: Keystore Already Present |" \
            --yesno "Another keystore is already present. Importing a new one will remove the old keystore.\n\nTake backup of keystore before procedding.\n\nDo you want to continue?" \
            -1 -1 \
            2>&1 >/dev/tty

        exitstatus=$?
        if [ "$exitstatus" -eq 1 ]; then

            return 1
        else
            rm -rf "$keystore_dir"
        fi
    fi

    internalStorage="$HOME/storage/shared"
    [ -d "$internalStorage" ] || internalStorage="$HOME"
    currentPath="$internalStorage"
    newPath=""
    selectedFile=""

    while [ ! -f "$selectedFile" ]; do
        currentPath=${currentPath:-$internalStorage}
        dirList=()
        files=()
        num=0

        while read -r itemName; do
            if [ -d "$currentPath/$itemName" ]; then
                files+=("$itemName")
                itemNameDisplay="$itemName"
                [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                    itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                dirList+=("$((++num))" "$itemNameDisplay/" "DIR: $itemName/")
            elif [[ "${itemName,,}" =~ \.(jks|p12|pfx|keystore)$ ]]; then
                files+=("$itemName")
                itemNameDisplay="$itemName"
                [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                    itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                dirList+=("$((++num))" "$itemNameDisplay" "KEYSTORE: $itemName")
            fi
        done < <(LC_ALL=C ls -1 --group-directories-first "$currentPath" 2>/dev/null)

        if [ ${#dirList[@]} -eq 0 ]; then
            dirList+=("1" "Directory Empty" "No files or subdirectories")
        fi

        pathIndex=$("${DIALOG[@]}" \
            --begin 2 0 \
            --title '| Import Keystore - Select File |' \
            --item-help \
            --ok-label "Select" \
            --cancel-label "Back" \
            --menu "Use arrow keys to navigate\nCurrent Path: $currentPath/" \
            $(( $(tput lines) - 3 )) -1 15 \
            "${dirList[@]}" \
            2>&1 >/dev/tty)

        exitstatus=$?
        [ "$exitstatus" -eq 1 ] && return 1

        if [[ "${dirList[$(($pathIndex*3-1))]}" == "Directory Empty" ]]; then
            continue
        fi

        selectedFile="${files[$pathIndex-1]}"
        selectedFile="$currentPath/$selectedFile"

        if [ -d "$selectedFile" ]; then
            currentPath="$selectedFile"
            selectedFile=""
        fi
    done

    credentials=$("${DIALOG[@]}" \
        --title "| Enter Keystore Credentials |" \
        --ok-label "Done" \
        --cancel-label "Cancel" \
        --form "Enter credentials for: $(basename "$selectedFile")" \
        15 60 0 \
        "Alias:" 1 1 "" 1 10 30 0 \
        "Keystore Password:" 2 1 "" 2 20 30 10 \
        "Private Key Password:" 3 1 "" 3 22 30 10 \
        2>&1 >/dev/tty)

    exitstatus=$?
    [ "$exitstatus" -eq 1 ] && return 1

    alias_name=$(echo "$credentials" | sed -n 1p)
    keystore_pass=$(echo "$credentials" | sed -n 2p)
    private_key_pass=$(echo "$credentials" | sed -n 3p)

    "${DIALOG[@]}" \
        --title "| Confirm Import |" \
        --yesno "Confirm to import this keystore?\n\nFile: $(basename "$selectedFile")\nAlias: $alias_name\nKeystore Password: $keystore_pass\nPrivate Key Password: $private_key_pass\n\nVerification Will Start" \
        -1 -1 \
        2>&1 >/dev/tty

    exitstatus=$?
    [ "$exitstatus" -eq 1 ] && return 1

    notify info "Verifying..." 2>&1 >/dev/tty
    sleep 1

    verification_output=$(keytool -list -v \
        -keystore "$selectedFile" \
        -storepass "$keystore_pass" \
        -alias "$alias_name" \
        -keypass "$private_key_pass" 2>&1)

    verification_exit_code=$?

    if [ $verification_exit_code -ne 0 ]; then
        notify msg "Verification failed\nCheck entered credentials" 2>&1 >/dev/tty
        return 1
    fi

    if echo "$verification_output" | grep -q "Alias name: $alias_name"; then
        notify info "Verification successful\nImporting..." 2>&1 >/dev/tty
        sleep 1
    else
        notify msg "Verification failed\nAlias not found in keystore" 2>&1 >/dev/tty
        return 1
    fi

    mkdir -p "$keystore_dir"

    cp "$selectedFile" "$keystore_dir/"
    filename=$(basename "$selectedFile")

    keystore_json="$keystore_dir/keystore.json"

    jq -n --arg filename "$filename" \
          --arg alias "$alias_name" \
          --arg keystore_pass "$keystore_pass" \
          --arg private_key_pass "$private_key_pass" \
          '{($filename): {"alias": $alias, "keystore_password": $keystore_pass, "private_key_password": $private_key_pass}}' > "$keystore_json"

    notify msg "Keystore imported successfully!" 2>&1 >/dev/tty

    return 0
}
