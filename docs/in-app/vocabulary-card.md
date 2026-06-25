# Vocabulary Card — reading summary (on device)

**Vocabulary Card (No AI)** uses KOReader StarDict dictionaries only — no AI, no Wikipedia.

Anki note type name: **Vocabulary Card**

Install at least one dictionary in KOReader before using this flow.

## Fields (exact names)

| Order | Field |
|-------|-------|
| 1 | Phrase |
| 2 | Definition |
| 3 | Context |
| 4 | Source |

## Deck

Set under **Card defaults → Vocabulary Card → Default deck** (pick from Anki; can differ from Wiki). **Send routing → Subdeck by book title** works the same way as Wiki Card.

## Plugin settings

Configure under **AnkiKOAi → Settings → Card defaults → Vocabulary Card**:

- **Note type** — pick from Anki (default: Vocabulary Card)
- **Default deck** — pick from Anki
- **Preferred dictionary** — StarDict name, or leave empty to pick each time
- **One-tap send (Vocabulary)** — skip prompts and send to your default deck
- No API key required

## Templates and CSS

Templates and CSS are not shown on device. On your computer, open **docs/desktop/vocabulary-card-anki-templates.txt** in a text editor. Copy each labeled block into Anki → Tools → Manage Note Types → Vocabulary Card → Cards.

Full guide: **docs/anki-vocabulary-card.md**
