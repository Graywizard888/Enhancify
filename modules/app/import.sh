#!/usr/bin/bash

selectFile() {
    internalStorage="$HOME/storage/shared"
    [ -d "$internalStorage" ] || internalStorage="$HOME"
    currentPath="$internalStorage"
    newPath=""
    while [ ! -f "$newPath" ]; do
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
            elif [[ "${itemName,,}" =~ \.(apk|apkm|xapk)$ ]]; then
                files+=("$itemName")
                itemNameDisplay="$itemName"
                [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                    itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                dirList+=("$((++num))" "$itemNameDisplay" "FILE: $itemName")
            fi
        done < <(LC_ALL=C ls -1 --group-directories-first "$currentPath" 2>/dev/null)

        if [ ${#dirList[@]} -eq 0 ]; then
            dirList+=("1" "Directory Empty" "No files or subdirectories")
        fi

        pathIndex=$("${DIALOG[@]}" \
            --begin 2 0 \
            --title '| Import App - Select File |' \
            --item-help \
            --ok-label "Select" \
            --cancel-label "Back" \
            --menu "Use arrow keys to navigate\nCurrent Path: $currentPath/" \
            $(( $(tput lines) - 3 )) -1 15 \
            "${dirList[@]}" \
            2>&1 >/dev/tty)

        exitstatus=$?
        [ "$exitstatus" -eq 1 ] && break

        if [[ "${dirList[$(($pathIndex*3-1))]}" == "Directory Empty" ]]; then
            continue
        fi

        newPath="${files[$pathIndex-1]}"
        newPath="$currentPath/$newPath"

        if [ -d "$newPath" ]; then
            currentPath="$newPath"
        fi
    done

    [ "$exitstatus" -eq 1 ] && {
        TASK="CHOOSE_APP"
        return 1
    }

    SELECTED_FILE="$newPath"
    return 0
}

extractMeta() {
    local APP_INFO
    FILE_PATH="$SELECTED_FILE"
    if [[ "${FILE_PATH,,}" == *.apk ]]; then
        notify info "Please Wait !!\nExtracting data from \"$(basename "$FILE_PATH")\""
        if ! APP_INFO=$(./bin/aapt2 dump badging "$FILE_PATH" 2>/dev/null); then
            notify msg "The APK you selected is not valid. Download again and retry."
            return 1
        fi
        APP_EXT="apk"
        PKG_NAME=$(grep -oP "(?<=package: name=')[^']+" <<< "$APP_INFO")
        APP_NAME=$(grep -oP "(?<=application-label:')[^']+" <<< "$APP_INFO" | sed -E 's/[.: ]+/-/g')
        SELECTED_VERSION=$(grep -oP "(?<=versionName=')[^']+" <<< "$APP_INFO")
    else
        local ext="${FILE_PATH##*.}"
        if [[ "${ext,,}" == "apkm" ]]; then
            if ! APP_INFO=$(unzip -qqp "$FILE_PATH" info.json 2>/dev/null); then
                notify msg "The Bundle you selected is not valid. Download again and retry."
                return 1
            fi
            if jq -e --arg ARCH "$ARCH" '.arches | index($ARCH) == null' <<< "$APP_INFO" &>/dev/null; then
                notify msg "The selected Apk Bundle doesn't contain $ARCH lib.\nChoose another file."
                return 1
            fi
            APP_EXT="apkm"
            source <(jq -rc '
                "APP_NAME=\(.app_name)
                PKG_NAME=\(.pname)
                SELECTED_VERSION=\(.release_version)"
            ' <<< "$APP_INFO")
        elif [[ "${ext,,}" == "xapk" ]]; then
            mkdir -p "tmp" &>/dev/null
            unzip -qqp "$FILE_PATH" manifest.json > "tmp/manifest.json" 2>/dev/null
            if [ $? -ne 0 ]; then
                notify msg "The XAPK Bundle you selected is not valid. Download again and retry."
                return 1
            fi
            
            APP_INFO=$(<"tmp/manifest.json")
            device_arch="${ARCH//-/_}"
            if ! jq -e --arg arch "config.$device_arch" '.split_configs | index($arch) != null' <<< "$APP_INFO" &>/dev/null; then
                rm "tmp/manifest.json"
                notify msg "The selected XAPK Bundle doesn't contain $ARCH lib.\nChoose another file."
                return 1
            fi
            
            APP_EXT="xapk"
            source <(jq -rc '
                "PKG_NAME=\(.package_name)
                APP_NAME=\(.name)
                SELECTED_VERSION=\(.version_name)"
            ' <<< "$APP_INFO")
            rm "tmp/manifest.json"
        else
            notify msg "Unsupported file format: $ext"
            return 1
        fi
    fi
}

importApp() {
    unset PKG_NAME APP_NAME APP_VER
    local SELECTED_FILE FILE_PATH APP_EXT SELECTED_VERSION
    selectFile || return 1
    extractMeta || return 1
    APP_VER="${SELECTED_VERSION// /-}"
    getInstalledVersion

    if [ "$ALLOW_APP_VERSION_DOWNGRADE" == "off" ] &&
        jq -e '.[0] > .[1]' <<< "[\"${INSTALLED_VERSION:-0}\", \"$SELECTED_VERSION\"]" &>/dev/null; then
        notify msg "Selected version $SELECTED_VERSION is lower than installed version $INSTALLED_VERSION.\nPlease select a higher version!"
        return 1
    fi

    if ! "${DIALOG[@]}" \
        --title '| App Details |' \
        --yes-label 'Import App' \
        --no-label 'Back' \
        --yesno "The following data is extracted from the file you provided.\nApp Name    : $APP_NAME\nPackage Name: $PKG_NAME\nVersion     : $SELECTED_VERSION\nDo you want to proceed with this app?" -1 -1; then
        return 1
    fi

    mkdir -p "apps/$APP_NAME" &>/dev/null
    rm -rf apps/"$APP_NAME"/* &>/dev/null
    local targetPath="apps/$APP_NAME/$APP_VER.$APP_EXT"
    cp "$FILE_PATH" "$targetPath"

    if [[ "$APP_EXT" == "apkm" ]]; then
        antisplit_apkm || return 1
    elif [[ "$APP_EXT" == "xapk" ]]; then
        antisplit_xapk || return 1
    elif [[ "$APP_EXT" == "apk" ]] && [[ "$OPTIMIZE_LIBS" == on ]]; then
        Optimize_Libs || return 1


    fi

    findPatchedApp || return 1
}


