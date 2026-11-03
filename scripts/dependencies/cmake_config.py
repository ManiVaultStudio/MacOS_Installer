"""Shared CMake command settings for dependency-only builds."""
from __future__ import annotations

import os
from typing import Mapping, Sequence


def configure_command(source: str, build: str, prefix: str, architectures: Sequence[str],
                     minimum_macos: str, options: Sequence[str], env: Mapping[str, str]) -> list[str]:
    return [
        "cmake", "-S", source, "-B", build,
        f"-DCMAKE_BUILD_TYPE={env.get('DEPENDENCY_BUILD_TYPE', os.environ.get('DEPENDENCY_BUILD_TYPE', 'Release'))}",
        f"-DCMAKE_INSTALL_PREFIX={prefix}",
        f"-DCMAKE_OSX_ARCHITECTURES={';'.join(architectures)}",
        f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum_macos}",
        "-DFETCHCONTENT_UPDATES_DISCONNECTED=ON",
        "-G", env.get("DEPENDENCY_CMAKE_GENERATOR", os.environ.get("DEPENDENCY_CMAKE_GENERATOR", "Ninja")),
        *options,
    ]
