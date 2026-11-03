#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
mkdir -p "${LIBRARIES_ROOT}"
cd "${LIBRARIES_ROOT}"

download_tarball() {
    local url="$1" archive="$2"
    if [ -f "$archive" ] && gzip -t "$archive" >/dev/null 2>&1 && tar -tzf "$archive" >/dev/null 2>&1; then
        echo "Using verified source archive: $archive"
        return
    fi
    if [ -e "$archive" ]; then
        echo "Discarding invalid source archive: $archive"
        rm -f "$archive"
    fi
    echo "Downloading source archive: $archive"
    local temporary="${archive}.part.$$"
    rm -f "$temporary"
    if ! curl --fail --location --retry 3 --retry-delay 2 --output "$temporary" "$url"; then
        rm -f "$temporary"
        echo "Download failed: could not fetch $url" >&2
        return 1
    fi
    if ! gzip -t "$temporary" >/dev/null 2>&1 || ! tar -tzf "$temporary" >/dev/null 2>&1; then
        rm -f "$temporary"
        echo "Download failed: $url did not provide a valid .tar.gz source archive." >&2
        return 1
    fi
    mv "$temporary" "$archive"
}

##########################
# --- ZLIB BUILD --------
##########################
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
ZLIB_DIR="zlib-${ZLIB_VERSION}"

if [ ! -d "${ZLIB_DIR}" ]; then
    download_tarball "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}.tar.gz"
    tar -xzf zlib-${ZLIB_VERSION}.tar.gz
    rm zlib-${ZLIB_VERSION}.tar.gz
fi

cd "${ZLIB_DIR}"

rm -rf build_x86_64 build_arm64 build_universal install_x86_64 install_arm64

NUM_CORES=${BUILD_JOBS:-2}

echo "Building zlib x86_64..."
mkdir -p build_x86_64 && cd build_x86_64
cmake .. -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_INSTALL_PREFIX=../install_x86_64
cmake --build . --parallel ${NUM_CORES}
cmake --install .
cd ..

echo "Building zlib arm64..."
mkdir -p build_arm64 && cd build_arm64
cmake .. -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_INSTALL_PREFIX=../install_arm64
cmake --build . --parallel ${NUM_CORES}
cmake --install .
cd ..

