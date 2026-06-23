# Getting started

End-to-end setup: plugin on your e-reader, Anki on your PC, first vocabulary card and (optionally) first memorization deck.

## What you need

- A device running [KOReader](https://koreader.rocks/) (Kobo, Kindle with KOReader, or the desktop emulator)
- A PC on the **same Wi‑Fi network** running [Anki](https://apps.ankiweb.net/) with the [AnkiConnect](https://foosoft.net/projects/anki-connect/) add-on (code `2055492159`)
- An API key from at least one AI provider (for **Wiki Card (AI)** only)
- StarDict dictionaries installed in KOReader (for **Vocabulary Card (No AI)**)

## Step 1 — Install the plugin

Copy this repository into KOReader’s plugins folder:

```
koreader/plugins/AnkiKOAi.koplugin/
```

The folder name **must** end in `.koplugin`.

Restart KOReader. You should see **AnkiKOAi** in the highlight menu after selecting text.

## Step 2 — Set up Anki (one-time)

Create **three note types** and **deck-option presets**. Skipping this step is the most common reason sends fail.

| Flow | Guide | Default deck |
|------|-------|--------------|
| Wiki Card (AI) | [Anki: Wiki Card setup](anki-vocabulary.md) | `English::Koreader` |
| Vocabulary Card (No AI) | [Anki: Vocabulary Card setup](anki-vocabulary-card.md) | `English::Koreader` |
| Memorization | [Anki: Memorization deck](anki-memorization.md) | `Memorize` (subdecks auto-created) |

Minimum checklist:

- [ ] Note type **Wiki Card** with fields `Phrase`, `Text`, `Links`, `Source` (+ optional `Definition`, `IPA`, `Synonyms`) — see [anki-vocabulary.md](anki-vocabulary.md)
- [ ] Note type **Vocabulary Card** with fields `Phrase`, `Definition`, `Context`, `Source` — see [anki-vocabulary-card.md](anki-vocabulary-card.md)
- [ ] Note type **Memorization** with card types **Line** and **Full**
- [ ] Deck **English::Koreader** (or your chosen vocab parent deck)
- [ ] Deck **Memorize** (parent for memorization subdecks)
- [ ] Deck-options preset **Wiki Card** applied to the vocab deck
- [ ] Deck-options preset **Memorize** applied to `Memorize` and subdecks
- [ ] (Recommended) Filtered deck **Memorize :: Full recitation (weekly)** for full-passage cards

## Step 3 — Configure the plugin

On the device (recommended on Kobo):

1. Open **AnkiKOAi → Settings** (or tap Settings from the AnkiKOAi hub menu).
2. Set **AnkiConnect URL** to `http://YOUR_PC_LAN_IP:8765` — use your PC’s Wi‑Fi address, **not** `localhost`.
3. Set **Deck**, **Wiki note type** (`Wiki Card`), and **Vocabulary note type** (`Vocabulary Card`) to match Anki.
4. Tap **Test Connection** — Anki must be running on the PC.
5. Under **API Keys**, paste your provider key (Wiki Card only).
6. Optionally open **Memorization…** and confirm parent deck `Memorize` and note type `Memorization`.

Alternatively, copy `configuration.lua.sample` to `configuration.lua` on a PC and edit there before syncing the plugin folder to the device. On-device settings **override** the file after you save them once.

See [Plugin configuration](plugin-configuration.md) for every setting.

## Step 4 — AnkiConnect on the PC

1. Anki → Tools → Add-ons → Get Add-ons → enter `2055492159`.
2. Restart Anki.
3. Find your PC’s LAN IP (e.g. `ipconfig` on Windows, `ip addr` on Linux).
4. Confirm AnkiConnect listens on port **8765** (default).

Firewall must allow inbound connections on that port from your e-reader’s subnet.

## Step 5 — Your first Wiki Card (AI)

1. Open a book in KOReader and highlight a word or short phrase.
2. Choose **AnkiKOAi → Wiki Card (AI)** from the highlight menu.
3. Wait for the AI card preview (front shows the term only; back shows the article and explore links).
4. Tap **Show Answer**, review, edit if needed, then **→ Anki**.
5. Pick the deck (defaults to your configured deck; subdeck by book title is ON by default).
6. Confirm the note appears in Anki.

Highlights turn **orange** when saved locally and **green** after a successful send.

## Step 5b — Your first Vocabulary Card (No AI)

1. Ensure KOReader dictionaries are installed and enabled.
2. Highlight a single word.
3. Choose **AnkiKOAi → Vocabulary Card (No AI)**.
4. Review the dictionary definition and passage context, then send to Anki.

No API key or Wi‑Fi is required for the dictionary lookup itself; sending to Anki still needs AnkiConnect on your PC.

## Step 6 — Your first memorization deck (optional)

1. Highlight a short poem or paragraph (use line breaks for poetry).
2. Choose **Memorization Card (No AI, Multi-Line)** from the highlight menu.
3. Confirm chunk size and deck name, then send.

See [Anki: Memorization deck](anki-memorization.md) for study routine and filtered-deck setup.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| “Cannot reach Anki” | Anki running? Correct LAN IP? Firewall? |
| Send fails / missing fields | Note type and field names must match docs exactly |
| Wiki Card generation fails | Check API key and Wi‑Fi |
| Dictionary lookup fails | Install/enable StarDict dictionaries in KOReader |
| No **AnkiKOAi** in menu | Restart KOReader; confirm `.koplugin` folder name |

## Next steps

- Batch highlights: **AnkiKOAi → Highlights to Anki** (Wiki Card AI batch or Memorization)
- Edit saved cards: **My Cards**
- Tune memorization chunk size: **AnkiKOAi → Settings → Memorization…**
