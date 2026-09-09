#!/usr/bin/bash

Fetch_Dependency() {
    while true; do
        local choice
        choice=$("${DIALOG[@]}" \
            --title '| Fetch Dependency |' \
            --cancel-label Back \
            --ok-label Select \
            --menu 'Select a dependency to fetch:' -1 -1 -1 \
            1 "Fetch GmsCore" \
            2 "Fetch PotHelper" \
            3>&1 1>&2 2>&3
        ) || return 1
        case "$choice" in
            1)
                Fetch_MicroG || continue
                ;;
            2)
                Fetch_PotHelper || continue
                ;;
            *) return 1 ;;
        esac
    done
}

showPotHelperChangelog() {
    local version="$1"
    local size="$2"
    local api_response="$3"

    local changelog_tmp="$HOME/Enhancify/pothelper_changelog.tmp"
    local changelog_display="$HOME/Enhancify/pothelper_changelog_display.tmp"

    jq -r 'if type == "array" then .[0] else . end | .body // empty' <<< "$api_response" > "$changelog_tmp" 2>/dev/null

    [ ! -f "$changelog_tmp" ] && return 0
    [ ! -s "$changelog_tmp" ] && rm -f "$changelog_tmp" && return 0

    local term_cols
    if command -v tput &>/dev/null; then
        term_cols=$(tput cols 2>/dev/null)
    fi
    if [ -z "$term_cols" ] || [ "$term_cols" -eq 0 ] 2>/dev/null; then
        if [ -n "$COLUMNS" ]; then
            term_cols="$COLUMNS"
        else
            term_cols=$(stty size 2>/dev/null | awk '{print $2}')
        fi
    fi
    [ -z "$term_cols" ] || [ "$term_cols" -eq 0 ] 2>/dev/null && term_cols=70

    local wrap_width=$((term_cols - 8))
    [ "$wrap_width" -lt 25 ] && wrap_width=25

    local size_display=""
    if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
        size_display=$(numfmt --to=iec --format='%0.1f' "$size")
    fi

    {
        echo " Provider : PotHelper"
        echo " Version  : $version"
        if [ -n "$size_display" ]; then
            echo " Size     : $size_display"
        fi
        echo " Type     : PotHelper APK"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    } > "$changelog_display"

    sed -E '
        s/\r//g
        /^\*\*Full Changelog\*\*/d
        /^Full Changelog/d
        /^##? ?\[?[0-9]+\.[0-9]+/d
        s/\[([^]]*)\]\([^)]*\)/\1/g
        s/\*\*([^*]*)\*\*/\1/g
        s/\*([^*]+)\*/\1/g
        s/`([^`]*)`/\1/g
        s/\([a-f0-9]{7,}\)//g
        s/\(#[0-9]+\)//g
        s/\(\s*\)//g
        s|https?://[^ ]*||g
        s/@[a-zA-Z0-9_.-]+//g
        s/<[^>]*>//g
        s/^\* /  • /
        s/^- /  • /
        s/[[:space:]]+$//
    ' "$changelog_tmp" | \
    awk '
        /^### / {
            sub(/^### /, "")
            print ""
            print "━━ " $0 " ━━"
            print ""
            next
        }
        { print }
    ' | \
    cat -s | \
    awk -v width="$wrap_width" '
    {
        line = $0

        if (line == "") {
            print ""
            next
        }

        if (line ~ /^━━/) {
            print line
            next
        }

        if (line ~ /^  • /) {
            prefix = "  • "
            indent = "    "
            text = substr(line, 5)
        } else {
            prefix = ""
            indent = ""
            text = line
        }

        max_first = width - length(prefix)
        if (max_first < 10) max_first = 10
        max_cont = width - length(indent)
        if (max_cont < 10) max_cont = 10

        remaining = text
        first = 1

        while (length(remaining) > 0) {
            if (first) {
                max = max_first
            } else {
                max = max_cont
            }

            if (length(remaining) <= max) {
                if (first) {
                    print prefix remaining
                } else {
                    print indent remaining
                }
                break
            }

            cut = 0
            for (i = max; i > 0; i--) {
                if (substr(remaining, i, 1) == " ") {
                    cut = i
                    break
                }
            }

            if (cut == 0) cut = max

            chunk = substr(remaining, 1, cut)
            remaining = substr(remaining, cut + 1)

            sub(/^ /, "", remaining)

            if (first) {
                print prefix chunk
                first = 0
            } else {
                print indent chunk
            }
        }
    }
    ' >> "$changelog_display"

    "${DIALOG[@]}" \
        --title "| PotHelper — Changelog |" \
        --exit-label "Download" \
        --textbox "$changelog_display" -1 -1

    local dialog_exit=$?
    rm -f "$changelog_tmp" "$changelog_display"

    return $dialog_exit
}

Fetch_PotHelper() {
    local pot_dir="$STORAGE/Dependencies"
    local GITHUB_TOKEN
    GITHUB_TOKEN=$(read_github_token)
    local AUTH_HEADER=""
    local AUTH_TEXT=""

    if [ -n "$GITHUB_TOKEN" ]; then
        AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
        AUTH_TEXT="[Authorised]"
    fi

    local curl_opts=("${CURL[@]}" \
        --compressed \
        --retry 3 \
        --retry-delay 1 \
        -A "$USER_AGENT_GITHUB" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28")

    if [ -n "$AUTH_HEADER" ]; then
        curl_opts+=(-H "$AUTH_HEADER")
    fi

    curl_opts+=(-D headers.tmp)

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        notify info "Initiating Network Acceleration ...\nFetching PotHelper Info... $AUTH_TEXT"
    else
        notify info "Fetching PotHelper Info.. $AUTH_TEXT"
    fi
    sleep 1

    "${curl_opts[@]}" "https://api.github.com/rate_limit" > response.tmp
    local response_headers=$(<headers.tmp)
    log_github_api_request "https://api.github.com/rate_limit" "$response_headers"
    local remaining
    remaining=$(jq -r '.resources.core.remaining' response.tmp)
    rm -f headers.tmp response.tmp

    if [ "$remaining" -lt 2 ]; then
        notify msg "Unable to fetch PotHelper\nYou are probably rate limited!!\n\nTry again later."
        return 1
    fi

    local repo="MorpheApp/PotHelper"
    local api_url="https://api.github.com/repos/$repo/releases"

    "${curl_opts[@]}" "$api_url" > response.tmp
    response_headers=$(<headers.tmp)
    log_github_api_request "$api_url" "$response_headers"

    local api_response
    if ! api_response=$(<response.tmp); then
        rm -f headers.tmp response.tmp
        notify msg "Failed to fetch release info for PotHelper"
        return 1
    fi
    rm -f headers.tmp response.tmp

    local tag_name
    tag_name=$(jq -r 'if type == "array" then .[0] else . end | .tag_name // empty' <<< "$api_response")

    [ -z "$tag_name" ] && {
        notify msg "Failed to parse release info for PotHelper\nRetry later."
        return 1
    }

    local asset_info
    asset_info=$(jq -r '
        if type == "array" then .[0] else . end
        | .assets[]?
        | select(.name | endswith(".apk"))
        | [.browser_download_url, .size, .name]
        | @tsv
    ' <<< "$api_response" | head -n1)

    [ -z "$asset_info" ] && {
        notify msg "No APK assets found in PotHelper release"
        return 1
    }

    local url size name
    IFS=$'\t' read -r url size name <<< "$asset_info"

    if [ -z "$size" ] || [ "$size" -le 0 ] 2>/dev/null; then
        notify msg "Invalid file size from API for PotHelper"
        return 1
    fi

    local clean_tag
    clean_tag=$(echo "$tag_name" | tr -cd '[:alnum:]._-')
    local filename="$name"
    local output_file="$pot_dir/$filename"

    if [ -f "$output_file" ]; then
        local existing_size
        existing_size=$(stat -c %s "$output_file" 2>/dev/null)
        if [ "$existing_size" == "$size" ]; then
            notify msg "PotHelper $clean_tag already downloaded!\nSize: $(numfmt --to=iec --format='%0.1f' "$size")\n\nOpening..."
            termux-open --view "$output_file"
            tput civis
            return 0
        fi
    fi

    showPotHelperChangelog "$clean_tag" "$size" "$api_response"

    mkdir -p "$pot_dir"

    rm -f "$pot_dir/pot-helper-"*.apk 2>/dev/null

    local -a dl_urls=("$url")
    local -a dl_dirs=("$pot_dir")
    local -a dl_files=("$filename")
    local -a dl_sizes=("$size")
    local -a dl_labels=("PotHelper $clean_tag")

    if [ "$DISABLE_NETWORK_ACCELERATION" != "on" ]; then
        downloadBatchAria2c dl_urls dl_dirs dl_files dl_sizes dl_labels || return 1
    else
        downloadSequentialWget dl_urls dl_dirs dl_files dl_sizes dl_labels || return 1
    fi

    local actual_size
    actual_size=$(stat -c %s "$output_file" 2>/dev/null)

    if [ -z "$actual_size" ]; then
        notify msg "Download failed!\nPotHelper file not found after download."
        return 1
    fi

    if [ "$actual_size" != "$size" ]; then
        rm -f "$output_file" 2>/dev/null
        notify msg "Download incomplete!\nExpected: $(numfmt --to=iec --format='%0.1f' "$size")\nGot: $(numfmt --to=iec --format='%0.1f' "$actual_size")\n\nRetry or change your Network."
        return 1
    fi

    notify msg "PotHelper downloaded successfully!\nVersion: $clean_tag\nSize: $(numfmt --to=iec --format='%0.1f' "$actual_size")\nSaved at: Internal Storage/Enhancify/Dependencies/$filename"
    termux-open --view "$output_file"
    tput civis
    return 0
}
