custom_source_management() {
    while true; do
        local SOURCE_CHOICE
        SOURCE_CHOICE=$("${DIALOG[@]}" \
            --title '| Custom Source Management |' \
            --no-cancel \
            --ok-label 'Select' \
            --menu "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
            "Add Source" "Add new custom source" \
            "Edit Sources" "Modify existing custom sources" \
            "Delete Sources" "Remove existing sources" \
            "Description" "How to add sources" \
            "Back" "Return to main menu" \
            2>&1 > /dev/tty)

        case $SOURCE_CHOICE in
            "Add Source")
                add_custom_source
                ;;
            "Edit Sources")
                edit_custom_sources
                ;;
            "Delete Sources")
                delete_custom_sources
                ;;
            "Description")
                show_source_help
                ;;
            "Back")
                break
                ;;
        esac
    done
}

add_custom_source() {
    local SOURCE_NAME REPO_NAME JSON_URL VERSION

    while true; do
        SOURCE_NAME=$("${DIALOG[@]}" --title "Source Name" --inputbox "Enter source name (required):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return
        [ -z "$SOURCE_NAME" ] && notify msg "Source name cannot be empty!" && continue

        REPO_NAME=$("${DIALOG[@]}" --title "Repository" --inputbox "Enter repository (username/repo) (required):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return
        if [ -z "$REPO_NAME" ]; then
            notify msg "Repository cannot be empty!"
            continue
        fi
        if [[ ! "$REPO_NAME" =~ ^[^/]+/[^/]+$ ]]; then
            notify msg "Invalid repository format! Must be: username/repo"
            continue
        fi

        JSON_URL=$("${DIALOG[@]}" --title "JSON URL (Optional)" --inputbox "Enter JSON URL (leave blank for null):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return

        VERSION=$("${DIALOG[@]}" --title "Version (Optional)" --inputbox "Enter version (leave blank for null):" -1 -1 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return

        break
    done

    [ -z "$JSON_URL" ] && JSON_URL="null"
    [ -z "$VERSION" ] && VERSION="null"

    jq --arg source "$SOURCE_NAME" \
       --arg repo "$REPO_NAME" \
       --arg json "$JSON_URL" \
       --arg version "$VERSION" \
       '. += [{
            "source": $source,
            "repository": $repo,
            "api": {
                "json": (if $json == "null" then null else $json end),
                "version": (if $version == "null" then null else $version end)
            }
        }]' sources.json > temp.json && mv temp.json sources.json

    notify msg "Custom source added successfully!"
}

edit_custom_sources() {
    local predefined_sources=("ReVanced" "ReVanced-Extended" "Anddea" "RVX-Android-6-7" "ReVancedExperiments")
    local sources=() source_choices=()
    
    local source_count=$(jq length sources.json)
    for ((i=0; i<source_count; i++)); do
        local source_name=$(jq -r ".[$i].source" sources.json)
        if ! [[ " ${predefined_sources[*]} " =~ " $source_name " ]]; then
            sources+=("$source_name")
            source_choices+=("$source_name" "")
        fi
    done

    if [ ${#sources[@]} -eq 0 ]; then
        notify msg "No custom sources found!"
        return
    fi

    local selected_source
    selected_source=$("${DIALOG[@]}" \
        --title '| Edit Custom Sources |' \
        --cancel-label 'Back' \
        --ok-label 'Edit' \
        --menu "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
        "${source_choices[@]}" \
        2>&1 > /dev/tty)
    [ -z "$selected_source" ] && return

    local index=$(jq -r --arg source "$selected_source" 'map(.source) | index($source)' sources.json)
    local current_name="$selected_source"
    local current_repo=$(jq -r ".[$index].repository" sources.json)
    local current_json=$(jq -r ".[$index].api.json" sources.json)
    local current_version=$(jq -r ".[$index].api.version" sources.json)

    [ "$current_json" = "null" ] && current_json=""
    [ "$current_version" = "null" ] && current_version=""

    local new_name
    while true; do
        new_name=$("${DIALOG[@]}" --title "Source Name" --inputbox "Edit source name:" -1 -1 "$current_name" 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return
        [ -z "$new_name" ] && notify msg "Source name cannot be empty!" && continue
        break
    done

    local new_repo
    while true; do
        new_repo=$("${DIALOG[@]}" --title "Repository" --inputbox "Edit repository (username/repo):" -1 -1 "$current_repo" 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return
        
        if [[ -z "$new_repo" ]]; then
            notify msg "Repository cannot be empty!"
            continue
        fi
        
        if [[ ! "$new_repo" =~ ^[^/]+/[^/]+$ ]]; then
            notify msg "Invalid format! Must be: username/repo"
            continue
        fi
        break
    done

    local new_json new_version
    new_json=$("${DIALOG[@]}" --title "JSON URL (Optional)" --inputbox "Edit JSON URL:" -1 -1 "$current_json" 2>&1 >/dev/tty)
    [ $? -ne 0 ] && return
    [ -z "$new_json" ] && new_json="null"

    new_version=$("${DIALOG[@]}" --title "Version (Optional)" --inputbox "Edit version:" -1 -1 "$current_version" 2>&1 >/dev/tty)
    [ $? -ne 0 ] && return
    [ -z "$new_version" ] && new_version="null"

    jq --arg idx "$index" \
       --arg name "$new_name" \
       --arg repo "$new_repo" \
       --arg json "$new_json" \
       --arg version "$new_version" \
    '.[$idx | tonumber] |= 
        (.source = $name |
         .repository = $repo |
         .api.json = (if $json == "null" then null else $json end) |
         .api.version = (if $version == "null" then null else $version end))' \
    sources.json > tmp.json && mv tmp.json sources.json

    notify msg "Source updated successfully!"
}

delete_custom_sources() {
    local predefined_sources=("ReVanced" "ReVanced-Extended" "Anddea" "RVX-Android-6-7" "ReVancedExperiments")
    local sources=() source_choices=()
    
    local source_count=$(jq length sources.json)
    for ((i=0; i<source_count; i++)); do
        local source_name=$(jq -r ".[$i].source" sources.json)
        if ! [[ " ${predefined_sources[*]} " =~ " $source_name " ]]; then
            sources+=("$source_name")
            source_choices+=("$source_name" "")
        fi
    done

    if [ ${#sources[@]} -eq 0 ]; then
        notify msg "No custom sources found!"
        return
    fi

    local selected_source
    selected_source=$("${DIALOG[@]}" \
        --title '| Delete Sources |' \
        --cancel-label 'Cancel' \
        --ok-label 'Delete' \
        --menu "$NAVIGATION_HINT\n$SELECTION_HINT" -1 -1 -1 \
        "${source_choices[@]}" \
        2>&1 > /dev/tty)
    [ -z "$selected_source" ] && return

    dialog --backtitle 'Enhancify' --defaultno \
        --yesno "Do you really want to remove '$selected_source' from sources?" 12 45

    if [ $? -eq 0 ]; then
        jq --arg source "$selected_source" \
            'map(select(.source != $source))' \
            sources.json > tmp.json && mv tmp.json sources.json
            
        notify msg "Source '$selected_source' deleted successfully!"
    fi
}

show_source_help() {
    local HELP_MSG="WARNING!! this feature is in experimental phase may sometime work may not..

To add a custom source, you need to provide details in sources.json format:-

1. Source Name: project name.

2. Repository: example Aunali321/RevancedExperiments (username/projectname)

3. JSON URL (Optional): URL of patches.json file found on github source code repo ask developers so they can assist adding this increases the sucess rate of fetching patches.

4. Version (Optional): Enter Source version if you like.

Leave optional fields blank to set them to null"

    "${DIALOG[@]}" --msgbox "$HELP_MSG" -1 -1
}
