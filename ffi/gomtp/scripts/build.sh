#!/usr/bin/env bash

set -e

export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PKG_ROOT_DIR="$(cd "$SCRIPT_DIR/../../../" >/dev/null 2>&1 && pwd)"
TEMP_ROOT_DIR="$PKG_ROOT_DIR/tmp"
LIBUSB_BOTTLE_TEMP_DIR="$TEMP_ROOT_DIR/libusb_cache"
GOMTP_NATIVE_DIR="$PKG_ROOT_DIR/ffi/gomtp/native"
BUILD_BASE_DIR="$PKG_ROOT_DIR/lib"

# Keep only the architectures you need, e.g. ARCHES="arm64".
ARCHES="${ARCHES:-arm64 amd64}"

echo "creating the temp directory in $TEMP_ROOT_DIR..."
mkdir -p "$TEMP_ROOT_DIR"

echo "creating the libusb temp directory in $LIBUSB_BOTTLE_TEMP_DIR..."
mkdir -p "$LIBUSB_BOTTLE_TEMP_DIR"
chmod -R +w "$LIBUSB_BOTTLE_TEMP_DIR"

MACOS_VERSION=$(sw_vers -productVersion)
IFS='.' read -r major minor patch <<< "$MACOS_VERSION"

if [ "$major" -lt 10 ] || ( [ "$major" -eq 10 ] && [ "$minor" -lt 14 ] ); then
    echo "To build the gomtp dylib files at least macOS >=10.14 is required"
    exit 1
fi

IS_HISTORIC=false
if [ "$major" -eq 10 ] && [ "$minor" -ge 14 ] && [ "$minor" -le 15 ]; then
    IS_HISTORIC=true
    echo "This is a historical version of macOS."
    echo "Support for these older version of the oses are now being deprecated..."
fi

# bottle entry: "sha256 arch os osName osVersion libusbVersion"
declare -a BOTTLES_LATEST=(
    "d9121e56c7dbfad640c9f8e3c3cc621d88404dc1047a4a7b7c82fe06193bca1f arm64 darwin mac big_sur 1.0.26"
    "1318e1155192bdaf7d159562849ee8f73cb0f59b0cb77c142f8be99056ba9d9e amd64 darwin mac mojave 1.0.24"
)

declare -a BOTTLES_HISTORIC=(
    "1318e1155192bdaf7d159562849ee8f73cb0f59b0cb77c142f8be99056ba9d9e amd64 darwin mac mojave 1.0.24"
)

if [ "$IS_HISTORIC" = true ]; then
    CHOSEN_BOTTLES=("${BOTTLES_HISTORIC[@]}")
else
    CHOSEN_BOTTLES=("${BOTTLES_LATEST[@]}")
fi

lipo_inputs=()

for bottle_info in "${CHOSEN_BOTTLES[@]}"; do
    IFS=" " read -r sha256 arch os osName osVersion libusbVersion <<< "$bottle_info"

    if [[ " $ARCHES " != *" $arch "* ]]; then
        continue
    fi

    IDENTIFIER="libusb_${libusbVersion}_${osVersion}_${os}_${arch}"
    TARBALL="$LIBUSB_BOTTLE_TEMP_DIR/$IDENTIFIER.tar.gz"
    EXTRACTED="$LIBUSB_BOTTLE_TEMP_DIR/$IDENTIFIER"
    PKGCONFIG_BASE_DIR="$EXTRACTED/libusb/$libusbVersion/lib/pkgconfig"
    PKGCONFIG="$PKGCONFIG_BASE_DIR/libusb-1.0.pc"
    PKGCONFIG_PREFIX="$EXTRACTED"
    LIBUSB_DYLIB="$EXTRACTED/libusb/$libusbVersion/lib/libusb-1.0.0.dylib"
    BUILD_DIR="$BUILD_BASE_DIR/bin/$arch"
    GOMTP_DYLIB_IN_BUILD_DIR="$BUILD_DIR/gomtp.dylib"
    RPATH="@loader_path/libusb.dylib"

    echo "attempting to download the libusb tar file for: $os-$osName-$osVersion-$arch-$libusbVersion"
    if [ ! -f "$TARBALL" ]; then
        curl -L -H "Authorization: Bearer QQ==" -o "$TARBALL" "https://ghcr.io/v2/homebrew/core/libusb/blobs/sha256:$sha256"
    fi

    echo "[$IDENTIFIER] creating the libusb temp directory in $EXTRACTED..."
    mkdir -p "$EXTRACTED"
    tar -xf "$TARBALL" -C "$EXTRACTED" --no-same-permissions
    chmod -R +w "$EXTRACTED"

    echo "[$IDENTIFIER] replacing the string '@@HOMEBREW_CELLAR@@' in the pkg-config file..."
    sed -i '' "s|@@HOMEBREW_CELLAR@@|$PKGCONFIG_PREFIX|g" "$PKGCONFIG"

    echo "[$IDENTIFIER] fixing the install name of the libusb dylib..."
    install_name_tool -id "$RPATH" "$LIBUSB_DYLIB"

    echo "building gomtp for $arch..."
    mkdir -p "$BUILD_DIR"
    (
        cd "$GOMTP_NATIVE_DIR" && \
        CGO_ENABLED=1 \
        PKG_CONFIG_PATH="$PKGCONFIG_BASE_DIR" \
        CGO_CFLAGS='-mmacosx-version-min=12.0' \
        CGO_LDFLAGS='-mmacosx-version-min=12.0' \
        GOARCH=$arch GOOS=$os \
        go build -v -trimpath -o "$GOMTP_DYLIB_IN_BUILD_DIR" -buildmode=c-shared ./*.go
    )

    # match the install name the Xcode project expects for the bundled dylib
    install_name_tool -id "@rpath/gomtp.dylib" "$GOMTP_DYLIB_IN_BUILD_DIR"

    lipo_inputs+=("$GOMTP_DYLIB_IN_BUILD_DIR")
done

if [ ${#lipo_inputs[@]} -gt 1 ]; then
    echo "Creating universal binaries with lipo..."
    lipo -create -output "$BUILD_BASE_DIR/gomtp.dylib" "${lipo_inputs[@]}"
elif [ ${#lipo_inputs[@]} -eq 1 ]; then
    cp "${lipo_inputs[0]}" "$BUILD_BASE_DIR/gomtp.dylib"
fi

if [ -f "$BUILD_BASE_DIR/bin/arm64/gomtp.h" ]; then
    cp "$BUILD_BASE_DIR/bin/arm64/gomtp.h" "$BUILD_BASE_DIR/gomtp.h"
elif [ -f "$BUILD_BASE_DIR/bin/amd64/gomtp.h" ]; then
    cp "$BUILD_BASE_DIR/bin/amd64/gomtp.h" "$BUILD_BASE_DIR/gomtp.h"
fi

echo "gomtp dylib created successfully in $BUILD_BASE_DIR!"
