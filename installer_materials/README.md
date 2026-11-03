# Installer materials

Each workbook project owns a folder under `projects/<profile-id>/`. Keep its app and project JSON, application icon, DMG background, and optional folder icons together there. Point the project's `InstallerAssets` row at the files it uses.

Shared license files and splash/logo artwork live in `common/`. Project folders can override any material independently while reusing common assets. New projects created in the desktop app start as a copy of `projects/manivault-studio/`.
