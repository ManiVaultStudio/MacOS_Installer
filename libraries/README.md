# Dependency storage

Pinned dependency sources, local checkouts, build trees, and install prefixes belong here. The dependency catalog is `installer_database/dependencies.json`; `dependency_manager.py` resolves all declared artifacts relative to this directory. Generated contents are ignored by Git. The bundled HDF5 source archive is retained for offline builds.
