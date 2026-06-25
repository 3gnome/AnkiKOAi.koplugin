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
| Wiki Card (AI) | [Anki: Wiki Card setup](anki-vocabulary.md) | Configure under **Card defaults → Wiki Card** |
| Vocabulary Card (No AI) | [Anki: Vocabulary Card setup](anki-vocabulary-card.md) | Configure under **Card defaults → Vocabulary Card** |
| Memorization | [Anki: Memorization deck](anki-memorization.md) | **Memorize** parent deck under **Card defaults → Memorization Card** |

Minimum checklist:

- [ ] Note type **Wiki Card** with fields `Phrase`, `Text`, `Links`, `Source` (+ optional `Definition`, `IPA`, `Synonyms`) — see [anki-vocabulary.md](anki-vocabulary.md)
- [ ] Note type **Vocabulary Card** with fields `Phrase`, `Definition`, `Context`, `Source` — see [anki-vocabulary-card.md](anki-vocabulary-card.md)
- [ ] Note type **Memorization** with card types **Line** and **Full**
- [ ] Deck for Wiki Card (e.g. **English::Koreader**)
- [ ] Deck for Vocabulary Card (can match wiki deck or differ, e.g. **2026 Vocabulary**)
- [ ] Deck **Memorize** (parent for memorization subdecks)
- [ ] Deck-options preset **Wiki Card** applied to the vocab deck
- [ ] Deck-options preset **Memorize** applied to `Memorize` and subdecks
- [ ] (Recommended) Filtered deck **Memorize :: Full recitation (weekly)** for full-passage cards

## Step 3 — Configure the plugin

On the device (recommended on Kobo):

1. Open **AnkiKOAi → Settings** (or tap Settings from the AnkiKOAi hub menu).
2. Open **Anki connection…** → set **AnkiConnect URL** to `http://YOUR_PC_LAN_IP:8765` (your PC’s Wi‑Fi address, **not** `localhost`) → **Test Connection** (Anki must be running).
3. Open **Card defaults…**:
   - **Wiki Card…** → note type **Wiki Card**, default deck `English::Koreader` (or yours)
   - **Vocabulary Card…** → note type **Vocabulary Card**, default deck (e.g. `2026 Vocabulary`)
   - **Memorization Card…** → parent deck **Memorize**, note type **Memorization**
   - **Send routing…** → leave **Subdeck by book title** ON if you want `Deck::Book Title`
4. Under **AI Settings → API Keys**, paste your provider key (Wiki Card only).

Alternatively, copy `configuration.lua.sample` to `configuration.lua` on a PC and edit there before syncing the plugin folder to the device. On-device settings **override** the file after you save them once.

See [Plugin configuration](plugin-configuration.md) for every setting.

### Optional: one-tap send (fastest workflow)

After defaults are set, turn on **One-tap send** per card type under **Card defaults**:

| Card type | Effect |
|-----------|--------|
| Wiki Card | Skip note-type and deck pickers; generate and send to your default deck |
| Vocabulary Card | Skip note-type picker; use preferred dictionary when set; send to default deck |
| Memorization Card | Skip intro and confirmation; send step cards immediately |

Enable **Skip hub submenu when auto-send** (under **Memorization Card defaults**) to go from the AnkiKOAi hub to the card action in one tap when one-tap send is ON.

## Step 4 — AnkiConnect on the PC

1. Anki → Tools → Add-ons → Get Add-ons → enter `2055492159`.
2. Restart Anki.
3. Find your PC’s LAN IP (e.g. `ipconfig` on Windows, `ip addr` on Linux).
4. Confirm AnkiConnect listens on port **8765** (default).

Firewall must allow inbound connections on that port from your e-reader’s subnet.

## Step 5 — Your first Wiki Card (AI)

1. Open a book in KOReader and highlight a word or short phrase.
2. Choose **AnkiKOAi → Wiki Card (AI)** from the highlight menu.
3. If one-tap send is OFF: pick note type (if prompted), wait for the AI preview, review, then **→ Anki** and pick a deck.
4. If one-tap send is ON: the card generates and sends to your default deck automatically.
5. Confirm the note appears in Anki.

Highlights turn **orange** when saved locally and **green** after a successful send.

## Step 5b — Your first Vocabulary Card (No AI)

1. Ensure KOReader dictionaries are installed and enabled.
2. Highlight a single word.
3. Choose **AnkiKOAi → Vocabulary Card (No AI)**.
4. If multiple dictionaries match and no preferred dictionary is set, pick an entry once.
5. Review (or auto-send) and confirm in Anki.

No API key or Wi‑Fi is required for the dictionary lookup itself; sending to Anki still needs AnkiConnect on your PC.

## Step 6 — Your first memorization deck (optional)

1. Highlight a short poem or paragraph (use line breaks for poetry).
2. Choose **Memorization Card (No AI, Multi-Line)** from the highlight menu.
3. If one-tap send is OFF: confirm chunk size and deck, then send.
4. If one-tap send is ON: step cards (+ optional full card) are sent immediately.

See [Anki: Memorization deck](anki-memorization.md) for study routine and filtered-deck setup.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| “Cannot reach Anki” | Anki running? Correct LAN IP? Firewall? |
| Send fails / missing fields | Note type and field names must match docs exactly |
| Wiki Card generation fails | Check API key and Wi‑Fi |
| Dictionary lookup fails | Install/enable StarDict dictionaries in KOReader |
| Card sent to wrong deck | Check the card type’s default deck under **Card defaults**; one-tap send uses that deck, not your last manual pick |
| No **AnkiKOAi** in menu | Restart KOReader; confirm `.koplugin` folder name |

## Next steps

- Batch highlights: **AnkiKOAi → Highlights and Cards** (Wiki, Vocabulary, or Memorization batch)
- Edit saved cards: **My Cards**
- Tune memorization split/context: **AnkiKOAi → Settings → Memorization options…**
- Tune per-type decks, note types, and one-tap send: **AnkiKOAi → Settings → Card defaults…**
- Send routing (subdeck by book): **Card defaults → Send routing…**
