# Prompts & suffix

How to customize AI prompts for Wiki Card generation in AnkiKOAi.

## Where to open it

**AnkiKOAi → Settings → AI Settings → Prompts & suffix**

On your e-reader, tap **View README** in that submenu for a short summary (`docs/in-app/prompts-and-suffix.md`).

---

## What gets customized

| Control | Purpose |
|---------|---------|
| **Prompt suffix** | Extra instructions appended to every generate and regen prompt |
| **Note type** | Read-only — always your Wiki Card note type from **Card defaults → Wiki Card** |
| **View default generate/regen** | Built-in template only (gray row) |
| **Modify generate/regen prompt…** | Custom template override |
| **Preview effective generate/regen** | Full assembled prompt (sample highlight data) |
| **Reset generate / regen** | Clears custom template for the wiki note type |
| **Restore defaults** | Clears suffix and all custom prompts |
| **Save** | Writes to on-device settings (`ankikooai_settings.json`) |

Vocabulary and Memorization flows do **not** use these prompts.

---

## Prompt suffix

Stored as `prompt_suffix` in settings. When non-empty, the plugin adds:

```
Additional instructions from the reader:
<your text>
```

to both generate and regen prompts.

Good uses: tone (“formal academic English”), focus (“always mention word origin”), length limits, or domain hints (“this is a legal thriller”).

---

## Per–note-type prompts

Custom templates live in `custom_prompts` keyed by **exact Anki note type name** (normalized through the plugin’s model-name rules). The UI always edits prompts for your **Wiki Card note type** (`wiki_note_type` from Card defaults); `prompt_edit_model` is kept in sync on save.

- **Generate prompt** → key = note type name (e.g. `Wiki Card`)
- **Regen prompt** → key = note type name + `::__regen_text__`

Leave a field empty to fall back to the built-in profile:

- **Information** note types (Wiki Card): JSON schema prompt for `Phrase`, `Text`, `Definition`, optional `IPA`; plugin fills `Links` and `Source`
- **Basic** / **generic**: simpler front/back JSON prompts

When you change the default wiki note type under **Settings → Card defaults → Wiki Card**, existing custom prompts are **migrated** from the old name to the new one when possible.

---

## Accuracy and wiki blocks

These are **not** edited in Prompts & suffix; they come from **AI Settings** (tap gray **About …** rows on device for details):

| Toggle | In prompt |
|--------|-----------|
| Wiki sources ON | Wikimedia excerpts + wiki-specific accuracy rules (treat excerpts as primary sources) |
| Wiki sources OFF | Passage-only accuracy rules — no Wikimedia excerpts |
| Strict accuracy ON | Extra rule: if not confident about any field, use exactly "Unclear from context"; never guess |
| Strict accuracy OFF | Standard accuracy rules only (no invented citations; prefer passage-supported facts) |

The suffix and custom templates still receive `{accuracy_rules}`, `{wiki_block}`, `{custom_suffix}`, and other placeholders when previewed or sent.

---

## Template placeholders

Custom generate templates should keep the same `{placeholders}` as the default profile, including:

- `{language}`, `{title}`, `{author}`, `{phrase}`, `{context}`
- `{definition}` (when relevant)
- `{wiki_block}`, `{accuracy_rules}`, `{custom_suffix}`
- `{json_schema}`, `{model_name}`

Regen templates typically use `{phrase}`, `{context}`, `{definition}`, `{wiki_block}`, `{custom_suffix}`, `{accuracy_rules}`, `{model_name}`.

Use **Preview** on device before saving a long custom prompt.

---

## Storage keys (advanced)

In `ankikooai_settings.json`:

```json
{
  "prompt_suffix": "",
  "prompt_edit_model": "Wiki Card",
  "custom_prompts": {
    "Wiki Card": "...",
    "Wiki Card::__regen_text__": "..."
  }
}
```

`prompt_edit_model` mirrors `wiki_note_type` (synced when you save Prompts & suffix).

---

## Tips

1. Start with **suffix only** — small changes, low risk.
2. Use **Preview** after any edit.
3. **Reset** one prompt before **Restore defaults** if you only want to undo one note type.
4. Custom prompts do not affect dictionary-only Vocabulary cards or memorization chunking.
