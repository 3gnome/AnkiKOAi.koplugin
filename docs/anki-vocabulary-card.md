# Anki: Vocabulary Card setup (dictionary-only, no AI)

> **On your e-reader:** Tap **View README** in the Vocabulary Card submenu for a short summary (`docs/in-app/vocabulary-card.md`).  
> **Copy-paste on your computer:** Anki front/back templates and CSS are in **`docs/desktop/vocabulary-card-anki-templates.txt`** — open in any text editor and paste into Anki’s note-type editor.

**Vocabulary Card (No AI)** is the menu label in AnkiKOAi. In Anki, create a note type named **Vocabulary Card** with the fields below — the plugin sends data to those exact names via AnkiConnect.

This flow uses **KOReader's installed StarDict dictionaries only**. It does not call AI, Wikipedia, or Wiktionary. Install at least one dictionary in KOReader (Search → Dictionary support in the KOReader wiki) before using this button.

## 1. Create the note type

1. Anki → **Tools → Manage Note Types → Add → Add: Basic**
2. Rename the note type to exactly: **Vocabulary Card**
3. Open **Fields** — delete `Front` and `Back`, then add fields **in this order**:

   | Order | Field name |
   |-------|------------|
   | 1 | Phrase |
   | 2 | Definition |
   | 3 | Context |
   | 4 | Source |

4. **Cards** — keep a single card type (Card 1).

## 2. Front template

Copy from **`docs/desktop/vocabulary-card-anki-templates.txt`** (Part 2) on your computer, or use:

```html
{{#Phrase}}
<div class="vocab-card vocab-card--front">
  <div class="phrase">{{Phrase}}</div>
  <div class="prompt">Recall the definition.</div>
</div>
{{/Phrase}}
```

## 3. Back template

```html
{{#Phrase}}
<div class="vocab-card vocab-card--back">
  <div class="phrase phrase--back">{{Phrase}}</div>

  {{#Definition}}
  <div class="section">
    <div class="section-label">Definition</div>
    <div class="section-body">{{Definition}}</div>
  </div>
  {{/Definition}}

  {{#Context}}
  <div class="section">
    <div class="section-label">Passage</div>
    <div class="section-body context">{{Context}}</div>
  </div>
  {{/Context}}

  {{#Source}}<div class="source">{{Source}}</div>{{/Source}}
</div>
{{/Phrase}}
```

## 4. Styling

Paste into **Cards → Styling**:

```css
.card {
  font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif;
  font-size: 18px;
  line-height: 1.45;
  color: #222;
  max-width: 42em;
  margin: 0 auto;
  padding: 0.5em 1em;
}

.vocab-card--front {
  text-align: center;
  padding-top: 2em;
}

.phrase {
  font-size: 1.6em;
  font-weight: 700;
  color: #003a75;
  margin-bottom: 0.4em;
}

.phrase--back {
  font-size: 1.15em;
  text-align: left;
  border-bottom: 1px solid #ccc;
  padding-bottom: 0.5em;
  margin-bottom: 0.75em;
}

.prompt {
  font-size: 0.85em;
  color: #666;
  margin-top: 2em;
}

.section {
  margin: 0.75em 0;
}

.section-label {
  font-size: 0.75em;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: #555;
  margin-bottom: 0.25em;
}

.section-body {
  text-align: left;
}

.context {
  font-size: 0.95em;
  font-style: italic;
}

.source {
  font-size: 0.8em;
  color: #666;
  margin-top: 1.5em;
  border-top: 1px solid #ddd;
  padding-top: 0.5em;
}
```

## 5. Deck

Use the same vocab deck as Wiki Cards — default **English::Koreader**. Subdecks by book title work the same way.

You can use the same deck-options preset as Wiki Cards, or create a separate **Vocabulary Card** preset with similar new/review limits.

## 6. Deck options preset

Suggested values for dictionary drill cards:

| Setting | Suggested |
|---------|-----------|
| New cards/day | 30–50 |
| Maximum reviews/day | 250 |
| Learning steps | `1m 10m 1d` |
| Graduating interval | 2 days |
| Easy interval | 4 days |
| Starting ease | 250% |
| Bury related new/siblings | OFF |

Dictionary definitions are shorter than AI Wiki Cards — slightly higher daily caps are often comfortable.

## 7. Plugin settings (must match Anki)

Configure on device under **AnkiKOAi → Settings → Card defaults**:

| Setting | Default | Menu path |
|---------|---------|-----------|
| Vocabulary note type | Vocabulary Card | Card defaults → Vocabulary Card… |
| Default deck | English::Koreader | Card defaults → Vocabulary Card… |
| Preferred dictionary | (auto) | Card defaults → Vocabulary Card… |
| One-tap send (Vocabulary) | OFF | Card defaults → Vocabulary Card… |
| Subdeck by book title | ON | Card defaults → Send routing… |
| Tags | KOReader | Settings → Tags… |

**One-tap send** uses your default deck and auto-picks the preferred dictionary when set. With multiple dictionaries and no preferred name, the plugin shows the picker once.

In `configuration.lua`:

```lua
anki = {
    url   = "http://192.168.1.100:8765",
    vocabulary_deck = "English::Koreader",
    vocabulary_model = "Vocabulary Card",
    auto_send_vocabulary = false,
    vocabulary_preferred_dictionary = "",
    tags  = { "KOReader" },
},
```

## 8. What the plugin sends

| Field | Content |
|-------|---------|
| Phrase | Highlighted word or phrase (from dictionary headword when available) |
| Definition | Plain-text definition from your KOReader dictionary |
| Context | Surrounding passage from the book (~10 lines) |
| Source | Book title, author, page/chapter (from KOReader metadata) |

## 9. KOReader dictionary requirement

1. Install StarDict dictionaries in KOReader's `data/dict/` folder.
2. Enable dictionaries in **Search → Dictionary settings**.
3. Test a normal long-press lookup in the book before using **Vocabulary Card (No AI)**.

If lookup fails, the plugin shows an error — there is no AI fallback for this flow.

## Related

- **Wiki Card (AI)** — rich AI + wiki notes: [anki-vocabulary.md](anki-vocabulary.md)
- **Memorization Card (No AI, Multi-Line)** — [anki-memorization.md](anki-memorization.md)
