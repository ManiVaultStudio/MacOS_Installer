#!/usr/bin/env python3
"""Enable Qt6 GuiPrivate discovery and linking on all platforms."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Enable GuiPrivate discovery on macOS as well as other Unix platforms.
old_discovery = """if(UNIX AND NOT APPLE
   AND QT_VERSION_MAJOR STREQUAL "6"
   AND QT_VERSION_MINOR GREATER_EQUAL 9)"""

new_discovery = """if(QT_VERSION_MAJOR STREQUAL "6"
   AND QT_VERSION_MINOR GREATER_EQUAL 9)"""

# Enable the private target link on macOS too.
old_link = 'if(UNIX AND NOT APPLE AND QT_VERSION_MAJOR STREQUAL "6")'
new_link = 'if(QT_VERSION_MAJOR STREQUAL "6")'

changes = 0

if old_discovery in text:
    text = text.replace(old_discovery, new_discovery)
    changes += 1

if old_link in text:
    text = text.replace(old_link, new_link)
    changes += 1

if changes:
    path.write_text(text, encoding="utf-8")
    print(f"Updated {changes} Qt6 private-target conditions in {path}.")
else:
    discovery_ok = new_discovery in text
    link_ok = new_link in text

    if discovery_ok and link_ok:
        print(f"Qt6 private-target conditions already patched in {path}.")
    else:
        raise SystemExit(
            f"Could not identify expected Qt6 private-target conditions in {path}."
        )
