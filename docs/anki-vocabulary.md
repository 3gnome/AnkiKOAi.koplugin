# Anki: Wiki Card setup

> **On your e-reader:** Tap **View README** in the Wiki Card submenu for a short summary (`docs/in-app/wiki-card.md`).  
> **Copy-paste on your computer:** Anki front/back templates and CSS are in **`docs/desktop/wiki-card-anki-templates.txt`** — open in any text editor and paste into Anki’s note-type editor.

**Wiki Card (AI)** is the menu label in AnkiKOAi. In Anki, create a note type named **Wiki Card** with the fields below — the plugin sends data to those exact names via AnkiConnect.

A Wiki Card is **not** a traditional question→answer flashcard. Highlight a term while reading; the **front** shows that term only. The **back** is a Wikipedia-style article, real Wikipedia links to explore further, and your book citation.

Set up the **Wiki Card** note type and **English::Koreader** deck (or your own names — but they must match the plugin settings).

> **Legacy names:** If you already have note types named **Information card** or **Vocabulary**, the plugin still recognizes them. New setups should use **Wiki Card** with the field order below. If upgrading an older note type, add the **Links** field.

## 1. Create the note type

1. Anki → **Tools → Manage Note Types → Add → Add: Basic**
2. Rename the note type to exactly: **Wiki Card**
3. Open **Fields** — delete `Front` and `Back`, then add fields **in this order**:

   | Order | Field name | Purpose |
   |-------|------------|---------|
   | 1 | Phrase | Highlighted term (front of card) |
   | 2 | Text | Wikipedia-style article (back) |
   | 3 | Links | HTML list of real Wikipedia URLs (filled by plugin) |
   | 4 | Source | Book title, author, page (filled by plugin) |
   | 5 | Definition | Optional short lede (AI may fill) |
   | 6 | IPA | Optional pronunciation hint |
   | 7 | Synonyms | Legacy; usually empty |

4. **Cards** — keep a single card type (Card 1).

## 2. Front template

Copy from **`docs/desktop/wiki-card-anki-templates.txt`** (Part 2) on your computer, or use:

```html
{{#Phrase}}
<div class="info-card info-card--front">
  <div class="phrase">{{Phrase}}</div>
  <div class="prompt">Recall the topic.</div>
</div>
{{/Phrase}}
```

**Study experience:** term only on the front — no IPA, no definition peek.

## 3. Back template

Copy from **`docs/desktop/wiki-card-anki-templates.txt`** (Part 3), or use:

```html
{{#Phrase}}
<div class="info-card info-card--back">
  <div class="phrase phrase--back">{{Phrase}}</div>

  {{#Definition}}
  <div class="section">
    <div class="section-body lede">{{Definition}}</div>
  </div>
  {{/Definition}}

  {{#Text}}
  <div class="section">
    <div class="section-label">Article</div>
    <div class="section-body article">{{Text}}</div>
  </div>
  {{/Text}}

  {{#Links}}
  <div class="section">
    <div class="section-label">Explore further</div>
    <div class="section-body links">{{Links}}</div>
  </div>
  {{/Links}}

  {{#Source}}<div class="source">{{Source}}</div>{{/Source}}
</div>
{{/Phrase}}
```

## 4. Styling

Paste into **Cards → Styling** (shared by front and back). Full CSS is in **`docs/desktop/wiki-card-anki-templates.txt`** (Part 4). Minimum set:

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

.info-card--front {
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

.section { margin: 0.75em 0; }

.section-label {
  font-size: 0.75em;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: #555;
  margin-bottom: 0.25em;
}

.section-body { text-align: left; }

.lede {
  font-size: 1.05em;
  font-weight: 600;
  margin-bottom: 0.5em;
}

.article { font-size: 0.98em; }

.links a {
  color: #0066cc;
  text-decoration: none;
}

.links a:hover { text-decoration: underline; }

.source {
  font-size: 0.8em;
  color: #666;
  margin-top: 1.5em;
  border-top: 1px solid #ddd;
  padding-top: 0.5em;
}
```

## 5. Deck

Create a deck named **English::Koreader** (or your preferred parent deck). With **Subdeck by book title** ON in plugin settings, cards go to `English::Koreader::Book Title`.

## 6. Deck options preset

Create a preset named **Wiki Card** and apply it to `English::Koreader` and subdecks.

Suggested values for AI-rich reading notes (adjust to taste):

| Setting | Suggested |
|---------|-----------|
| New cards/day | 20–40 |
| Maximum reviews/day | 200 |
| Learning steps | `1m 10m 1d` |
| Graduating interval | 3 days |
| Easy interval | 7 days |
| Starting ease | 250% |
| Lapse steps | `10m` |
| Leech threshold | 8 |
| Bury related new/siblings | OFF |

Wiki Cards are content-heavy — higher daily limits than memorization step cards are usually fine.

## 7. Plugin settings (must match Anki)

| Setting | Default | Notes |
|---------|---------|-------|
| Note type | Wiki Card | Must match Anki note type name |
| Deck | English::Koreader | Must exist or AnkiConnect creates it |
| Tags | KOReader | Comma-separated in Settings |
| Subdeck by book title | ON | `Parent::Book Title` |
| Wiki sources for AI | ON | Wikipedia/Wiktionary excerpts ground the article |
| Sync to AnkiWeb after send | ON | Requires AnkiWeb account on desktop |
| Send to Anki after generate | OFF | When ON, skips manual review step |

In `configuration.lua`:

```lua
anki = {
    url   = "http://192.168.1.100:8765",
    deck  = "English::Koreader",
    model = "Wiki Card",
    tags  = { "KOReader" },
    sync_after_send = true,
},
```

## 8. What the plugin sends

| Field | Content |
|-------|---------|
| Phrase | Highlighted term (canonical form from AI) |
| Text | Wikipedia-style encyclopedia article |
| Links | HTML list of real Wikipedia URLs (plugin fills after generation) |
| Source | Book title, author, page/chapter (from KOReader metadata) |
| Definition | Optional short lede when the AI provides one |
| IPA | Pronunciation hint when available |
| Synonyms | Usually empty (legacy field) |

The **Links** and **Source** fields are filled by the plugin — the AI is instructed to leave them empty.

## 9. Custom note types

The plugin also supports **Basic** (Front/Back) and arbitrary note types via generic AI prompts. Pick the note type before generating; field names must exist on the Anki model. For most users, **Wiki Card** is the intended layout.

See [Plugin configuration](plugin-configuration.md) for custom prompts and provider options.

## Related

- **Vocabulary Card (No AI)** — dictionary-only cards: [anki-vocabulary-card.md](anki-vocabulary-card.md)
- **Memorization Card (No AI, Multi-Line)** — [anki-memorization.md](anki-memorization.md)
