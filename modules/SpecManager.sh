Specifications() {
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    pkg install jq -y
fi

if ! command -v dialog &> /dev/null; then
    echo "Installing dialog..."
    pkg install dialog -y
fi

if ! command -v curl &> /dev/null; then
    echo "Installing curl..."
    pkg install curl -y
fi

get_specs() {
    DEVICE_NAME=$(getprop ro.product.model)
    DEVICE_BRAND=$(getprop ro.product.brand)
    DPI=$(getprop ro.sf.lcd_density)
    ARCH=$(uname -m)
    ANDROID_VERSION=$(getprop ro.build.version.release)
    SDK_VERSION=$(getprop ro.build.version.sdk)
    TOTAL_RAM=$(free -h | grep Mem | awk '{print $2}')
    STORAGE_INFO=$(df -h /sdcard 2>/dev/null | tail -1 | awk '{print $2 " (Used: " $3 ")"}')
    KERNEL=$(uname -r)
}

get_version() {
    INFO_FILE="$HOME/Enhancify/.info"
    if [ -f "$INFO_FILE" ]; then
        VERSION_NAME=$(grep -oP '(?<=version=|VERSION=|Version=).*' "$INFO_FILE" | head -1 | xargs)
        [ -z "$VERSION_NAME" ] && VERSION_NAME=$(cat "$INFO_FILE" | head -1 | xargs)
    else
        VERSION_NAME="Not Found"
    fi
}

fetch_changelog() {
    local version="$1"
    local repo="Graywizard888/Enhancify"
    local temp_file="$HOME/Enhancify/changelog.json"

    if [ "$version" = "Not Found" ]; then
        echo "Version not found in .info file"
        return 1
    fi

    curl -s "https://api.github.com/repos/$repo/releases/tags/$version" > "$temp_file"

    if grep -q '"message".*"Not Found"' "$temp_file" 2>/dev/null; then
        if [[ $version == v* ]]; then
            version_no_v="${version#v}"
            curl -s "https://api.github.com/repos/$repo/releases/tags/$version_no_v" > "$temp_file"
        elif [[ $version != v* ]]; then
            version_with_v="v$version"
            curl -s "https://api.github.com/repos/$repo/releases/tags/$version_with_v" > "$temp_file"
        fi
    fi

    CHANGELOG=$(jq -r '.body // empty' "$temp_file" 2>/dev/null)

    rm -f "$temp_file"

    if [ -z "$CHANGELOG" ]; then
        echo "Unable to fetch changelog for version: $version"
        return 1
    else
        echo "$CHANGELOG"
    fi
}

get_specs

get_version

notify info "Loading specifications and changelog..."

CHANGELOG_TEXT=$(fetch_changelog "$VERSION_NAME")

COMBINED_TEXT="DEVICE SPECIFICATIONS

Device Brand      : $DEVICE_BRAND
Device Model      : $DEVICE_NAME
DPI               : $DPI
Android Version   : $ANDROID_VERSION
SDK Level         : $SDK_VERSION
Architecture      : $ARCH
Kernel Version    : $KERNEL
Total RAM         : $TOTAL_RAM
Storage           : $STORAGE_INFO
Enhancify Version : $VERSION_NAME

================================================

                Enhancify $VERSION_NAME Changelog

$CHANGELOG_TEXT"

dialog --title "| Specifications & Changelog |" \
       --ok-label "Understood" \
       --msgbox "$COMBINED_TEXT" -1 -1

clear
}
