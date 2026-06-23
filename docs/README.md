# Documentation

Guides for setting up Anki decks that match this plugin, configuring KOReader, and studying effectively.

## Start here

| Guide | What it covers |
|-------|----------------|
| [Getting started](getting-started.md) | Install plugin → set up Anki → first card in ~15 minutes |
| [Plugin configuration](plugin-configuration.md) | API keys, AnkiConnect, decks, AI providers, memorization tuning |
| [Anki: Wiki Card setup](anki-vocabulary.md) | **Wiki Card** note type (AI + wiki), templates, CSS, deck options |
| [Anki: Vocabulary Card setup](anki-vocabulary-card.md) | **Vocabulary Card** note type (dictionary only, no AI) |
| [Anki: Memorization deck](anki-memorization.md) | **Memorization** note type, step/full cards, filtered deck, study routine |
| [Publishing & discoverability](publishing.md) | GitHub setup, descriptions, topics, releases, AppStore |

## Copy-paste reference (use on your computer)

Open these in **Notepad, VS Code, or any text editor** on your PC and paste directly into Anki’s note-type editor (Cards tab):

| File | Use for |
|------|---------|
| [docs/desktop/wiki-card-anki-templates.txt](desktop/wiki-card-anki-templates.txt) | Wiki Card front/back + CSS |
| [docs/desktop/vocabulary-card-anki-templates.txt](desktop/vocabulary-card-anki-templates.txt) | Vocabulary Card front/back + CSS |
| [docs/desktop/memorization-anki-templates.txt](desktop/memorization-anki-templates.txt) | Memorization Line/Full templates + CSS |
| [anki-memorization-setup.txt](../anki-memorization-setup.txt) | Same as memorization desktop file (plugin root) |

**On your e-reader**, tap **View README** in each card submenu for what that card type does (fields, decks, settings). Copy templates and CSS on your computer from the desktop `.txt` files above — not from the e-reader screen. Full Markdown guides (deck options, study routine, etc.) remain in the `docs/*.md` files above.

## In-app vs desktop docs

| On device (plugin) | On computer (copy-paste) | Full formatted guide |
|--------------------|--------------------------|----------------------|
| `docs/in-app/wiki-card.md` | `docs/desktop/wiki-card-anki-templates.txt` | [anki-vocabulary.md](anki-vocabulary.md) |
| `docs/in-app/vocabulary-card.md` | `docs/desktop/vocabulary-card-anki-templates.txt` | [anki-vocabulary-card.md](anki-vocabulary-card.md) |
| `docs/in-app/memorization.md` | `docs/desktop/memorization-anki-templates.txt` | [anki-memorization.md](anki-memorization.md) |

## Three Anki workflows

This plugin supports three separate flows:

1. **Wiki Card (AI)** — highlight a word or phrase → AI + Wikipedia/Wiktionary build a reading note (term on front, article + explore links on back) → send to your vocab deck (default `English::Koreader`). Anki note type: **Wiki Card**.
2. **Vocabulary Card (No AI)** — highlight a word → KOReader dictionary lookup → send a simpler note with definition + passage. Anki note type: **Vocabulary Card**. No API key required for this flow.
3. **Memorization Card (No AI, Multi-Line)** — highlight a poem or passage → plugin builds overlapping step cards plus an optional full-recitation card → send to `Memorize::Book::location` subdecks.

Each flow needs its **own Anki note type**. Wiki Card and Vocabulary Card can share the same deck; Memorization uses a separate deck hierarchy and deck-options preset.

## Field names must match

AnkiConnect sends data using exact field names. Renaming fields in Anki without updating the plugin will break sends.

| Menu label | Anki note type | Required fields |
|------------|----------------|-----------------|
| Wiki Card (AI) | Wiki Card | `Phrase`, `Text`, `Links`, `Source`, `Definition`, `IPA`, `Synonyms` |
| Vocabulary Card (No AI) | Vocabulary Card | `Phrase`, `Definition`, `Context`, `Source` |
| Memorization Card (No AI, Multi-Line) | Memorization | `Title`, `Context`, `Target`, `FullText`, `Source`, `LineIndex`, `FullRecite` |

**Legacy Wiki Card names:** **Information card** and **Vocabulary** are still recognized. If upgrading, add the **Links** field and update templates from `docs/desktop/wiki-card-anki-templates.txt`.
