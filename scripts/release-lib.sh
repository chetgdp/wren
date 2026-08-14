#!/bin/sh

# Shared deterministic checks and bundle installation. This file performs no
# build, signing, download, or launch work when sourced.

wren_die() {
    echo "wren release: $*" >&2
    return 1
}

wren_engine_root() {
    if [ -n "${WREN_ENGINE_ROOT:-}" ]; then
        printf '%s\n' "$WREN_ENGINE_ROOT"
    else
        printf '%s\n' "$1/../research/qwentts.cpp"
    fi
}


wren_validate_bundle() {
    bundle=$1
    contents="$bundle/Contents"
    resources="$contents/Resources"

    [ -d "$bundle" ] || wren_die "missing app bundle: $bundle" || return
    for relative in \
        Contents/Info.plist \
        Contents/MacOS/wren \
        Contents/Resources/uv \
        Contents/Resources/server/serve.py \
        Contents/Resources/server/storage.py \
        Contents/Resources/server/fx.py \
        Contents/Resources/server/requirements.txt \
        Contents/Resources/engine/tts-server \
        Contents/Resources/engine/libggml.0.dylib \
        Contents/Resources/engine/libggml-base.0.dylib \
        Contents/Resources/engine/libggml-blas.0.dylib \
        Contents/Resources/engine/libggml-cpu.0.dylib \
        Contents/Resources/engine/libggml-metal.0.dylib \
        Contents/Resources/voices/c3po_god.wav \
        Contents/Resources/voices/c3po_god.txt \
        Contents/Resources/AppIcon.icns
    do
        [ -f "$bundle/$relative" ] || \
            wren_die "bundle is missing $relative" || return
    done

    [ -x "$contents/MacOS/wren" ] || \
        wren_die "bundle executable is not executable" || return
    [ -x "$resources/uv" ] || \
        wren_die "bundled uv is not executable" || return
    [ -x "$resources/engine/tts-server" ] || \
        wren_die "bundled tts-server is not executable" || return

    requirement_count=$(wc -l < "$resources/server/requirements.txt")
    [ "$requirement_count" -eq 3 ] || \
        wren_die "requirements.txt must contain exactly three pins" || return
    bundle_identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no bundle identifier" || return
    [ "$bundle_identifier" = "com.digimata.wren" ] || \
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
    for component in "$@"; do
        case "$component" in
            ''|*[!0-9]*)
                wren_die "short version must have three numeric components"
                return
                ;;
        esac
    done
    build_version=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleVersion' "$contents/Info.plist" 2>/dev/null) || \
        wren_die "Info.plist has no build version" || return
    case "$build_version" in
        ''|*[!0-9]*)
            wren_die "build version must be a positive integer"
            return
            ;;
    esac
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
    destination=$2
    cli_link=$3
    previous="${destination}.old"

    wren_validate_bundle "$stage" || return
    mkdir -p "$(dirname "$destination")" "$(dirname "$cli_link")"
    rm -rf "$previous"

    if [ -d "$destination" ]; then
        mv "$destination" "$previous"
    fi
    if ! mv "$stage" "$destination"; then
        if [ -d "$previous" ]; then
            mv "$previous" "$destination"
        fi
        wren_die "could not install $destination"
        return
    fi

    if ! ln -sfn "$destination/Contents/MacOS/wren" "$cli_link"; then
        rm -rf "$destination"
        if [ -d "$previous" ]; then
            mv "$previous" "$destination"
        fi
        wren_die "could not update CLI link $cli_link"
        return
    fi
    rm -rf "$previous"
}
