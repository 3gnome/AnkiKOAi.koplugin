# Prompts & suffix — reading summary (on device)

Customize how **Wiki Card (AI)** builds flashcards. These settings apply only to AI generation — not Vocabulary or Memorization cards.

Open from **AnkiKOAi → Settings → AI Settings → Prompts & suffix**.

Gray rows are informational — **tap gray rows for help.**

## Note type

Prompts always apply to your **Wiki Card note type** from **Card defaults → Wiki Card**. The gray **Note type:** row shows the current name. To change it, use Card defaults — custom prompts migrate when possible.

## View default vs Modify vs Preview effective

| Action | Purpose |
|--------|---------|
| **View default generate/regen prompt** | Built-in template only (no custom override) |
| **Modify generate/regen prompt…** | Edit your custom template; empty = use default |
| **Preview effective generate/regen prompt** | Full prompt as sent (custom + suffix + accuracy rules) |

## Prompt suffix

Short extra instructions appended to every AI prompt.

Examples: always include etymology, prefer British spelling, keep definitions under 40 words.

Use **Modify prompt suffix…** to edit. Leave empty to use built-in defaults only.

## Generate prompt

Overrides the main prompt used when you create a new Wiki Card from a highlight.

Leave empty to use the default profile. **Reset generate prompt** clears your custom template.

## Regen prompt

Overrides the prompt for **Regenerate broader context** in the card preview.

Stored separately from the generate prompt (key ends with `::__regen_text__` internally).

## Other toggles (AI Settings menu)

These are under **Settings → AI Settings** — not in Prompts & suffix. Gray **About …** rows explain each option when tapped.

| Setting | Effect |
|---------|--------|
| **Wiki sources** | Adds Wiktionary/Wikipedia excerpts to prompts |
| **Strict accuracy** | AI must say "Unclear from context" instead of guessing |
| **Language** | Target language for definitions and notes |

## Save workflow

Edits here are **drafts** until you tap **Save**. **Close without saving** or **← Back** (with unsaved changes) discards changes. **Restore defaults** clears suffix and all custom prompts.

Full guide on your computer: **docs/prompts-and-suffix.md**
