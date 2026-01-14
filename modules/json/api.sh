#!/usr/bin/bash

parseJsonFromAPI() {
    local RESPONSE

    notify info "Please Wait!!\nParsing JSON file for $SOURCE patches from API."

    if ! AVAILABLE_PATCHES=$(
        "${CURL[@]}" "$JSON_URL" |
            jq -c \
                --arg STRING "$STRING" \
                --arg NUMBER "$NUMBER" \
                --arg BOOLEAN "$BOOLEAN" \
                --arg STRINGARRAY "$STRINGARRAY" '
                (if type == "array" then . else .patches // [] end) |
                reduce .[] as {
                    name: $PATCH,
                    description: $DESCRIPTION,
                    use: $USE,
                    compatiblePackages: $COMPATIBLE_PKGS,
                    options: $OPTIONS
                } (
                    [];
                    (
                        $OPTIONS |
                        if . == null then
                            []
                        elif length != 0 then
                            map(
                                . |= {"patchName": $PATCH} + . |
                                .type |= (
                                    if . == null then
                                        $STRING
                                    elif test("List") then
                                        $STRINGARRAY
                                    elif test("Boolean") then
                                        $BOOLEAN
                                    elif test("Long|Int|Float") then
                                        $NUMBER
                                    else
                                        $STRING
                                    end
                                ) |
                                .values |= (
                                    if . != null then
                                        [to_entries[] | (.value | tostring) + " (" + .key + ")"]
                                    else
                                        []
                                    end
                                )
                            )
                        else
                            []
                        end
                    ) as $OPTIONS |
                    (
                        $DESCRIPTION // "No description available"
                    ) as $DESCRIPTION |
                    [
                        $COMPATIBLE_PKGS |
                        if . == null then
                            {"name": null, "versions": []}
                        else
                            to_entries[] |
                            {"name": .key, "versions": (.value // [])}
                        end
                    ] as $COMPATIBLE_PKGS |
                    reduce $COMPATIBLE_PKGS[] as {name: $PKG_NAME, versions: $VERSIONS} (
                        .;
                        if any(.[]; .pkgName == $PKG_NAME) then
                            .
                        else
                            . |= .[0:-1] + [
                                {
                                    "pkgName": $PKG_NAME,
                                    "versions": [],
                                    "patches": {
                                        "recommended": [],
                                        "optional": []
                                    },
                                    "options": [],
                                    "descriptions": {}
                                }
                            ] + .[-1:]
                        end |
                        map(
                            if .pkgName == $PKG_NAME then
                                .versions |= (. + $VERSIONS | unique | sort) |
                                .patches |= (
                                    if $USE then
                                        .recommended += [$PATCH]
                                    else
                                        .optional += [$PATCH]
                                    end
                                ) |
                                .options += $OPTIONS |
                                .descriptions += {($PATCH): $DESCRIPTION}
                            else
                                .
                            end
                        )
                    )
                )
            ' 2> /dev/null
    ); then
        notify error "API fetch failed, falling back to CLI parsing..."
        unset JSON_URL AVAILABLE_PATCHES
        return 1
    fi

    if [ -z "$AVAILABLE_PATCHES" ] || [ "$AVAILABLE_PATCHES" = "[]" ] || [ "$AVAILABLE_PATCHES" = "null" ]; then
        notify error "API returned empty/invalid data, falling back to CLI parsing..."
        unset JSON_URL AVAILABLE_PATCHES
        return 1
    fi

    if ! jq -e '.[0].pkgName' <<< "$AVAILABLE_PATCHES" &> /dev/null; then
        notify error "API returned malformed data, falling back to CLI parsing..."
        unset JSON_URL AVAILABLE_PATCHES
        return 1
    fi

    mkdir -p "assets/$SOURCE"

    echo "$AVAILABLE_PATCHES" > "assets/$SOURCE/Patches-$PATCHES_VERSION.json"
    
    return 0
}
