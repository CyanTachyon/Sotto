#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$SOURCE_ROOT/scripts/check-compatibility.py" --self-test
swift run --build-system native --package-path "$SOURCE_ROOT" SottoChecks
swift build --build-system native --package-path "$SOURCE_ROOT" --product Sotto
CHECK_BINARY="$(swift build --build-system native --package-path "$SOURCE_ROOT" --show-bin-path)/Sotto"
SOTTO_READER_CHECK_BINARY="$CHECK_BINARY" PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$SOURCE_ROOT/Backend/test_reader.py"

PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$SOURCE_ROOT/Backend/test_media.py"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$SOURCE_ROOT/Backend/test_session_metadata.py"
