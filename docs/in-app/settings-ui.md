# Settings — on-device help

Open from **AnkiKOAi → Settings**. Gray rows are informational — **tap any for details**. The menu subtitle reminds you: *Tap gray rows for help.*

For the full reference on your computer, see **docs/plugin-configuration.md**.

## Main Settings

| Submenu | Purpose |
|---------|---------|
| **Card defaults…** | Note types, default decks, one-tap send, **Where cards go**, **Deck picker shortcuts** |
| **Anki connection…** | AnkiConnect URL, sync after send, test connection |
| **Tags…** | Enable tags and edit the tag list sent with cards |
| **Memorization options…** | Split/context/batch behavior (not deck routing) |
| **AI Settings** | Wiki Card (AI) provider, keys, accuracy, language, prompts |
| **Sync…** | Background send when WiFi is on (every 20 min), cloud backup |

## View All Highlights

Open from the **highlight menu** or **AnkiKOAi hub** (not under Settings). Shows every highlight in the open book: select rows, **Delete Selected Highlights**, or batch-send as Wiki / Vocabulary / Memorization. Same checklist as **Highlights and Cards → Highlights to Anki**.

Tap **View settings guide** on the main screen to reopen this document.

## Card defaults — hub menu labels

Under **Card defaults → Wiki Card** or **Vocabulary Card**, **Hub menu label** renames the entry in the AnkiKOAi highlight hub and in Highlights batch mode. Leave empty for the built-in default (`Wiki Card (AI)` / `Vocabulary Card (No AI)`).

This does **not** change the long-press **Create Vocab Card** button in the dictionary popup.

Wiki/Vocabulary/Memorization hub submenus include **← Back** to return to the AnkiKOAi hub.

## Where cards go (Wiki & Vocabulary)

Automatic deck routing when cards are saved or sent:

1. Card-type default deck (**Wiki Card** or **Vocabulary Card**)
2. **Book override** for matching `book_title`, if set
3. **Append book title to deck name** — when ON, adds `::Book Title` to the parent deck segment

Gray preview rows show the resolved deck for the open book. **Memorization** uses **Card defaults → Memorization Card** instead — not this screen.

## Deck picker shortcuts

**Favorite decks** and **Recent** decks appear at the top when you **manually choose a deck** at send time. They do not change automatic routing or one-tap send.

Recent decks (last 5) are saved automatically when you send from the card viewer.

## Tags

When **Tags on new cards** is OFF, no tags are sent to Anki. When ON, the comma-separated tag list is applied on every AnkiConnect send (default: `KOReader`).

## AI Settings

Applies to **Wiki Card (AI)** only — not Vocabulary or Memorization.

| Setting | Effect |
|---------|--------|
| **Provider / API Keys** | Which LLM service generates Wiki cards |
| **Wiki sources** | ON: Wiktionary/Wikipedia excerpts + wiki accuracy rules. OFF: passage-only rules |
| **Strict accuracy** | ON: AI must write exactly "Unclear from context" when not confident; never guess |
| **Target language** | Language for generated definitions and notes |
| **Prompts & suffix** | Custom prompts and suffix (separate submenu) |

Tap the gray **About …** rows on the AI Settings screen for current ON/OFF details.

## Prompts & suffix

Open from **AI Settings → Prompts & suffix**. Gray rows are informational — **tap gray rows for help.** Edits are **drafts** until **Save**.

Prompts always apply to your **Wiki Card note type** from **Card defaults → Wiki Card** (gray **Note type:** row). Change the note type there — custom prompts migrate when possible.

| Action | Purpose |
|--------|---------|
| **View default generate/regen prompt** | Built-in template only (no custom override) |
| **Modify generate/regen prompt…** | Edit your custom template |
| **Preview effective generate/regen prompt** | Full prompt as sent (custom + suffix + accuracy rules) |
| **Modify prompt suffix…** | Extra instructions appended to every AI prompt |
| **Reset / Restore defaults** | Clear one prompt or all custom prompts + suffix |
| **← Back** | Returns to AI Settings (discard confirm if unsaved) |

Tap **View README** in that submenu for more detail (`docs/in-app/prompts-and-suffix.md`).
