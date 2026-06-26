# Plugin configuration

How to connect the plugin to AI providers, AnkiConnect, and your decks.

## Two places settings live

| Source | When to use |
|--------|-------------|
| **`configuration.lua`** | Initial setup on PC; version-control a **sample** only (`configuration.lua.sample`) |
| **On-device Settings UI** | Kobo/Kindle — saved to `ankikooai_settings.json` in KOReader’s data dir |

On-device settings **override** `configuration.lua` for Anki and API keys after you save them once.

`configuration.lua` is gitignored — never commit API keys or LAN URLs.

### Create local config

```bash
cp configuration.lua.sample configuration.lua
```

Edit keys and URLs, then copy the plugin folder to the device.

---

## Settings UI map

Open from **AnkiKOAi → Settings** or the plugin hub menu.

### Main screen

| Setting | Description |
|---------|-------------|
| **Card defaults…** | Per card type: note type and default deck (from Anki), one-tap send, dictionary |
| **Anki connection…** | AnkiConnect URL, sync after send, test connection |
| **Tags…** | Enable tags and edit tag list |
| **Memorization options…** | Split/context/batch behavior (not deck or note type) |
| **AI Settings** | Provider, language, wiki sources, prompts |
| **Sync…** | Send pending cards when WiFi is on (every **20 minutes**, silent), cloud backup |

### Card defaults

| Submenu | Settings |
|---------|----------|
| **Wiki Card…** | Note type, default deck, **One-tap send (Wiki)** |
| **Vocabulary Card…** | Note type, default deck, preferred dictionary, **One-tap send (Vocabulary)** |
| **Memorization Card…** | Note type, parent deck, **One-tap send (Memorization)**, quick highlight button, skip hub submenu when auto-send |
| **Send routing…** | Subdeck by book title, favorites, per-book deck overrides (not default decks) |

**One-tap send** uses each card type’s configured default deck (not the last deck you picked manually). Turn it on per card type under **Card defaults**.

When **Skip hub submenu when auto-send** is ON and one-tap send is ON for a card type, the AnkiKOAi hub goes straight to that action (no “Create…” submenu).

### Settings migration

If you previously used **Send to Anki after generate**, the plugin migrates that to all three **One-tap send** toggles on first load. Legacy `memorize_auto_send` is migrated to `auto_send_memorization`.

---

## AnkiConnect

| Requirement | Detail |
|-------------|--------|
| Anki desktop | Must be running on the PC |
| Add-on | AnkiConnect — install code `2055492159` |
| Port | Default `8765` |
| URL from e-reader | `http://192.168.x.x:8765` — **not** `localhost` or `127.0.0.1` |

Test with **Test Connection** under **Anki connection**. If it fails: check firewall, Wi‑Fi isolation (guest networks often block device-to-PC), and that Anki is in the foreground at least once after install.

### Deck resolution (Wiki & Vocabulary)

1. Start from the card type’s default deck (**Card defaults → Wiki Card** or **Vocabulary Card**)
2. If **per-book mapping** exists for `book_title`, use that deck instead (under **Send routing → Favorites & book overrides**)
3. If **Subdeck by book title** is ON (**Send routing**), append `::Book Title`

Example: deck `English::Koreader`, book *Moby-Dick* → `English::Koreader::Moby-Dick`

---

## AI providers

Set in **AnkiKOAi → Settings → AI Settings** or `configuration.lua`.

### AI provider (`text_provider`)

| Value | API key field | Notes |
|-------|---------------|-------|
| `dashscope` | `dashscope_api_key` | Default; Qwen models via DashScope |
| `gemini` | `gemini_api_key` | Google AI Studio |
| `openai` | `openai_api_key` | GPT models |
| `openrouter` | `openrouter_api_key` | Many models; set `openrouter_model` |

### Other AI toggles

| Setting | Effect |
|---------|--------|
| **Wiki sources** | Pulls Wiktionary/Wikipedia snippets into the prompt |
| **Strict accuracy** | Stricter prompt rules — less creative filler |
| **Prompt suffix** | Appended to all generation prompts |
| **Custom prompt per note type** | Overrides default Wiki Card/Basic/generic prompts |

Default model names in `configuration.lua.sample`:

```lua
provider = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
model    = "qwen-plus",
openrouter_model = "anthropic/claude-3-haiku",
```

---

## Vocabulary (`anki` section)

