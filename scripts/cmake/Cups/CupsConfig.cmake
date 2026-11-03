# Qt 6 requests Cups::Cups, while the locally built CUPS package exports
# CUPS::CUPS. Adapt the target name at package discovery time.
find_package(CUPS CONFIG REQUIRED PATHS "$ENV{CUPS_CMAKE_DIR}" NO_DEFAULT_PATH)

if(TARGET CUPS::CUPS AND NOT TARGET Cups::Cups)
    add_library(Cups::Cups ALIAS CUPS::CUPS)
endif()

set(Cups_FOUND TRUE)
set(Cups_VERSION "${CUPS_VERSION}")
