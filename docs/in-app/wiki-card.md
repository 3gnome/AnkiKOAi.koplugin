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
| 5 | Definition *(reader's highlight — copied verbatim)* |
| 6 | IPA *(optional)* |
| 7 | Synonyms *(legacy; usually empty)* |

**Phrase** = front (short label, often the key term). **Definition** = the reader's exact highlight (shown on the back). **Text** = AI exploration of the subject (no book recap). **Links** = clickable Wikipedia URLs (filled by the plugin). **Source** = book citation.

## Deck

Set under **Card defaults → Wiki Card → Default deck** (pick from Anki). With **Send routing → Subdeck by book title** ON, cards go to `YourDeck::Book Title`.

## Plugin settings

Configure under **AnkiKOAi → Settings → Card defaults → Wiki Card**:

- **Note type** — pick from Anki (default: Wiki Card)
- **Default deck** — pick from Anki
- **One-tap send (Wiki)** — skip note-type, deck, and review prompts; sends to your default deck
- Requires AI API key and Wi‑Fi for generation
- **Wiki sources** should be ON (**Settings → AI Settings**)

Send-time options (subdeck by book, per-book overrides): **Card defaults → Send routing**.

## Templates and CSS

On your computer, open **docs/desktop/wiki-card-anki-templates.txt** and add the **Links** field if your note type is older. Copy each block into Anki → Tools → Manage Note Types → Wiki Card → Cards.

Full walkthrough: **docs/anki-vocabulary.md**
