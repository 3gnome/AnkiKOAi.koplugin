# Prompts & suffix — reading summary (on device)

Customize how **Wiki Card (AI)** builds flashcards. These settings apply only to AI generation — not Vocabulary or Memorization cards.

Open from **AnkiKOAi → Settings → AI Settings → Prompts & suffix**.

## Prompt suffix

Short extra instructions appended to every AI prompt.

Examples: always include etymology, prefer British spelling, keep definitions under 40 words.

Leave empty to use the built-in defaults only.

## Note type for prompts

Pick which Anki note type you are editing (**Note type for prompts**). Prompts are stored **per note type** (e.g. Wiki Card vs a custom clone).

Default wiki note types are set under **Settings → Card defaults → Wiki Card**. Changing that default may copy custom prompts from the old type to the new one.

## Generate prompt

Overrides the main prompt used when you create a new Wiki Card from a highlight.

Leave empty to use the default profile for that note type. Use **Preview generate prompt** to see the full text sent to the AI (with sample book data).

## Regen prompt

Overrides the prompt for **Regenerate broader context** in the card preview.

Stored separately from the generate prompt (key ends with `::__regen_text__` internally).

## Other toggles (AI Providers menu)

| Setting | Effect |
|---------|--------|
| **Wiki sources** | Adds Wiktionary/Wikipedia excerpts to prompts |
| **Strict accuracy** | Tells the AI to say "Unclear from context" instead of guessing |
| **Language** | Target language for definitions and notes |

## Save workflow

Edits here are **drafts** until you tap **Save**. **Close without saving** discards changes. **Restore defaults** clears suffix and all custom prompts.

Full guide on your computer: **docs/prompts-and-suffix.md**
