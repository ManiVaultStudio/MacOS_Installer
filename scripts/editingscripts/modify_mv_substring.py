import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


CHUNK_SIZE = 8 * 1024 * 1024  # 8 MB

TARGET_FILES = [
    "meta.json",
    "project.json",
    "workspace.json",
]


def sha256_file(path):
    """Calculate SHA-256 hash of a file."""

    h = hashlib.sha256()

    with open(path, "rb") as f:
        while True:
            chunk = f.read(CHUNK_SIZE)

            if not chunk:
                break

            h.update(chunk)

    return h.hexdigest()


def run(command, **kwargs):
    """Run a subprocess command."""

    return subprocess.run(
        command,
        check=True,
        **kwargs,
    )


def extract_file(archive, filename):
    """Extract one file from ZIP directly into memory."""

    result = subprocess.run(
        [
            "unzip",
            "-p",
            str(archive),
            filename,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )

    return result.stdout


def modify_mv_archive(
    source_path,
    replacements,
):
    source = Path(source_path)

    output = source.with_name(
        f"{source.stem}_modified{source.suffix}"
    )

    print()
    print("=" * 70)
    print("FAST MV SUBSTRING REPLACEMENT")
    print("=" * 70)

    # ============================================================
    # STEP 1: FAST COPY
    # ============================================================

    print()
    print("[1/5] Copying original archive")
    print("-" * 70)

    run(
        [
            "cp",
            "-p",
            str(source),
            str(output),
        ]
    )

    print("✓ Copy complete")

    # ============================================================
    # STEP 2: VERIFY COPY
    # ============================================================

    print()
    print("[2/5] Verifying copy")
    print("-" * 70)

    source_hash = sha256_file(source)
    output_hash = sha256_file(output)

    if source_hash != output_hash:
        raise RuntimeError(
            "ERROR: The copied archive does not match "
            "the original."
        )

    print("✓ Original and copy are byte-for-byte identical")
    print(f"✓ SHA-256: {source_hash}")

    # ============================================================
    # STEP 3: MODIFY ONLY THE THREE JSON FILES
    # ============================================================

    print()
    print("[3/5] Searching and replacing")
    print("-" * 70)

    modified_files = []
    total_replacements = 0

    with tempfile.TemporaryDirectory() as temp_dir:

        temp_dir = Path(temp_dir)

        for filename in TARGET_FILES:

            print()
            print(f"Processing: {filename}")

            # Extract ONLY this JSON file.
            data = extract_file(
                source,
                filename,
            )

            original_data = data

            file_count = 0

            # Perform byte-level replacements.
            for old, new in replacements.items():

                old_bytes = old.encode("utf-8")
                new_bytes = new.encode("utf-8")

                count = data.count(
                    old_bytes
                )

                if count > 0:

                    print(
                        f"  Found {count} occurrence(s): "
                        f"{old} → {new}"
                    )

                    data = data.replace(
                        old_bytes,
                        new_bytes,
                    )

                    file_count += count

            if data != original_data:

                modified_files.append(
                    filename
                )

                total_replacements += (
                    file_count
                )

                # Preserve the filename exactly.
                destination = (
                    temp_dir / filename
                )

                destination.write_bytes(
                    data
                )

                print(
                    f"  ✓ Modified "
                    f"{file_count} occurrence(s)"
                )

            else:

                print(
                    "  No changes needed"
                )

        print()
        print(
            f"Total replacements: "
            f"{total_replacements}"
        )

        # --------------------------------------------------------
        # Safety check
        # --------------------------------------------------------

        if total_replacements == 0:

            raise RuntimeError(
                "ERROR: No replacements were made. "
                "Aborting without modifying output."
            )

        # ========================================================
        # STEP 4: UPDATE ONLY MODIFIED FILES
        # ========================================================

        print()
        print("[4/5] Updating archive")
        print("-" * 70)

        print(
            "Updating:",
            ", ".join(modified_files),
        )

        run(
            [
                "zip",
                "-q",
                "-u",
                str(output),
                *modified_files,
            ],
            cwd=temp_dir,
        )

        print(
            "✓ Archive update complete"
        )

    # ============================================================
    # STEP 5: VERIFY
    # ============================================================

    print()
    print("[5/5] Verifying result")
    print("-" * 70)

    # ------------------------------------------------------------
    # ZIP integrity
    # ------------------------------------------------------------

    print(
        "Checking ZIP integrity..."
    )

    run(
        [
            "unzip",
            "-t",
            str(output),
        ],
        stdout=subprocess.DEVNULL,
    )

    print(
        "✓ ZIP integrity check passed"
    )

    # ------------------------------------------------------------
    # Verify replacements
    # ------------------------------------------------------------

    print()
    print(
        "Verifying replacements..."
    )

    for filename in modified_files:

        data = extract_file(
            output,
            filename,
        )

        for old, new in replacements.items():

            old_bytes = old.encode(
                "utf-8"
            )

            new_bytes = new.encode(
                "utf-8"
            )

            remaining = data.count(
                old_bytes
            )

            replaced = data.count(
                new_bytes
            )

            if remaining > 0:

                raise RuntimeError(
                    f"Verification failed: "
                    f"{filename} still contains "
                    f"{remaining} occurrence(s) "
                    f"of '{old}'."
                )

            print(
                f"✓ {filename}: "
                f"'{old}' completely replaced"
            )

    # ------------------------------------------------------------
    # Final output
    # ------------------------------------------------------------

    print()
    print("=" * 70)
    print("SUCCESS")
    print("=" * 70)

    print(
        f"Files modified: "
        f"{len(modified_files)}"
    )

    print(
        f"Total replacements: "
        f"{total_replacements}"
    )

    print(
        f"Output file:"
    )

    print(
        output
    )

    print()
    print(
        "Original archive was NOT modified."
    )

    return output


if __name__ == "__main__":

    target_mv = (
        "/Applications/Cytosplore Viewer Master/Downloads/Projects/EvoViewerSubsetProject.mv"
    )

    replacements = {
        "CrossSpeciesComparison": "XSC",
        "No data available or insufficient data for chart.": "Select cells in the scatterplot to begin exploration.",
    }

    modify_mv_archive(
        target_mv,
        replacements,
    )