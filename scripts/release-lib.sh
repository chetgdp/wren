#!/bin/sh
# Release bundle validation and installation helpers.
set -e

wren_die() {
    echo "wren release: $*" >&2
    return 1
}

wren_validate_bundle() {
    bundle=$1
    contents="$bundle/Contents"
    resources="$contents/Resources"

    [ -d "$bundle" ] || wren_die "missing app bundle: $bundle" || return
    for relative in \
        Contents/Info.plist \
        Contents/MacOS/wren \
        Contents/Resources/AppIcon.icns
    do
        [ -f "$bundle/$relative" ] || \
            wren_die "bundle is missing $relative" || return
    done

    [ -x "$contents/MacOS/wren" ] || \
        wren_die "bundle executable is not executable" || return

    bundle_identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no bundle identifier" || return
    [ "$bundle_identifier" = "com.heavyetl.wren" ] || \
        wren_die "Info.plist has the wrong bundle identifier" || return
    bundle_executable=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no executable name" || return
    [ "$bundle_executable" = "wren" ] || \
        wren_die "Info.plist names the wrong executable" || return
    package_type=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundlePackageType' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no package type" || return
    [ "$package_type" = "APPL" ] || \
        wren_die "Info.plist is not an application bundle" || return
    short_version=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' "$contents/Info.plist" \
        2>/dev/null) || \
        wren_die "Info.plist has no short version" || return
    old_ifs=$IFS
    IFS=.
    set -- $short_version
    IFS=$old_ifs
    [ "$#" -eq 3 ] || \
        wren_die "short version must have three numeric components" || return

    build_version=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleVersion' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no build version" || return
    [ "$build_version" -gt 0 ] || \
        wren_die "build version must be a positive integer" || return

    icon_name=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIconFile' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no icon name" || return
    [ "$icon_name" = "AppIcon" ] || \
        wren_die "Info.plist names the wrong app icon" || return
}

wren_install_bundle() {
    stage=$1
    dest=$2
    cli_link=$3

    mkdir -p "$(dirname "$dest")" "$(dirname "$cli_link")"
    old="$dest.old"
    rm -rf "$old"
    if [ -d "$dest" ]; then
        mv "$dest" "$old"
    fi
    if ! mv "$stage" "$dest"; then
        if [ -d "$old" ]; then
            mv "$old" "$dest"
        fi
        wren_die "bundle swap failed" || return
    fi
    if ! ln -sfn "$dest/Contents/MacOS/wren" "$cli_link"; then
        rm -rf "$dest"
        if [ -d "$old" ]; then
            mv "$old" "$dest"
        fi
        wren_die "cli symlink update failed" || return
    fi
    rm -rf "$old"
}
