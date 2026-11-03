#!/bin/bash
# Shared locations for the locally built libraries consumed by project stages.
: "${OPENMP_VERSION:=21.1.2}"
: "${HDF5_VERSION:=1.14.6}"
: "${ZLIB_VERSION:=1.3.1}"
: "${CUPS_VERSION:=2.4.14}"

: "${OPENMP_BUILD_DIR:=$LIBRARIES_ROOT/openmp-${OPENMP_VERSION}/build_universal}"
: "${HDF5_INSTALL_DIR:=$LIBRARIES_ROOT/hdf5-${HDF5_VERSION}/install_universal_static}"
: "${HDF5_CMAKE_DIR:=$HDF5_INSTALL_DIR/share/cmake/hdf5}"
: "${HDF5_COMPAT_CMAKE_DIR:=$HDF5_INSTALL_DIR/cmake}"
: "${HDF5_LIB_DIR:=$HDF5_INSTALL_DIR/lib}"
: "${ZLIB_ROOT:=$LIBRARIES_ROOT/zlib-${ZLIB_VERSION}/build_universal}"
: "${ZLIB_DIR:=$ZLIB_ROOT/share/cmake/zlib}"
: "${CUPS_BUILD_DIR:=$LIBRARIES_ROOT/cups-${CUPS_VERSION}/build_universal}"
: "${CUPS_CMAKE_DIR:=$CUPS_BUILD_DIR/lib/cmake/CUPS}"

export OPENMP_VERSION OPENMP_BUILD_DIR HDF5_VERSION HDF5_INSTALL_DIR HDF5_CMAKE_DIR
export HDF5_COMPAT_CMAKE_DIR HDF5_LIB_DIR ZLIB_VERSION ZLIB_ROOT ZLIB_DIR CUPS_VERSION CUPS_BUILD_DIR CUPS_CMAKE_DIR
