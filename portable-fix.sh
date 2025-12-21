#!/bin/bash

PREFIX="./dist"
BIN_DIR="${PREFIX}/bin"
LIB_DIR="${PREFIX}/lib"

RPATH_TEST="@loader_path/../lib"
RPATH_PROD="@loader_path/../Frameworks"

set -e

# Iterate over all .dylib files in the lib directory to build a list of our libraries
MY_LIBS=()
for lib in "$LIB_DIR"/*.dylib; do
  if [[ -f "$lib" ]]; then
    MY_LIBS+=("$(basename "$lib")")
  fi
done
echo "🔍 Detected libraries: ${MY_LIBS[*]}"

# Function to check if a library is in our list
is_my_lib() {
  local target=$1
  for lib_name in "${MY_LIBS[@]}"; do
    if [[ "$target" == "$lib_name" ]]; then
      return 0 # True
    fi
  done
  return 1 # False
}

echo "🚀 [Stage 1] Fix install names and dependencies in our own libraries"
for lib_path in "$LIB_DIR"/*.dylib; do
  # Skip non-files
  [ -e "$lib_path" ] || continue

  lib_name=$(basename "$lib_path")
  echo "   Processing library: $lib_name"

  # 1.1 Fix own install name (LC_ID_DYLIB)
  install_name_tool -id "@rpath/$lib_name" "$lib_path"

  # 1.2 Fix dependencies (LC_LOAD_DYLIB)
  # Get all dependencies of this library, excluding itself
  dependencies=$(otool -L "$lib_path" | grep ".dylib" | awk '{print $1}')

  for dep in $dependencies; do
    dep_name=$(basename "$dep")

    # If the dependency is one of our libraries, change its path to @loader_path
    if is_my_lib "$dep_name"; then
      if [[ "$dep" != @loader_path* ]]; then
        echo "      -> Redirecting dependency: $dep_name -> @loader_path/$dep_name"
        install_name_tool -change "$dep" "@loader_path/$dep_name" "$lib_path"
      fi
    fi
  done

  # 1.3 Code signing
  echo "      -> Code signing library: $lib_name"
  codesign --force --sign - "$lib_path"
done

echo "🚀 [Stage 2] Fix dependencies in our binaries"
for bin_path in "$BIN_DIR"/*; do
  # Skip non-files
  [ -f "$bin_path" ] || continue

  # Check if it's a Mach-O binary
  file_type=$(file -b "$bin_path")
  if [[ "$file_type" != *"Mach-O"* ]]; then
    echo "   Skipping non-Mach-O file: $(basename "$bin_path")"
    continue
  fi

  bin_name=$(basename "$bin_path")
  echo "   Processing binary: $bin_name"

  # 2.1 Fix dependencies (LC_LOAD_DYLIB)
  dependencies=$(otool -L "$bin_path" | grep ".dylib" | awk '{print $1}')

  for dep in $dependencies; do
    dep_name=$(basename "$dep")

    if is_my_lib "$dep_name"; then
      if [[ "$dep" != @rpath* ]]; then
        echo "      -> Redirecting dependency: $dep_name -> @rpath/$dep_name"
        install_name_tool -change "$dep" "@rpath/$dep_name" "$bin_path"
      fi
    fi
  done

  # 2.2 Inject RPATH (first remove old ones to avoid duplicates, or simply add new ones)
  # Here we adopt a "try to add" strategy; for more rigor, you can first check if it exists

  # Inject @loader_path RPATH
  if ! otool -l "$bin_path" | grep -q '@loader_path'; then
    echo "      -> Adding RPATH: @loader_path"
    install_name_tool -add_rpath "@loader_path" "$bin_path"
  fi

  # Inject test environment path
  if ! otool -l "$bin_path" | grep -q "$RPATH_TEST"; then
    echo "      -> Adding RPATH: $RPATH_TEST"
    install_name_tool -add_rpath "$RPATH_TEST" "$bin_path"
  fi

  # Inject production environment path
  if ! otool -l "$bin_path" | grep -q "$RPATH_PROD"; then
    echo "      -> Adding RPATH: $RPATH_PROD"
    install_name_tool -add_rpath "$RPATH_PROD" "$bin_path"
  fi

  # 2.3 Code signing
  echo "      -> Code signing binary: $bin_name"
  codesign --force --sign - "$bin_path"
done

echo "✅ All binaries and libraries have been fixed successfully."
