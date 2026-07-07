#!/bin/bash
# Add a second dev book (Wizard of Oz) with sidecar highlights for View All Highlights testing.
#   bash /mnt/c/Users/small/AnkiKOAi.koplugin/scripts/setup_second_book.sh

set -euo pipefail

REPO="/mnt/c/Users/small/AnkiKOAi.koplugin"
EMU="$HOME/koreader-dev/emulator/usr/lib/koreader"
BOOK="wizard-of-oz.epub"
PATH_EPUB="$REPO/$BOOK"

echo "=== Download $BOOK ==="
curl -Lf -o "$PATH_EPUB" "https://www.gutenberg.org/ebooks/55.epub.noimages"
ls -la "$PATH_EPUB"

echo "=== Create sidecar with sample highlights ==="
SDR="$REPO/wizard-of-oz.sdr"
mkdir -p "$SDR"
cat > "$SDR/metadata.epub.lua" <<'LUA'
-- /mnt/c/Users/small/AnkiKOAi.koplugin/wizard-of-oz.sdr/metadata.epub.lua
return {
    ["annotations"] = {
        [1] = {
            ["chapter"] = "Chapter I. The Cyclone",
            ["color"] = "yellow",
            ["datetime"] = "2026-07-07 10:00:00",
            ["drawer"] = "lighten",
            ["page"] = "/body/div/p[1]/text().1",
            ["pageno"] = 1,
            ["pos0"] = "/body/div/p[1]/text().1",
            ["pos1"] = "/body/div/p[1]/text().120",
            ["text"] = "Dorothy lived in the midst of the great Kansas prairies, with Uncle Henry, who was a farmer, and Aunt Em, who was the farmer's wife.",
        },
        [2] = {
            ["chapter"] = "Chapter I. The Cyclone",
            ["color"] = "yellow",
            ["datetime"] = "2026-07-07 10:01:00",
            ["drawer"] = "lighten",
            ["page"] = "/body/div/p[2]/text().1",
            ["pageno"] = 1,
            ["pos0"] = "/body/div/p[2]/text().1",
            ["pos1"] = "/body/div/p[2]/text().80",
            ["text"] = "Their house was small, for the lumber to build it had to be carried by wagon many miles.",
        },
    },
    ["doc_path"] = "/mnt/c/Users/small/AnkiKOAi.koplugin/wizard-of-oz.epub",
    ["doc_props"] = {
        ["authors"] = "L. Frank Baum",
        ["title"] = "The Wonderful Wizard of Oz",
        ["series"] = "",
    },
}
LUA

echo "=== Update emulator history.lua ==="
HIST="$EMU/history.lua"
python3 - "$HIST" "$PATH_EPUB" <<'PY'
import re, sys, time
hist_path, book_path = sys.argv[1], sys.argv[2]
text = open(hist_path, encoding="utf-8").read()
if book_path in text:
    print("  Already in history")
    sys.exit(0)
now = int(time.time())
new_entry = (
    f"    [1] = {{\n"
    f'        ["time"] = {now},\n'
    f'        ["file"] = "{book_path}",\n'
    f'        ["text"] = "The Wonderful Wizard of Oz",\n'
    f'        ["select_enabled"] = true,\n'
    f"    }},\n"
)

def renum(m):
    return f"    [{int(m.group(1)) + 1}] ="

text = re.sub(r"    \[(\d+)\] =", renum, text)
text = text.replace("return {", "return {\n" + new_entry, 1)
open(hist_path, "w", encoding="utf-8").write(text)
print("  Added to history.lua")
PY

echo "=== Done ==="
echo "Books ready:"
echo "  $REPO/alice.epub"
echo "  $PATH_EPUB"
echo "Launch: bash dev-start.sh --emulator alice.epub"
