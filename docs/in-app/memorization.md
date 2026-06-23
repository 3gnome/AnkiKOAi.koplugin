# Memorization Card — reading summary (on device)

LPCG-style verbatim memorization: overlapping **step** cards plus an optional **full recitation** card per passage.

Anki note type name: **Memorization**

## Fields (exact names)

Title, Context, Target, FullText, Source, LineIndex, FullRecite

## Card types in Anki

| Card type | Purpose |
|-----------|---------|
| **Line** | Daily step cards (`memorization::step`) |
| **Full** | Whole-passage recitation (`memorization::full`) |

## Deck hierarchy

Parent deck: **Memorize** → plugin creates `Memorize::Book title::page`.

Set **Parent deck** to `Memorize` in plugin Settings → Memorization.

## Plugin settings (defaults)

- Context lines: 3
- Max words per chunk: 7
- Full recitation card: ON

## Templates and CSS

Templates and CSS are not shown on device. On your computer, open **docs/desktop/memorization-anki-templates.txt** in a text editor. Copy each labeled block into Anki → Tools → Manage Note Types → Memorization → Cards.

Full guide: **docs/anki-memorization.md**
