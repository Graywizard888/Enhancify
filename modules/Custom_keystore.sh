ManageKeystore() {
    while true; do
        keystore_dir="/data/data/com.termux/files/home/Enhancify/keystore"
        has_keystore="false"
        if [ -d "$keystore_dir" ] && [ -n "$(ls -A "$keystore_dir" 2>/dev/null)" ]; then
            has_keystore="true"
        fi

        menu_options=()
        menu_options+=("1" "Generate Keystore" "Create a new signing keystore")
        menu_options+=("2" "Add Custom Keystore" "Import a new keystore file")

        if [ "$has_keystore" = "true" ]; then
            menu_options+=("3" "Delete Custom Keystore" "Remove all imported keystores")
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
                createKeystore
                ;;
            2)
                addCustomKeystore
                ;;
            3)
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

createKeystore() {
    keystore_dir="/data/data/com.termux/files/home/Enhancify/keystore"

    if [ -d "$keystore_dir" ] && [ -n "$(ls -A "$keystore_dir" 2>/dev/null)" ]; then
        "${DIALOG[@]}" \
            --title "| Warning: Keystore Already Present |" \
            --yesno "Another keystore is already present. Generating a new one will remove the old keystore.\n\nTake backup of keystore before proceeding.\n\nDo you want to continue?" \
            -1 -1 \
            2>&1 >/dev/tty

        exitstatus=$?
        if [ "$exitstatus" -eq 1 ]; then
            return 1
        else
            rm -rf "$keystore_dir"
        fi
    fi

    keystore_type=$("${DIALOG[@]}" \
        --begin 2 0 \
        --title '| Generation Window |' \
        --ok-label "Generate" \
        --cancel-label "Back" \
        --menu "Select Keystore Type" \
        $(( $(tput lines) - 3 )) -1 15 \
        "1" "PKCS12 (Recommended)" \
        "2" "JKS" \
        2>&1 >/dev/tty)

    exitstatus=$?
    [ "$exitstatus" -eq 1 ] && return 1

    case "$keystore_type" in
        1) store_type="PKCS12"; extension="p12" ;;
        2) store_type="JKS"; extension="jks" ;;
    esac

    tput cnorm 2>/dev/null

    credentials=$("${DIALOG[@]}" \
        --title "| Enter Keystore Details |" \
        --ok-label "Next" \
        --cancel-label "Back" \
        --form "Enter details for new $store_type keystore\n(Fields marked with * are required)" \
        22 70 11 \
        "* Keystore Name:" 1 1 "" 1 20 30 50 \
        "* Alias:" 2 1 "" 2 20 30 50 \
        "* Keystore Pass (4+):" 3 1 "" 3 22 30 50 \
        "* Key Pass (4+):" 4 1 "" 4 22 30 50 \
        "Validity (days):" 5 1 "10000" 5 20 30 10 \
        "Common Name (CN):" 6 1 "" 6 20 30 50 \
        "Org Unit (OU):" 7 1 "" 7 20 30 50 \
        "Organization (O):" 8 1 "" 8 20 30 50 \
        "City (L):" 9 1 "" 9 20 30 50 \
        "State (ST):" 10 1 "" 10 20 30 50 \
        "Country Code (C):" 11 1 "US" 11 20 30 2 \
        2>&1 >/dev/tty)

    exitstatus=$?
    [ "$exitstatus" -eq 1 ] && return 1

    keystore_name=$(echo "$credentials" | sed -n 1p)
    alias_name=$(echo "$credentials" | sed -n 2p)
    keystore_pass=$(echo "$credentials" | sed -n 3p)
    private_key_pass=$(echo "$credentials" | sed -n 4p)
    validity=$(echo "$credentials" | sed -n 5p)
    cn=$(echo "$credentials" | sed -n 6p)
    ou=$(echo "$credentials" | sed -n 7p)
    org=$(echo "$credentials" | sed -n 8p)
    city=$(echo "$credentials" | sed -n 9p)
    state=$(echo "$credentials" | sed -n 10p)
    country=$(echo "$credentials" | sed -n 11p)

    tput civis 2>/dev/null

    if [ -z "$keystore_name" ] || [ -z "$alias_name" ] || [ -z "$keystore_pass" ] || [ -z "$private_key_pass" ]; then
        notify msg "Required fields cannot be empty!\n\nKeystore Name, Alias, Passwords are required." 2>&1 >/dev/tty
        return 1
    fi

    if [ ${#keystore_pass} -lt 4 ]; then
        notify msg "Keystore password must be at least 4 characters!" 2>&1 >/dev/tty
        return 1
    fi

    if [ ${#private_key_pass} -lt 6 ]; then
        notify msg "Private key password must be at least 6 characters!" 2>&1 >/dev/tty
        return 1
    fi

    if [[ ! "$keystore_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        notify msg "Keystore name can only contain letters, numbers, underscores, and hyphens!" 2>&1 >/dev/tty
        return 1
    fi

    validity=${validity:-10000}
    cn=${cn:-Unknown}
    ou=${ou:-Unknown}
    org=${org:-Unknown}
    city=${city:-Unknown}
    state=${state:-Unknown}
    country=${country:-US}

    dname="CN=$cn, OU=$ou, O=$org, L=$city, ST=$state, C=$country"

    "${DIALOG[@]}" \
        --title "| Confirm Generation |" \
        --yesno "Generate keystore with these configurations ?\n\nKeystore: ${keystore_name}.${extension}\nType: $store_type\nAlias: $alias_name\nKeystore Password: $keystore_pass\nKey Password: $private_key_pass\nValidity: $validity days\n\nDN: $dname" \
        -1 -1 \
        2>&1 >/dev/tty

    exitstatus=$?
    [ "$exitstatus" -eq 1 ] && return 1

    notify info "Generating keystore..." 2>&1 >/dev/tty

    mkdir -p "$keystore_dir"

    keystore_file="$keystore_dir/${keystore_name}.${extension}"

    creation_output=$(keytool -genkeypair -v \
        -keystore "$keystore_file" \
        -storetype "$store_type" \
        -alias "$alias_name" \
        -keyalg RSA \
        -keysize 2048 \
        -validity "$validity" \
        -storepass "$keystore_pass" \
        -keypass "$private_key_pass" \
        -dname "$dname" 2>&1)

    creation_exit_code=$?

    if [ $creation_exit_code -ne 0 ]; then
        rm -rf "$keystore_dir"
        notify msg "Keystore generation failed!\n\n$creation_output" 2>&1 >/dev/tty
        return 1
    fi

    keystore_json="$keystore_dir/keystore.json"
    filename="${keystore_name}.${extension}"

    jq -n --arg filename "$filename" \
          --arg alias "$alias_name" \
          --arg keystore_pass "$keystore_pass" \
          --arg private_key_pass "$private_key_pass" \
          '{($filename): {"alias": $alias, "keystore_password": $keystore_pass, "private_key_password": $private_key_pass}}' > "$keystore_json"

    notify msg "Keystore generated and imported successfully!\n\nFile: ${keystore_name}.${extension}" 2>&1 >/dev/tty

    return 0
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

    tput cnorm 2>/dev/null

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

    tput civis 2>/dev/null

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
