Fetch_MicroG() {
    STORAGE_PATH="$STORAGE"
    local microg_dir="$STORAGE/GmsCore"
    mkdir -p "$microg_dir"

    local GITHUB_TOKEN=$(get_github_token)
    local curl_opts=("${CURL[@]}")
    [ -n "$GITHUB_TOKEN" ] && curl_opts+=(--header "Authorization: token $GITHUB_TOKEN")

    local choice provider repo
    choice=$("${DIALOG[@]}" \
        --title '| Choose GmsCore Provider |' \
        --cancel-label Back \
        --ok-label Download \
        --menu 'Select GmsCore provider:' -1 -1 -1 \
        1 "Wst_Xda MicroG (Recommended)" \
        2 "Revanced " \
        3 "Rex " \
        3>&1 1>&2 2>&3
    ) || return 1

    case "$choice" in
        1) provider="Wst_Xda" repo="WSTxda/MicroG-RE" ;;
        2) provider="Revanced" repo="ReVanced/GmsCore" ;;
        3) provider="Rex" repo="YT-Advanced/GmsCore" ;;
        *) return 1 ;;
    esac

    local api_url="https://api.github.com/repos/$repo/releases/latest"
    local api_response
    api_response=$("${curl_opts[@]}" -s "$api_url") || {
        notify msg "Failed to fetch release info for $provider GmsCore"
        return 1
    }

    local tag_name=$(jq -r '.tag_name' <<< "$api_response")
    local asset_info
    asset_info=$(jq -r '.assets[] | select(.name | endswith(".apk")) | [.browser_download_url, .size, .name] | @tsv' <<< "$api_response" | head -n1)
    [ -z "$asset_info" ] && {
        notify msg "No APK assets found in $provider release"
        return 1
    }

    IFS=$'\t' read -r url size name <<< "$asset_info"

    local clean_tag=$(echo "$tag_name" | tr -cd '[:alnum:]._-')
    local filename="${provider}-${clean_tag}.apk"
    local output_file="$microg_dir/$filename"

    local gauge_text="Downloading $provider GmsCore\nFile: $filename\nSize: $(numfmt --to=iec --format="%0.1f" "$size")"

    local retry_count=3
    while ((retry_count-- > 0)); do

        if downloadFile "$url" "$output_file" "$size" "$gauge_text"; then
            if [ -f "$output_file" ]; then
                local actual_size=$(stat -c %s "$output_file" 2>/dev/null)
                if [ -n "$actual_size" ] && [ "$actual_size" -gt $((size * 9/10)) ]; then
                    notify msg "$provider GmsCore downloaded successfully!\nSaved at: $output_file"
                    return 0
                    tput civis

                fi
            fi
        fi

        rm -f "$output_file" 2>/dev/null
        [ $retry_count -gt 0 ] && notify info "Download failed, retrying... ($retry_count attempts left)"
    done

    notify msg "Failed to download $provider GmsCore after multiple attempts"
    return 1

}
tput civis
