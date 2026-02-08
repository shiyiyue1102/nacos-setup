#!/usr/bin/env bash

set -euo pipefail

# package.sh - create nacos-setup-Linux-VERSION.zip and nacos-setup-Windows-VERSION.zip
# Usage: ./package.sh [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

print() { echo "[package] $*"; }

usage() {
    cat <<EOF
Usage: $0 [version]

If version is not provided, the script will try to detect it from:
  1) variable NACOS_SETUP_VERSION in ./nacos-setup.sh
  2) git describe --tags --always

Output: 
  ./dist/nacos-setup-VERSION.zip (Linux/macOS)
  ./dist/nacos-setup-windows-VERSION.zip
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

VERSION="${1:-}"

# Prefer version declared in nacos-setup.sh
file_version=""
if [ -f "$PROJECT_ROOT/nacos-setup.sh" ]; then
    file_version=$(sed -n 's/^NACOS_SETUP_VERSION="\(.*\)"/\1/p' "$PROJECT_ROOT/nacos-setup.sh" || true)
fi

if [ -n "$file_version" ]; then
    if [ -n "$VERSION" ] && [ "$VERSION" != "$file_version" ]; then
        echo "[package] Warning: provided version '$VERSION' differs from NACOS_SETUP_VERSION='$file_version' in nacos-setup.sh; using file version."
    fi
    VERSION="$file_version"
else
    if [ -z "$VERSION" ]; then
        echo "[package] Error: NACOS_SETUP_VERSION not found in nacos-setup.sh and no version argument provided."
        echo "Provide a version: ./package.sh 1.2.3  or define NACOS_SETUP_VERSION in nacos-setup.sh"
        exit 1
    fi
fi

DIST_DIR="$PROJECT_ROOT/dist"
mkdir -p "$DIST_DIR"

# ====================
# Package Linux version (also for macOS)
# ====================
package_linux() {
    local name="nacos-setup-$VERSION"
    local tmp_dir="/tmp/${name}-package-$$"
    
    print "Packaging Linux version: $VERSION"
    print "Staging to: $tmp_dir"
    
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir/$name"
    
    # Linux files only
    local include=("nacos-setup.sh" "nacos-installer.sh" "lib" "README.md" "LICENSE")
    
    for f in "${include[@]}"; do
        if [ -e "$PROJECT_ROOT/$f" ]; then
            cp -a "$PROJECT_ROOT/$f" "$tmp_dir/$name/"
        else
            print "Warning: $f not found, skipping"
        fi
    done
    
    # Ensure scripts are executable
    if [ -d "$tmp_dir/$name/lib" ]; then
        chmod +x "$tmp_dir/$name/lib"/*.sh 2>/dev/null || true
    fi
    if [ -f "$tmp_dir/$name/nacos-setup.sh" ]; then
        chmod +x "$tmp_dir/$name/nacos-setup.sh" 2>/dev/null || true
    fi
    if [ -f "$tmp_dir/$name/nacos-installer.sh" ]; then
        chmod +x "$tmp_dir/$name/nacos-installer.sh" 2>/dev/null || true
    fi
    
    pushd "$tmp_dir" >/dev/null
    local zipfile="$DIST_DIR/${name}.zip"
    print "Creating zip: $zipfile"
    zip -r -q "$zipfile" "$name"
    popd >/dev/null
    
    # Verify
    if unzip -tqq "$zipfile" >/dev/null 2>&1; then
        print "Linux package verified: OK"
    else
        print "Linux package verification: FAILED"
        exit 1
    fi
    
    rm -rf "$tmp_dir"
    print "Linux package: $zipfile"
}

# ====================
# Package Windows version
# ====================
package_windows() {
    local name="nacos-setup-windows-$VERSION"
    local tmp_dir="/tmp/${name}-package-$$"
    
    print "Packaging Windows version: $VERSION"
    print "Staging to: $tmp_dir"
    
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir/$name"
    
    # Windows files only
    if [ -d "$PROJECT_ROOT/windows" ]; then
        cp -a "$PROJECT_ROOT/windows"/* "$tmp_dir/$name/"
    else
        print "Error: windows directory not found"
        exit 1
    fi
    
    # Copy shared documentation
    cp "$PROJECT_ROOT/README.md" "$tmp_dir/$name/" 2>/dev/null || true
    cp "$PROJECT_ROOT/LICENSE" "$tmp_dir/$name/" 2>/dev/null || true
    
    pushd "$tmp_dir" >/dev/null
    local zipfile="$DIST_DIR/${name}.zip"
    print "Creating zip: $zipfile"
    zip -r -q "$zipfile" "$name"
    popd >/dev/null
    
    # Verify
    if unzip -tqq "$zipfile" >/dev/null 2>&1; then
        print "Windows package verified: OK"
    else
        print "Windows package verification: FAILED"
        exit 1
    fi
    
    rm -rf "$tmp_dir"
    print "Windows package: $zipfile"
}

# ====================
# Main
# ====================
print "========================================"
print "Packaging Nacos Setup v$VERSION"
print "========================================"
echo ""

package_linux
echo ""
package_windows

echo ""
print "========================================"
print "All packages created successfully!"
print "========================================"
print "Output directory: $DIST_DIR"
ls -lh "$DIST_DIR"/*.zip

exit 0