```lua
anki = {
    url   = "http://192.168.1.100:8765",
    deck  = "English::Koreader",  -- legacy fallback
    wiki_deck = "English::Koreader",
    vocabulary_deck = "English::Koreader",
    wiki_note_type = "Wiki Card",
    model = "Wiki Card",
    vocabulary_model = "Vocabulary Card",
    memorize_parent_deck = "Memorize",
    tags  = { "KOReader" },
    sync_after_send = true,
    auto_send_wiki = false,
    auto_send_vocabulary = false,
    auto_send_memorization = false,
    auto_send_skip_hub_submenu = false,
    vocabulary_preferred_dictionary = "",
},
```

| Key | Purpose |
|-----|---------|
| `url` | AnkiConnect endpoint |
| `wiki_deck` | Default deck for **Wiki Card** sends |
| `vocabulary_deck` | Default deck for **Vocabulary Card** sends |
| `deck` | Legacy fallback when per-type deck keys are unset |
| `wiki_note_type` | Note type for **Wiki Card (AI)** (preferred key) |
| `model` | Legacy alias for `wiki_note_type` — kept in sync on save |
| `vocabulary_model` | Note type for **Vocabulary Card (No AI)** |
| `auto_send_wiki` / `auto_send_vocabulary` / `auto_send_memorization` | One-tap send per card type |
| `auto_send_skip_hub_submenu` | Flatten hub menu when one-tap send is ON for that type |
| `vocabulary_preferred_dictionary` | StarDict name for vocabulary lookups |
| `tags` | Tags on every vocab note |
| `sync_after_send` | Push to AnkiWeb after successful send |

The plugin rejects Vocabulary Card or Memorization as the wiki default and migrates old settings automatically. Pickers in Settings only show compatible note types for each flow.

On-device equivalents: same names without the `anki.` prefix in the saved settings file.

---

## Memorization (`memorize` section)

```lua
memorize = {
    parent_deck             = "Memorize",
    model                   = "Memorization",
    context_lines           = 3,
    context_cumulative      = false,
    max_words_per_unit      = 7,
    auto_create_deck        = true,
    include_full_recitation = true,
    force_verse_lines       = false,
    show_split_preview      = false,
    replace_duplicates      = false,
    merge_batch             = false,
    tags                    = { "KOReader", "memorization" },
},
```

**Deck and note type** are set under **Settings → Card defaults → Memorization Card**. **Behavior** (context lines, verse split, batch merge, etc.) is under **Memorization options**.

On-device keys for **Card defaults**: `wiki_deck`, `vocabulary_deck`, `wiki_note_type`, `vocabulary_model`, `memorize_parent_deck`, `memorize_model`, `auto_send_wiki`, `auto_send_vocabulary`, `auto_send_memorization`, `memorize_quick_highlight_button`, `auto_send_skip_hub_submenu`, `vocabulary_preferred_dictionary`.

On-device keys for **Send routing**: `subdeck_by_book`, `per_book_decks`, `favorite_decks`.

On-device keys for **Memorization options**: `memorize_context_lines`, `memorize_context_cumulative`, `memorize_max_words`, `memorize_include_full_recitation`, `memorize_force_verse_lines`, `memorize_show_split_preview`, `memorize_replace_duplicates`, `memorize_merge_batch`, `memorize_auto_save_on_fail`.

See [Anki: Memorization deck](anki-memorization.md) for tuning prose vs poetry.

---

## Send routing extras

**Card defaults → Send routing → Favorites & book overrides:**

| Action | Purpose |
|--------|---------|
| **Toggle favorite: current deck** | Pin decks for quick pick at send time |
| **Map deck to current book** | Uses the open book’s title and lets you pick its Anki deck |

Recent decks (last 5) are remembered automatically when you send manually from the card viewer.

---

## Sync and storage

| Feature | File / setting |
|---------|----------------|
| Saved cards (not yet sent) | `ankikooai_cards.json` |
| Settings | `ankikooai_settings.json` |
| Send pending when WiFi (every 20 min) | Settings → Sync |
| Cloud sync | Optional backup of saved cards to a sync server |

Highlight colors after send (KOReader): **orange** = saved locally, **green** = sent to Anki.

**Send pending when WiFi (every 20 min):** When ON and WiFi is up, unsent cards in **My Cards** are flushed to AnkiConnect silently in the background (no progress overlay). If Anki is unreachable, the plugin backs off up to an hour between attempts. Turn OFF while reading without Anki to avoid any network activity.

---

## Security checklist for GitHub

- Commit **`configuration.lua.sample`** only
- Do **not** commit `configuration.lua`, `*_settings.json`, `*_cards.json`, or logs
- Rotate any API key that was ever committed or shared

---

## Related guides

- [Getting started](getting-started.md)
- [Anki: Vocabulary deck](anki-vocabulary.md)
- [Anki: Memorization deck](anki-memorization.md)
