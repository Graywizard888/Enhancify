bundleParser() {
    # ─── Step 1: Select Bundle JSON File ────────────────────────────────
    local internalStorage="$HOME/storage/shared"
    [ -d "$internalStorage" ] || internalStorage="$HOME"
    local currentPath="$internalStorage"
    local newPath=""
    local exitstatus=0

    while [ ! -f "$newPath" ]; do
        currentPath=${currentPath:-$internalStorage}
        local dirList=()
        local files=()
        local num=0

        while read -r itemName; do
            if [ -d "$currentPath/$itemName" ]; then
                files+=("$itemName")
                local itemNameDisplay="$itemName"
                [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                    itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                dirList+=("$((++num))" "$itemNameDisplay/" "DIR: $itemName/")
            elif [[ "${itemName,,}" =~ \.json$ ]]; then
                files+=("$itemName")
                local itemNameDisplay="$itemName"
                [ "${#itemName}" -gt $(("$(tput cols)" - 24)) ] &&
                    itemNameDisplay="${itemName:0:$(("$(tput cols)" - 34))}...${itemName: -10}"
                dirList+=("$((++num))" "$itemNameDisplay" "FILE: $itemName")
            fi
        done < <(LC_ALL=C ls -1 --group-directories-first "$currentPath" 2>/dev/null)

        if [ ${#dirList[@]} -eq 0 ]; then
            dirList+=("1" "Directory Empty" "No files or subdirectories")
        fi

        local pathIndex
        pathIndex=$("${DIALOG[@]}" \
            --begin 2 0 \
            --title '| Import Bundle - Select JSON File |' \
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
            newPath=""
        fi
    done

    [ "$exitstatus" -eq 1 ] && return 1

    local BUNDLE_FILE="$newPath"

    # ─── Step 2: Extract SOURCE from Filename ───────────────────────────
    local bundle_basename
    bundle_basename=$(basename "$BUNDLE_FILE" .json)

    local source_name="$bundle_basename"
    source_name="${source_name%-morphed-latest-patches-bundle}"
    source_name="${source_name%-morphed-stable-patches-bundle}"
    source_name="${source_name%-morphed-dev-patches-bundle}"
    source_name="${source_name%-latest-patches-bundle}"
    source_name="${source_name%-stable-patches-bundle}"
    source_name="${source_name%-dev-patches-bundle}"

    if [ -z "$source_name" ] || [ "$source_name" == "$bundle_basename" ]; then
        source_name="$bundle_basename"
    fi

    SOURCE="$source_name"

    # ─── Step 3: Process Bundle MetaData ────────────────────────────────
    notify info "Processing Bundle MetaData"

    local bundle_version bundle_description bundle_created_at bundle_download_url
    bundle_version=$(jq -r '.version // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_description=$(jq -r '.description // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_created_at=$(jq -r '.created_at // empty' "$BUNDLE_FILE" 2>/dev/null)
    bundle_download_url=$(jq -r '.download_url // empty' "$BUNDLE_FILE" 2>/dev/null)

    if [ -z "$bundle_version" ] || [ -z "$bundle_download_url" ]; then
        notify msg "Invalid bundle file!\nMissing required fields (version or download_url)."
        return 1
    fi

    bundle_description=$(printf '%b' "$bundle_description")

    # Sanitize description: convert [text](url) → text, remove standalone URLs, keep @mentions
    bundle_description=$(echo "$bundle_description" | \
        sed -E 's/\[([^]]*)\]\(https?:\/\/[^)]*\)/\1/g' | \
        sed -E 's/https?:\/\/[^[:space:]]*//g' | \
        sed -E 's/\( *\)//g' | \
        sed -E 's/  +/ /g')

    bundle_description=$(printf '%s' "$bundle_description" | cat -s)

    bundle_description=$(printf '%s' "$bundle_description" | \
        sed '/./,$!d' | \
        sed -e :a -e '/^\s*$/{ $d; N; ba; }')

   bundle_description=$(printf '%s' "$bundle_description" | \
        sed -E 's/^#{1,6}\s*//g' | \
        sed -E 's/\*{1,2}([^*]+)\*{1,2}/\1/g')

    # ─── Step 4: Display Bundle Details ─────────────────────────────────
    "${DIALOG[@]}" \
        --title '| Bundle Details |' \
        --yes-label "Download" \
        --no-label "Back" \
        --yesno "\nSource     : $SOURCE\n\nVersion    : $bundle_version\n\nCreated At : ${bundle_created_at:-N/A}\n\nDescription:\n${bundle_description:-N/A}\n" -1 -1

    [ $? -ne 0 ] && return 1

    # ─── Step 5: Determine Patches Extension ────────────────────────────
    local PATCHES_EXT
    case "$bundle_download_url" in
        *.mpp) PATCHES_EXT="mpp" ;;
        *.rvp) PATCHES_EXT="rvp" ;;
        *)     PATCHES_EXT="mpp" ;;
    esac

    # ─── Step 6: Setup GitHub Auth & API (mirrors assets.sh) ────────────
    rm -f "$HOME/Enhancify/github_api_log.json"

    unset CLI_VERSION CLI_URL CLI_SIZE PATCHES_VERSION PATCHES_URL PATCHES_SIZE JSON_URL
    for var in $(compgen -v | grep "^ASSET_"); do
        unset "$var"
    done

    local GITHUB_TOKEN AUTH_HEADER AUTH_TEXT
    GITHUB_TOKEN=$(read_github_token)
    AUTH_HEADER=""
    AUTH_TEXT=""

    if [ -n "$GITHUB_TOKEN" ]; then
        AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
        AUTH_TEXT="[Authorised]"
    fi

    local CURL_CMD=("${CURL[@]}" \
        --compressed \
        --retry 3 \
        --retry-delay 1 \
        -A "$USER_AGENT_GITHUB" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28")

    if [ -n "$AUTH_HEADER" ]; then
        CURL_CMD+=(-H "$AUTH_HEADER")
    fi

    CURL_CMD+=(-D headers.tmp)

    # ─── Step 7: Check Internet & Rate Limit ────────────────────────────
    internet || return 1

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        notify info "Initiating Network Acceleration ...\nFetching Bundle Assets for '$SOURCE'... $AUTH_TEXT"
    else
        notify info "Fetching Bundle Assets for '$SOURCE'... $AUTH_TEXT"
    fi

    "${CURL_CMD[@]}" "https://api.github.com/rate_limit" > response.tmp
    local response_headers=$(<headers.tmp)
    log_github_api_request "https://api.github.com/rate_limit" "$response_headers"
    local remaining
    remaining=$(jq -r '.resources.core.remaining' response.tmp 2>/dev/null)
    rm -f headers.tmp response.tmp

    if [ -z "$remaining" ] || [ "$remaining" -le 1 ]; then
        notify msg "Unable to proceed.\nYou are probably rate-limited at this moment.\nTry again later or use a GitHub token."
        return 1
    fi

    # ─── Step 8: Fetch Patches Info via API & Build .data ───────────────
    mkdir -p "assets/$SOURCE"
    rm -f "assets/$SOURCE/.data" "assets/.data" 2>/dev/null

    # Validate & convert GitHub browser URL to API URL
    # Input:  https://github.com/{owner}/{repo}/releases/download/{tag}/{filename}
    # Output: https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}
    if [[ "$bundle_download_url" != https://github.com/* ]]; then
        notify msg "Invalid download URL format.\nExpected GitHub release URL."
        return 1
    fi

    local url_path="${bundle_download_url#https://github.com/}"
    local repo_owner repo_name release_tag
    repo_owner=$(echo "$url_path" | cut -d'/' -f1)
    repo_name=$(echo "$url_path" | cut -d'/' -f2)
    release_tag=$(echo "$url_path" | cut -d'/' -f5)

    local PATCHES_API_URL="https://api.github.com/repos/$repo_owner/$repo_name/releases/tags/$release_tag"

    notify info "Fetching Patches Release Info for '$SOURCE'... $AUTH_TEXT"

    "${CURL_CMD[@]}" "$PATCHES_API_URL" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "$PATCHES_API_URL" "$response_headers"

    if ! jq -r --arg ext "$PATCHES_EXT" '
        if type == "array" then .[0] else . end |
        "PATCHES_VERSION='\''\(.tag_name)'\''",
        "PATCHES_EXT='\''" + $ext + "'\''",
        (
            .assets[] |
            select(
                (.name | endswith("." + $ext)) and
                (.name | endswith(".asc") | not)
            ) |
            "PATCHES_URL='\''\(.browser_download_url)'\''",
            "PATCHES_SIZE='\''\(.size|tostring)'\''"
        )
    ' response.tmp > "assets/$SOURCE/.data" 2>/dev/null; then
        rm -f headers.tmp response.tmp
        notify msg "Unable to fetch patches info from API!\nCheck the download URL and retry."
        return 1
    fi
    rm -f headers.tmp response.tmp

    source "assets/$SOURCE/.data"

    if [ -z "$PATCHES_URL" ] || [ -z "$PATCHES_SIZE" ] || [ "$PATCHES_SIZE" == "0" ]; then
        notify msg "Unable to determine patches file size.\nCheck the download URL and retry."
        return 1
    fi

    # ─── Step 9: Download Patches File (mirrors assets.sh) ──────────────
    PATCHES_FILE="assets/$SOURCE/Patches-$PATCHES_VERSION.$PATCHES_EXT"
    [ -e "$PATCHES_FILE" ] || rm -f assets/"$SOURCE"/Patches-* 2>/dev/null

    local CTR=3
    while [ "$PATCHES_SIZE" != "$(stat -c %s "$PATCHES_FILE" 2>/dev/null)" ]; do
        [ $CTR -eq 0 ] && notify msg "Oops! Unable to download patches completely.\n\nRetry or change your Network." && return 1
        ((CTR--))

        local patches_text="Source  : $SOURCE\n"
        patches_text+="File    : Patches-${PATCHES_VERSION}.${PATCHES_EXT}\n"
        patches_text+="Size    : $(numfmt --to=iec --format='%0.1f' "$PATCHES_SIZE")\n"
        patches_text+="\nDownloading..."

        downloadFile "$PATCHES_URL" "$PATCHES_FILE" "$PATCHES_SIZE" "$patches_text"
        tput civis
    done

    # ─── Step 10: Fetch CLI Info from GitHub API ────────────────────────
    local CLI_API_URL
    if [ "$PATCHES_EXT" == "mpp" ]; then
        CLI_API_URL="https://api.github.com/repos/MorpheApp/morphe-cli/releases/latest"
    else
        CLI_API_URL="https://api.github.com/repos/inotia00/revanced-cli/releases/latest"
    fi

    notify info "Fetching CLI Info... $AUTH_TEXT"

    "${CURL_CMD[@]}" "$CLI_API_URL" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "$CLI_API_URL" "$response_headers"

    if ! jq -r '
        if type == "array" then .[0] else . end |
        "CLI_VERSION='\''\(.tag_name)'\''",
        (
            .assets[] |
            if (.name | endswith(".jar")) then
                "CLI_URL='\''\(.browser_download_url)'\''",
                "CLI_SIZE='\''\(.size|tostring)'\''"
            else
                empty
            end
        )
    ' response.tmp > assets/.data 2>/dev/null; then
        rm -f headers.tmp response.tmp
        notify msg "Unable to fetch CLI info from API!\nRetry later."
        return 1
    fi
    rm -f headers.tmp response.tmp

    source "assets/.data"

    if [ -z "$CLI_VERSION" ] || [ -z "$CLI_URL" ] || [ -z "$CLI_SIZE" ]; then
        notify msg "Failed to parse CLI release info!\nRetry later."
        return 1
    fi

    # ─── Step 11: Download CLI (mirrors assets.sh) ──────────────────────
    CLI_FILE="assets/CLI-$CLI_VERSION.jar"
    [ -e "$CLI_FILE" ] || rm -f assets/CLI-* 2>/dev/null

    CTR=3
    while [ "$CLI_SIZE" != "$(stat -c %s "$CLI_FILE" 2>/dev/null)" ]; do
        [ $CTR -eq 0 ] && notify msg "Oops! Unable to download CLI completely.\n\nRetry or change your Network." && return 1
        ((CTR--))

        local cli_text="File    : CLI-$CLI_VERSION.jar\n"
        cli_text+="Size    : $(numfmt --to=iec --format='%0.1f' "$CLI_SIZE")\n"
        cli_text+="\nDownloading..."

        downloadFile "$CLI_URL" "$CLI_FILE" "$CLI_SIZE" "$cli_text"
        tput civis
    done

    # ─── Step 12: Parse Patches JSON ────────────────────────────────────
    parsePatchesJson || return 1

    # ─── Step 13: Start Patching Workflow ───────────────────────────────
    TASK="CHOOSE_APP"
    while true; do
        case "$TASK" in
            "CHOOSE_APP")
                chooseApp || break
                ;;
            "DOWNLOAD_APP")
                downloadApp || continue
                TASK="MANAGE_PATCHES"
                ;;
            "IMPORT_APP")
                importApp || continue
                TASK="MANAGE_PATCHES"
                ;;
            "MANAGE_PATCHES")
                managePatches || continue
                TASK="EDIT_OPTIONS"
                ;;
            "EDIT_OPTIONS")
                editOptions || continue
                TASK="PATCH_APP"
                ;;
            "PATCH_APP")
                patchApp || break
                TASK="INSTALL_APP"
                ;;
            "INSTALL_APP")
                installApp
                break
                ;;
        esac
    done
}
