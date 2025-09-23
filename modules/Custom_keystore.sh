selectKeystore() {
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
        --yesno "Confirm to import this keystore?\n\nFile: $(basename "$selectedFile")\nAlias: $alias_name" \
        10 60 \
        2>&1 >/dev/tty

    exitstatus=$?
    [ "$exitstatus" -eq 1 ] && return 1

    keystore_dir="/data/data/com.termux/files/home/Enhancify/keystore"
    mkdir -p "$keystore_dir"

    cp "$selectedFile" "$keystore_dir/"
    filename=$(basename "$selectedFile")

    keystore_json="$keystore_dir/keystore.json"

    if [ -f "$keystore_json" ]; then

        jq --arg filename "$filename" \
           --arg alias "$alias_name" \
           --arg keystore_pass "$keystore_pass" \
           --arg private_key_pass "$private_key_pass" \
           '. + {($filename): {"alias": $alias, "keystore_password": $keystore_pass, "private_key_password": $private_key_pass}}' \
           "$keystore_json" > "${keystore_json}.tmp" && mv "${keystore_json}.tmp" "$keystore_json"
    else

        jq -n --arg filename "$filename" \
              --arg alias "$alias_name" \
              --arg keystore_pass "$keystore_pass" \
              --arg private_key_pass "$private_key_pass" \
              '{($filename): {"alias": $alias, "keystore_password": $keystore_pass, "private_key_password": $private_key_pass}}' > "$keystore_json"
    fi

        notify msg "Keystore imported successfully!" \
        2>&1 >/dev/tty

    return 0
}
