# The HDF5 install's share/cmake/hdf5 config was left empty by the local
# dependency recipe. Expose its generated universal static targets here.
set(hdf5_FOUND TRUE)
set(HDF5_FOUND TRUE)
set(hdf5_VERSION "1.14.6")
set(HDF5_VERSION "1.14.6")
include("$ENV{HDF5_INSTALL_DIR}/share/cmake/hdf5/hdf5-targets.cmake")
