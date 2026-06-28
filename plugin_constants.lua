-- Plugin identity and storage file names.

return {
    ID   = "ankikooai",
    NAME = "AnkiKOAi",

    WIKI_CARD_LABEL = "Wiki Card (AI)",

    VOCABULARY_CARD_LABEL = "Vocabulary Card (No AI)",

    MEMORIZATION_CARD_LABEL = "Memorization Card (No AI, Multi-Line)",

    CARDS_FILE       = "ankikooai_cards.json",
    SETTINGS_FILE    = "ankikooai_settings.json",
    RECENT_SENT_FILE = "ankikooai_recent_sent.json",

    HIGHLIGHT_COLOR_SAVED = "orange",
    HIGHLIGHT_COLOR_SENT  = "green",

    -- KOReader sorts highlight-dialog buttons by id string (99_… sorts after 01_…07_).
    HIGHLIGHT_DIALOG_ID_HUB  = "99_ankikooai",
    HIGHLIGHT_DIALOG_ID_MEM  = "98_ankikooai_mem",
}
