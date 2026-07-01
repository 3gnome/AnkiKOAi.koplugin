#!/bin/bash
# Dev-only syntax/sanity checker (not part of the plugin).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KO="${KOREADER_DIR:-$HOME/koreader-dev/emulator/usr/lib/koreader}"
SRC="${PLUGIN_DIR:-$SCRIPT_DIR}"
LJ="$KO/luajit"
fail=0

echo "=== Parse-check all .lua files (loadfile, parse only) ==="
while IFS= read -r f; do
    CHK="$f" "$LJ" -e 'local p=os.getenv("CHK"); local fn,e=loadfile(p); if not fn then io.stderr:write(tostring(e).."\n"); os.exit(1) end' 2>/tmp/_chk.err
    if [ $? -ne 0 ]; then
        echo "SYNTAX ERROR: $f"
        cat /tmp/_chk.err
        fail=1
    fi
done < <(find "$SRC" -name '*.lua' -not -path '*/.git/*')
[ "$fail" -eq 0 ] && echo "All .lua files parse OK"

echo
echo "=== Functional test: note_type_profiles ==="
cd "$SRC"
"$LJ" -e '
package.path = "./?.lua;" .. package.path
local P = require("note_type_profiles")
assert(P.is_wiki_card("Wiki Card") == true, "Wiki Card should be wiki")
assert(P.is_wiki_card("Vocabulary") == false, "Vocabulary should NOT be wiki anymore")
assert(P.is_wiki_card("Information card") == false, "Information card should NOT be wiki anymore")
assert(P.normalize_model_name("Vocabulary") == "Vocabulary", "no legacy remap")
assert(P.normalize_model_name("") == "Wiki Card", "empty -> default")
assert(P.is_vocabulary_card("Vocabulary Card") == true, "Vocabulary Card still vocab")
assert(P.is_memorization("Memorization") == true, "Memorization still works")
print("note_type_profiles: all assertions passed")
'

echo
echo "=== Functional test: plugin_constants ==="
"$LJ" -e '
package.path = "./?.lua;" .. package.path
local C = require("plugin_constants")
assert(C.PREVIOUS_CARDS_FILE == nil, "legacy constant removed")
assert(C.LEGACY_CARDS_FILE == nil, "legacy constant removed")
assert(C.CARDS_FILE == "ankikooai_cards.json", "cards file intact")
print("plugin_constants: OK")
'

echo
echo "=== Functional test: highlight_cleanup ==="
"$LJ" spec/highlight_cleanup_spec.lua || fail=1

exit $fail
