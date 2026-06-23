# Wiki Card — reading summary (on device)

**Wiki Card (AI)** builds a reading note from your highlight: the **term on the front**, a **Wikipedia-style article** on the back, plus **real Wikipedia links** to explore further.

Anki note type name: **Wiki Card**

## Fields (exact names)

| Order | Field |
|-------|-------|
| 1 | Phrase |
| 2 | Text |
| 3 | Links |
| 4 | Source |
| 5 | Definition *(optional lede)* |
| 6 | IPA *(optional)* |
| 7 | Synonyms *(legacy; usually empty)* |

**Phrase** = front (highlighted term only). **Text** = encyclopedia article. **Links** = clickable Wikipedia URLs (filled by the plugin). **Source** = book citation.

## Deck

Default: **English::Koreader** (with subdeck-by-book ON → `English::Koreader::Book Title`).

## Plugin settings

- Note type: **Wiki Card**
- Deck: **English::Koreader**
- Requires AI API key and Wi‑Fi for generation
- **Wiki sources** should be ON (**AnkiKOAi → Settings → AI Settings**)

## Templates and CSS

On your computer, open **docs/desktop/wiki-card-anki-templates.txt** and add the **Links** field if your note type is older. Copy each block into Anki → Tools → Manage Note Types → Wiki Card → Cards.

Full walkthrough: **docs/anki-vocabulary.md**
