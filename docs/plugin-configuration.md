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
| **Wiki note type** | Default Anki model for Wiki Card (AI) (default: Wiki Card) |
| **Vocabulary note type** | Default Anki model for Vocabulary Card (No AI) (default: Vocabulary Card) |
| **Deck** | Default destination deck (default: English::Koreader) |
| **AnkiConnect URL** | `http://LAN_IP:8765` — PC running Anki, same Wi‑Fi |
| **Subdeck by book title** | ON → cards go to `Deck::Book Title` |
| **Send to Anki after generate** | ON → auto-send after AI generation (skips manual review step) |
| **Sync to AnkiWeb after send** | ON → AnkiConnect syncs to AnkiWeb after each send |
| **Tags** | Comma-separated tags on new notes (default: KOReader) |
| **Test Connection** | Pings AnkiConnect |
| **Advanced deck options** | Favorites, per-book deck mapping |
| **Memorization…** | Chunk size, parent deck, memorization note type |
| **Language** | Target language for AI output (default: English) |
| **Wiki sources for AI** | ON → enriches prompts with Wiktionary/Wikipedia when available |
| **AI Settings** | AI provider, strict accuracy, custom prompts |
| **API Keys** | DashScope, Gemini, OpenAI, OpenRouter |
| **Sync** | Auto-send on WiFi, cloud card backup |

---

## AnkiConnect

| Requirement | Detail |
|-------------|--------|
| Anki desktop | Must be running on the PC |
| Add-on | AnkiConnect — install code `2055492159` |
| Port | Default `8765` |
| URL from e-reader | `http://192.168.x.x:8765` — **not** `localhost` or `127.0.0.1` |

Test with **Test Connection** in Settings. If it fails: check firewall, Wi‑Fi isolation (guest networks often block device-to-PC), and that Anki is in the foreground at least once after install.

### Deck resolution (vocabulary)

1. Start from Settings **Deck** (or `anki.deck` in config)
2. If **per-book mapping** exists for `book_title`, use that deck instead
3. If **Subdeck by book title** is ON, append `::Book Title`

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
    deck  = "English::Koreader",
    wiki_note_type = "Wiki Card",
    model = "Wiki Card",
    vocabulary_model = "Vocabulary Card",
    tags  = { "KOReader" },
    sync_after_send = true,
},
```

| Key | Purpose |
|-----|---------|
| `url` | AnkiConnect endpoint |
| `deck` | Default vocabulary deck (Wiki and Vocabulary cards) |
| `wiki_note_type` | Note type for **Wiki Card (AI)** (preferred key) |
| `model` | Legacy alias for `wiki_note_type` — kept in sync on save |
| `vocabulary_model` | Note type for **Vocabulary Card (No AI)** |
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
    max_words_per_unit      = 7,
    auto_create_deck        = true,
    include_full_recitation = true,
    tags                    = { "KOReader", "memorization" },
},
```

On-device keys: `memorize_parent_deck`, `memorize_model`, `memorize_context_lines`, `memorize_max_words`, `memorize_include_full_recitation`.

See [Anki: Memorization deck](anki-memorization.md) for tuning prose vs poetry.

---

## Deck extras

**Advanced deck options:**

| Action | Purpose |
|--------|---------|
| **Toggle favorite: current deck** | Pin decks for quick pick at send time |
| **Map deck to current book** | Uses the open book’s title and lets you pick its Anki deck |

Recent decks (last 5) are remembered automatically when you send.

---

## Sync and storage

| Feature | File / setting |
|---------|----------------|
| Saved cards (not yet sent) | `ankikooai_cards.json` |
| Settings | `ankikooai_settings.json` |
| Auto-send on WiFi | Settings → Sync |
| Cloud sync | Optional backup of saved cards to a sync server |

Highlight colors after send (KOReader): **orange** = saved locally, **green** = sent to Anki.

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