echo "Creating universal zlib static library..."
mkdir -p build_universal/lib build_universal/include
lipo -create install_x86_64/lib/libz.a install_arm64/lib/libz.a -output build_universal/lib/libz.a
cp -R install_arm64/include/* build_universal/include/

mkdir -p build_universal/share/cmake/zlib
cat > build_universal/share/cmake/zlib/zlib-config.cmake <<EOL
set(ZLIB_FOUND TRUE)
set(ZLIB_VERSION "${ZLIB_VERSION}")
set(ZLIB_INCLUDE_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(ZLIB_LIBRARY_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../../lib")
add_library(ZLIB::ZLIB STATIC IMPORTED)
set_target_properties(ZLIB::ZLIB PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "\${ZLIB_INCLUDE_DIRS}"
  IMPORTED_LOCATION "\${ZLIB_LIBRARY_DIRS}/libz.a"
)
set(ZLIB_LIBRARIES ZLIB::ZLIB)
EOL

cat > build_universal/share/cmake/zlib/zlib-config-version.cmake <<EOL
set(PACKAGE_VERSION "${ZLIB_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOL

echo "✅ zlib universal static library built."

cd ..

##########################
# --- HDF5 BUILD --------
##########################
HDF5_VERSION="${HDF5_VERSION:-1.14.6}"
HDF5_DIR_NAME="hdf5-${HDF5_VERSION}"

if [ ! -d "${HDF5_DIR_NAME}" ]; then
    download_tarball "https://github.com/HDFGroup/hdf5/releases/download/hdf5_1.14.6/hdf5-${HDF5_VERSION}.tar.gz" "hdf5-${HDF5_VERSION}.tar.gz"
    tar -xzf hdf5-${HDF5_VERSION}.tar.gz
    rm hdf5-${HDF5_VERSION}.tar.gz
    if [ ! -d "${HDF5_DIR_NAME}" ]; then
        echo "HDF5 archive did not create the expected source folder: ${HDF5_DIR_NAME}" >&2
        exit 1
    fi
fi

cd "${HDF5_DIR_NAME}"
rm -rf build_universal_static install_universal_static

echo "Building HDF5 universal static libraries..."
mkdir -p build_universal_static && cd build_universal_static
cmake .. \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_EXECS=OFF \
    -DHDF5_BUILD_EXAMPLES=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DHDF5_BUILD_TOOLS=OFF \
    -DHDF5_BUILD_HL_LIB=ON \
    -DHDF5_BUILD_CPP_LIB=ON \
    -DHDF5_ENABLE_Z_LIB_SUPPORT=ON \
    -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
    -DHDF5_ENABLE_SZIP_ENCODING=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
    -DCMAKE_INSTALL_PREFIX=../install_universal_static
cmake --build . --parallel ${NUM_CORES}
cmake --install .
cd ..

# HDF5's exported targets reference ZLIB::ZLIB, but the upstream package
# configuration skips its bundled zlib target when PACKAGE_EXTLIBS is OFF.
# Load the separately built universal zlib package before importing HDF5
# targets so every downstream project receives the complete dependency graph.
python3 - "install_universal_static/cmake/hdf5-config.cmake" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1])
contents = config.read_text(encoding="utf-8")
marker = 'if (NOT TARGET "hdf5")'
bootstrap = '''if (HDF5_ENABLE_Z_LIB_SUPPORT AND NOT TARGET ZLIB::ZLIB)
  include("${CMAKE_CURRENT_LIST_DIR}/../../../zlib-${ZLIB_VERSION:-1.3.1}/build_universal/share/cmake/zlib/zlib-config.cmake")
endif ()

'''
if 'build_universal/share/cmake/zlib/zlib-config.cmake' not in contents:
    if marker not in contents:
        raise SystemExit(f"Could not locate HDF5 target import point in {config}")
    config.write_text(contents.replace(marker, bootstrap + marker, 1), encoding="utf-8")
PY

# Generate fully compliant CMake package for static HDF5
mkdir -p install_universal_static/share/cmake/hdf5

cat > install_universal_static/share/cmake/hdf5/hdf5-targets.cmake <<'EOL'
# Imported targets
if(NOT TARGET hdf5::hdf5-static)
  add_library(hdf5::hdf5-static STATIC IMPORTED)
  set_target_properties(hdf5::hdf5-static PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "\${CMAKE_CURRENT_LIST_DIR}/../../../include"
    IMPORTED_LOCATION "\${CMAKE_CURRENT_LIST_DIR}/../../lib/libhdf5.a"
  )
endif()

if(NOT TARGET hdf5::hdf5_cpp-static)
  add_library(hdf5::hdf5_cpp-static STATIC IMPORTED)
  set_target_properties(hdf5::hdf5_cpp-static PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "\${CMAKE_CURRENT_LIST_DIR}/../../../include"
    IMPORTED_LOCATION "\${CMAKE_CURRENT_LIST_DIR}/../../lib/libhdf5_cpp.a"
    INTERFACE_LINK_LIBRARIES "hdf5::hdf5-static"
  )
endif()

if(NOT TARGET hdf5::hdf5_hl-static)
  add_library(hdf5::hdf5_hl-static STATIC IMPORTED)
  set_target_properties(hdf5::hdf5_hl-static PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "\${CMAKE_CURRENT_LIST_DIR}/../../../include"
    IMPORTED_LOCATION "\${CMAKE_CURRENT_LIST_DIR}/../../lib/libhdf5_hl.a"
    INTERFACE_LINK_LIBRARIES "hdf5::hdf5-static"
  )
endif()

if(NOT TARGET hdf5::hdf5_hl_cpp-static)
  add_library(hdf5::hdf5_hl_cpp-static STATIC IMPORTED)
  set_target_properties(hdf5::hdf5_hl_cpp-static PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "\${CMAKE_CURRENT_LIST_DIR}/../../../include"
    IMPORTED_LOCATION "\${CMAKE_CURRENT_LIST_DIR}/../../lib/libhdf5_hl_cpp.a"
    INTERFACE_LINK_LIBRARIES "hdf5::hdf5_cpp-static;hdf5::hdf5_hl-static"
  )
endif()
EOL

cat > install_universal_static/share/cmake/hdf5/hdf5-config.cmake <<EOL
set(hdf5_FOUND TRUE)
set(HDF5_FOUND TRUE)
set(hdf5_VERSION "${HDF5_VERSION}")
set(HDF5_VERSION "${HDF5_VERSION}")
set(hdf5_INCLUDE_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(HDF5_INCLUDE_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(hdf5_LIBRARY_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../lib")
set(HDF5_LIBRARY_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../lib")

include("\${CMAKE_CURRENT_LIST_DIR}/hdf5-targets.cmake")

set(hdf5_LIBRARIES hdf5::hdf5-static)
set(hdf5_HL_LIBRARIES hdf5::hdf5_hl-static)
set(hdf5_CXX_LIBRARIES hdf5::hdf5_cpp-static)
set(hdf5_CXX_HL_LIBRARIES hdf5::hdf5_hl_cpp-static)
EOL

cat > install_universal_static/share/cmake/hdf5/hdf5-config-version.cmake <<EOL
set(PACKAGE_VERSION "${HDF5_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOL

echo "✅ HDF5 universal static libraries built with CMake targets."

cd ..
if [ ! -L "hdf5" ]; then
    ln -sf "${HDF5_DIR_NAME}" hdf5
fi

echo ""
echo "HDF5 and zlib static builds complete."
echo "HDF5 static CMake package: ${LIBRARIES_ROOT}/${HDF5_DIR_NAME}/install_universal_static/share/cmake/hdf5"
echo "zlib static CMake package: ${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION}/build_universal/share/cmake/zlib"
