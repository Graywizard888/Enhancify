#!/usr/bin/bash

parseJsonFromCLI() {

    local PACKAGES PATCHES TOTAL CTR DESCRIPTION OPTION_DESC
    local EXT="${PATCHES_FILE##*.}"
    local _tmpdir=""
    local _output_file="assets/${SOURCE}/Patches-${PATCHES_VERSION}.json"

    local _var
    for _var in CLI_FILE PATCHES_FILE SOURCE PATCHES_VERSION; do
        if [[ -z "${!_var:-}" ]]; then
            notify msg "Required variable \$$_var is not set."
            return 1
        fi
    done

    if [[ ! -f "$CLI_FILE" ]]; then
        notify msg "CLI file not found: $CLI_FILE"
        return 1
    fi

    if [[ ! -f "$PATCHES_FILE" ]]; then
        notify msg "Patches file not found: $PATCHES_FILE"
        return 1
    fi

    local _dep
    for _dep in jq java; do
        if ! command -v "$_dep" >/dev/null 2>&1; then
            notify msg "Required dependency '$_dep' not found."
            return 1
        fi
    done

    local T_STRING="${STRING:-STRING}"
    local T_NUMBER="${NUMBER:-NUMBER}"
    local T_BOOLEAN="${BOOLEAN:-BOOLEAN}"
    local T_STRINGARRAY="${STRINGARRAY:-STRINGARRAY}"

    _tmpdir=$(mktemp -d) || {
        notify msg "Failed to create temp directory."
        return 1
    }

    mkdir -p "assets/$SOURCE"

    local -a _ver_cmd=() _patch_cmd=()

    if [[ "$SOURCE" = "ReVanced" ]]; then

        _ver_cmd=(
            java -jar "$CLI_FILE" list-versions
            "--patches=$PATCHES_FILE" -u --bypass-verification
        )
        _patch_cmd=(
            java -jar "$CLI_FILE" list-patches
            "--patches=$PATCHES_FILE"
            --descriptions --options --packages
            --versions --universal-patches --bypass-verification
        )

    elif [[ "$EXT" = "mpp" ]]; then

        _ver_cmd=(
            java -jar "$CLI_FILE" list-versions
            "--patches=$PATCHES_FILE" -u
        )
        _patch_cmd=(
            java -jar "$CLI_FILE" list-patches
            "--patches=$PATCHES_FILE"
            --with-descriptions --with-options --with-packages
            --with-versions --with-universal-patches
        )

    else

        _ver_cmd=(
            java -jar "$CLI_FILE" list-versions
            "$PATCHES_FILE" -u
        )
        _patch_cmd=(
            java -jar "$CLI_FILE" list-patches
            "$PATCHES_FILE"
            --with-descriptions --with-options --with-packages
            --with-versions --with-universal-patches
        )

    fi

    ( set -o pipefail; "${_ver_cmd[@]}" 2>/dev/null | sed 's/^INFO: //' > "$_tmpdir/ver_raw.txt" ) &
    local _pid_ver=$!

    ( set -o pipefail; "${_patch_cmd[@]}" 2>/dev/null | sed 's/^INFO: //' > "$_tmpdir/patch_raw.txt" ) &
    local _pid_patch=$!

    if ! wait "$_pid_ver"; then
        notify msg "CLI list-versions command failed."
        rm -rf "$_tmpdir"
        return 1
    fi

    if ! wait "$_pid_patch"; then
        notify msg "CLI list-patches command failed."
        rm -rf "$_tmpdir"
        return 1
    fi

    readarray -d '' -t PACKAGES < <(
        awk -v RS='' -v ORS='\0' '1' "$_tmpdir/ver_raw.txt"
    )

    readarray -d '' -t PATCHES < <(
        awk -v RS='' -v ORS='\0' '1' "$_tmpdir/patch_raw.txt"
    )

    TOTAL=$(( ${#PACKAGES[@]} + ${#PATCHES[@]} ))
    [[ $TOTAL -eq 0 ]] && TOTAL=1
    CTR=0

    : > "$_tmpdir/packages.ndjson"

    for PACKAGE in "${PACKAGES[@]}"; do

        local PKG_NAME=""
        local -a PKG_VERSIONS=()

        while IFS= read -r _line; do
            case "$_line" in
                P*:\ *)  PKG_NAME="${_line##*: }" ;;
                $'\t'*)  PKG_VERSIONS+=("${_line#$'\t'}") ;;
            esac
        done <<< "$PACKAGE"

        if [[ -n "$PKG_NAME" ]]; then
            jq -nc --arg PKG_NAME "$PKG_NAME" '
                {
                    "pkgName": $PKG_NAME,
                    "versions": (
                        $ARGS.positional |
                        if .[0] == "Any" then []
                        else [ .[] | match(".*(?= \\()").string ]
                        end | sort
                    ),
                    "patches": {"recommended": [], "optional": []},
                    "options": [],
                    "descriptions": {}
                }
            ' --args "${PKG_VERSIONS[@]}" >> "$_tmpdir/packages.ndjson" 2>/dev/null
        fi

        unset PKG_NAME PKG_VERSIONS

        ((CTR++))
        echo "$(( (CTR * 100) / TOTAL ))"
    done

    unset PACKAGES

    echo '{"pkgName":null,"versions":[],"patches":{"recommended":[],"optional":[]},"options":[],"descriptions":{}}' \
        >> "$_tmpdir/packages.ndjson"

    : > "$_tmpdir/patches.ndjson"

    for PATCH in "${PATCHES[@]}"; do

        local PATCH_NAME="" USE="" DESCRIPTION=""
        local -a COMP_PKGS=()

        while IFS= read -r _line; do
            case "$_line" in
                "Name: "*)        PATCH_NAME="${_line#Name: }" ;;
                "Enabled: "*)     USE="${_line#Enabled: }" ;;
                "Description: "*) DESCRIPTION="${_line#Description: }" ;;
            esac
        done <<< "$PATCH"

        if [[ -z "$PATCH_NAME" ]]; then
            ((CTR++))
            echo "$(( (CTR * 100) / TOTAL ))"
            continue
        fi

        [[ -z "$DESCRIPTION" ]] && DESCRIPTION="No description available"

        PATCH=$(sed '/^Name:/d;/^Enabled:/d;/^Description:/d' <<< "$PATCH")

        if grep -q '^Compatible packages:' <<< "$PATCH"; then
            readarray -t COMP_PKGS < <(
                grep $'^\tPackage name:' <<< "$PATCH" | sed 's/.*: //;s/ //g'
            )
            PATCH=$(sed '/^Compatible packages:/d;/^\tPackage name:/d;/^\tVersions:/d;/^\tCompatible versions:/d;/^\t\t/d' <<< "$PATCH")
        fi

        local _opts_file="$_tmpdir/opts_${CTR}.json"
        printf '[]' > "$_opts_file"

        if grep -q "^Options:" <<< "$PATCH"; then

            PATCH=$(sed '/^Options:/d;s/^\t//g' <<< "$PATCH")

            local -a OPTIONS=()

            if [[ "$SOURCE" = "ReVanced" ]]; then
                readarray -d '' -t OPTIONS < <(
                    awk -v RS='\n\nName' -v ORS='\0' '1' <<< "$PATCH"
                )
            else
                readarray -d '' -t OPTIONS < <(
                    awk -v RS='\n\nTitle' -v ORS='\0' '1' <<< "$PATCH"
                )
            fi

            for OPTION in "${OPTIONS[@]}"; do

                local TITLE="" KEY="" REQUIRED="" DEFAULT="" TYPE=""
                local -a VALUES=()

                if [[ "$SOURCE" = "ReVanced" ]]; then
                    TITLE=$(grep -E -m1 '^Name:|^:' <<< "$OPTION" | sed 's/.*: //')
                    KEY="${TITLE// /}"
                    REQUIRED=$(grep -m1 '^Required:' <<< "$OPTION" | sed 's/.*: //')
                    DEFAULT=$(grep -m1 '^Default:' <<< "$OPTION" | sed 's/.*: //' | tr -d '\t\r')
                    TYPE=$(grep -m1 '^Type:' <<< "$OPTION" | sed 's/.*: //;s/ //')
                else
                    KEY=$(grep -m1 '^Key:' <<< "$OPTION" | sed 's/.*: //;s/ //g')
                    TITLE=$(grep -E -m1 '^Title:|^:' <<< "$OPTION" | sed 's/.*: //')
                    REQUIRED=$(grep -m1 '^Required:' <<< "$OPTION" | sed 's/.*: //')
                    DEFAULT=$(grep -m1 '^Default:' <<< "$OPTION" | sed 's/.*: //')
                    TYPE=$(grep -m1 '^Type:' <<< "$OPTION" | sed 's/.*: //;s/ //')
                fi

                if grep -q "^Possible values:" <<< "$OPTION"; then
                    readarray -t VALUES < <(
                        grep $'^\t' <<< "$OPTION" | sed 's/\t//'
                    )
                fi

                if [[ "$SOURCE" = "ReVanced" ]]; then
                    OPTION=$(sed '/^Name:/d;/^:/d;/^Required:/d;/^Default:/d;/^Type:/d;/^Possible values:/d;/^\t/d' <<< "$OPTION")
                    OPTION_DESC=$(sed 's/^Description: //' <<< "$OPTION" | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//')
                else
                    OPTION=$(sed '/^Key:/d;/^Title:/d;/^:/d;/^Required:/d;/^Default:/d;/^Type:/d;/^Possible values:/d;/^\t/d' <<< "$OPTION")
                    OPTION_DESC=$(sed 's/^Description: //;s/\n/\\n/g' <<< "$OPTION")
                fi

                if [[ "$SOURCE" = "ReVanced" ]]; then

                    jq -nc \
                        --arg PATCH_NAME "$PATCH_NAME" \
                        --arg KEY "$KEY" \
                        --arg TITLE "$TITLE" \
                        --arg DESCRIPTION "$OPTION_DESC" \
                        --arg REQUIRED "$REQUIRED" \
                        --arg DEFAULT "$DEFAULT" \
                        --arg TYPE "$TYPE" \
                        --arg STRING "$T_STRING" \
                        --arg NUMBER "$T_NUMBER" \
                        --arg BOOLEAN "$T_BOOLEAN" \
                        --arg STRINGARRAY "$T_STRINGARRAY" '

                        ($TYPE |
                            if . == null or . == "" then $STRING
                            elif test("List")           then $STRINGARRAY
                            elif test("Boolean")        then $BOOLEAN
                            elif test("Long|Int|Float") then $NUMBER
                            else $STRING end
                        ) as $rType |

                        ($DEFAULT |
                            if . != "" and . != null then
                                if   $rType == $STRING  then tostring
                                elif $rType == $NUMBER  then tonumber
                                elif $rType == $BOOLEAN then (. == "true")
                                elif $rType == $STRINGARRAY then (
                                    gsub("^\\[|\\]$"; "") | split(",") |
                                    map(gsub("^\\s+|\\s+$"; "") | gsub("^\"|\"$"; "")) |
                                    map(select(. != ""))
                                )
                                else . end
                            else null end
                        ) as $rDefault |

                        {
                            "patchName":   $PATCH_NAME,
                            "key":         $KEY,
                            "title":       $TITLE,
                            "description": $DESCRIPTION,
                            "required":    ($REQUIRED == "true"),
                            "type":        $rType,
                            "default":     $rDefault,
                            "values":      $ARGS.positional
                        }

                    ' --args "${VALUES[@]}" 2>/dev/null

                else

                    jq -nc \
                        --arg PATCH_NAME "$PATCH_NAME" \
                        --arg KEY "$KEY" \
                        --arg TITLE "$TITLE" \
                        --arg DESCRIPTION "$OPTION_DESC" \
                        --arg REQUIRED "$REQUIRED" \
                        --arg DEFAULT "$DEFAULT" \
                        --arg TYPE "$TYPE" \
                        --arg STRING "$T_STRING" \
                        --arg NUMBER "$T_NUMBER" \
                        --arg BOOLEAN "$T_BOOLEAN" \
                        --arg STRINGARRAY "$T_STRINGARRAY" '

                        ($TYPE |
                            if . == null or . == "" then $STRING
                            elif test("List")           then $STRINGARRAY
                            elif test("Boolean")        then $BOOLEAN
                            elif test("Long|Int|Float") then $NUMBER
                            else $STRING end
                        ) as $rType |

                        ($DEFAULT |
                            if . != "" and . != null then
                                if   $rType == $STRING  then tostring
                                elif $rType == $NUMBER  then tonumber
                                elif $rType == $BOOLEAN then (. == "true")
                                elif $rType == $STRINGARRAY then (
                                    gsub("(?<a>([^,\\[\\] ]+))"; "\"" + .a + "\"") |
                                    fromjson
                                )
                                else . end
                            else null end
                        ) as $rDefault |

                        {
                            "patchName":   $PATCH_NAME,
                            "key":         $KEY,
                            "title":       $TITLE,
                            "description": $DESCRIPTION,
                            "required":    ($REQUIRED == "true"),
                            "type":        $rType,
                            "default":     $rDefault,
                            "values":      $ARGS.positional
                        }

                    ' --args "${VALUES[@]}" 2>/dev/null

                fi

                unset TITLE KEY OPTION_DESC REQUIRED DEFAULT TYPE VALUES

            done > "$_tmpdir/opts_${CTR}.ndjson"

            unset OPTIONS

            if [[ -s "$_tmpdir/opts_${CTR}.ndjson" ]]; then
                jq -sc '.' "$_tmpdir/opts_${CTR}.ndjson" > "$_opts_file" 2>/dev/null \
                    || printf '[]' > "$_opts_file"
            fi

        fi

        jq -nc \
            --arg name "$PATCH_NAME" \
            --arg use "$USE" \
            --arg desc "$DESCRIPTION" \
            --slurpfile opts "$_opts_file" '
            {
                "name":        $name,
                "enabled":     ($use == "true"),
                "description": $desc,
                "options":     ($opts[0] // []),
                "packages":    $ARGS.positional
            }
        ' --args "${COMP_PKGS[@]}" >> "$_tmpdir/patches.ndjson" 2>/dev/null

        unset PATCH PATCH_NAME DESCRIPTION COMP_PKGS

        ((CTR++))
        echo "$(( (CTR * 100) / TOTAL ))"
    done

    unset TOTAL CTR PATCHES

    [[ -f "$_tmpdir/patches.ndjson" ]] || : > "$_tmpdir/patches.ndjson"

    jq -n \
        --slurpfile pkgs "$_tmpdir/packages.ndjson" \
        --slurpfile patches "$_tmpdir/patches.ndjson" '

        reduce $patches[] as $p ($pkgs;

            ($p.packages |
                if length == 0 then [null] else . end
            ) as $targets |

            reduce $targets[] as $pkg (.;
                map(
                    if .pkgName == $pkg then
                        .patches |= (
                            if $p.enabled then
                                .recommended += [$p.name]
                            else
                                .optional += [$p.name]
                            end
                        ) |
                        .options      += $p.options |
                        .descriptions += {($p.name): $p.description}
                    else .
                    end
                )
            )
        )

    ' > "$_tmpdir/result.json" 2>/dev/null


    if [[ -s "$_tmpdir/result.json" ]]; then
        mv "$_tmpdir/result.json" "$_output_file"
        AVAILABLE_PATCHES=$(cat "$_output_file")
    else
        notify msg "Failed to generate patches JSON."
        rm -rf "$_tmpdir"
        return 1
    fi

    rm -rf "$_tmpdir"
}
