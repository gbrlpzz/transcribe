"""Smart text — spoken-punctuation post-processing (dictation-style).

Whisper is very good at words but less reliable at commas, quotes and
structure. Smart text fixes the common cases: say "comma" and you get a comma,
say "new line" and the text wraps, say "delete that" and the last word
disappears.

Replacement happens only on whole-word tokens (word boundaries), so ordinary
speech such as "the period of the function" is left alone when the token is
embedded — the trade-off is documented in the README; disable with
``--no-smart-text`` or ``transcribe config set smart_text false``.
"""

from __future__ import annotations

import re

# token -> replacement. Tokens are matched as whole words, case-insensitively.
TOKENS: dict[str, str] = {
    # punctuation
    "comma": ",",
    "period": ".",
    "full stop": ".",
    "question mark": "?",
    "exclamation mark": "!",
    "exclamation point": "!",
    "colon": ":",
    "semicolon": ";",
    # structure
    "new line": "\n",
    "new paragraph": "\n\n",
    "newline": "\n",
    # quotes & brackets
    "open quote": "\u201c",
    "close quote": "\u201d",
    "open parenthesis": "(",
    "close parenthesis": ")",
    "open bracket": "[",
    "close bracket": "]",
    "open brace": "{",
    "close brace": "}",
    # symbols
    "at sign": "@",
    "hashtag": "#",
    "asterisk": "*",
    "dash": "\u2014",
    "hyphen": "-",
    "underscore": "_",
    "percent sign": "%",
    "dollar sign": "$",
    "ampersand": "&",
    "slash": "/",
    "backslash": "\\",
    "copyright sign": "\u00a9",
}

# tokens whose replacement is applied only at the end of an utterance
# (e.g. "delete that" removes the preceding word)
_EDIT_TOKENS = {
    "delete that": "delete",
    "scratch that": "delete",
    "undo that": "delete",
}

_WORD_RE = re.compile(r"(?<![\w])(" + "|".join(sorted(
    (re.escape(t) for t in TOKENS), key=len, reverse=True)) + r")(?![\w])", re.IGNORECASE)


def apply_smart_text(text: str, *, delete: bool = True) -> str:
    """Apply spoken-punctuation replacement to a transcript.

    ``delete`` enables "delete that" / "scratch that" editing commands.
    Returns the processed text with edits applied.
    """
    if not text:
        return text

    # whole-word token replacement
    out = _WORD_RE.sub(lambda m: TOKENS[m.group(1).lower()], text)
    out = _cleanup_spacing(out)

    if delete:
        out = _apply_delete_tokens(out)

    return out


def _cleanup_spacing(text: str) -> str:
    """Remove stray spaces introduced around punctuation and structure."""
    text = re.sub(r"[ \t]+([,.;:!?%])", r"\1", text)            # before punctuation
    text = re.sub(r"[ \t]+([\u201d\'\]\)\}])", r"\1", text)  # before closers
    text = re.sub(r"([\u201c\'\[\(\{])([ \t]+)", r"\1", text)  # after openers
    text = re.sub(r"[ \t]*\n[ \t]*", "\n", text)              # around newlines
    text = re.sub(r"([?!,;:])\.", r"\1", text)              # "?." -> "?"
    return text


def _apply_delete_tokens(text: str) -> str:
    """Handle 'delete that' / 'scratch that' by removing the previous word.

    The token itself is dropped and the word immediately before it is removed.
    Applied repeatedly so "delete that delete that" removes two words.
    """
    for _ in range(8):  # bound the loop; a real utterance won't exceed this
        match = None
        for token in _EDIT_TOKENS:
            m = re.search(r"(?<![\w])" + re.escape(token) + r"(?![\w])", text, re.IGNORECASE)
            if m:
                match = (token, m)
                break
        if not match:
            break
        token, m = match
        # remove the token
        before = text[: m.start()]
        after = text[m.end():]
        # remove the previous word (and any whitespace before it)
        before = re.sub(r"[\w\u00c0-\u024f]+[\s]*$", "", before)
        text = before + after
    return text.strip()


def strip_whitespace(text: str) -> str:
    """Collapse double spaces and trim (keeps intentional newlines)."""
    return re.sub(r"[ \t]+", " ", text).strip()
