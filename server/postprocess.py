"""Deterministic cleanup of raw transcripts — no LLM, no rewriting.

Removes the artifacts real dictation produces: the ASR silence-hallucination
("thank you."), stray "." fragments, asterisk sound-tags (*laughs*), spoken
fillers (uh/um), restart-stutters, and word echoes (a word repeated across a
segment boundary, which models emit on restarts and boundary splits).

Every step is a pure string op. Steps that can cascade loop to a fixpoint, so
the whole pipeline is idempotent: postprocess(postprocess(x)) == postprocess(x).

Guiding principle for filler removal: a hallucinated "thank you" is ALWAYS its
own period-terminated segment ("thank you."), because ASR closes the "sentence"
it invents on silence. A REAL "thank you" flows into the sentence ("thank you
for...", "thank you bro"). So we only ever strip a "thank you" that is a complete
standalone segment — never one with a lexical continuation.
"""

import json
import os
import re

from paths import DATA_DIR

DICTIONARY_PATH = os.path.join(DATA_DIR, "dictionary.json")


def load_dictionary():
    try:
        with open(DICTIONARY_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


# Step 5 stoplist: words whose duplication across a "." is real
# interjection/enumeration, not a boundary echo.
DEDUP_STOPLIST = {
    "okay", "yeah", "that", "path", "testing", "exactly", "sure", "really",
    "thanks", "good", "hello", "wait", "stop", "done",
}

# The core filler token: u[hm]+ (uh, um, uhh, umm, uhm, ...). Fenced on each side
# against a letter or hyphen so real words ("umbrella", "human", "number") and
# "uh-oh" are immune.
FILLER = r"(?<![\w-])u[hm]+(?![\w-])"


def whitespace_squeeze(text):
    text = re.sub(r"[ \t]{2,}", " ", text)
    return re.sub(r"\s+([.,!?…])", r"\1", text)


def strip_asterisk_tags(text):
    return re.sub(r"\*[^*\n]*\*", "", text)


# Delete a "." or "-" that is space-bounded (or string-edge-bounded) on BOTH
# sides. A real sentence period is glued to its word ("lab."), and decimals
# ("4.7"), abbreviations ("u.s."), ellipses ("toss...") and hyphenated compounds
# ("in-depth") all have a non-space neighbour, so they're immune.
def delete_lone_markers(text):
    return re.sub(r"(?:^|(?<=\s))[.\-](?=\s|$)", "", text)


# Spoken fillers ("uh" / "um"). Unlike the "thank you" hallucination these are
# REAL disfluencies and pure filler wherever they land, so always safe to drop.
# We also swallow one adjacent comma so "so, uh, yeah" collapses to "so, yeah".
# Looped to a fixpoint so runs of fillers fully unwind.
def strip_spoken_fillers(text):
    while True:
        prev = text
        # filler that is its OWN segment after a sentence mark ("bro. um. no" ->
        # "bro. no"). Matching starts AFTER the preceding mark so a real ellipsis
        # is left whole ("toss... um. ok" -> "toss... ok").
        text = re.sub(r"(?<=[.!?…])\s*" + FILLER + r"\s*\.(?=\s|$)", "", text, flags=re.I)
        # filler fenced by commas: "so, uh, yeah" -> "so, yeah"
        text = re.sub(r",\s*" + FILLER + r"\s*(?=,)", "", text, flags=re.I)
        # filler right after a comma: "so, uh yeah" -> "so, yeah"
        text = re.sub(r"(,\s*)" + FILLER + r"\s+", r"\1", text, flags=re.I)
        # filler right before a comma: "uh, so" / "thing uh, and" -> drop both
        text = re.sub(FILLER + r"\s*,\s*", "", text, flags=re.I)
        # bare filler: "and uh the" / "uh so" / "thing uh" -> drop it
        text = re.sub(FILLER, "", text, flags=re.I)
        # a comma orphaned against a sentence mark by the drop ("thing, um." ->
        # "thing, ." ) collapses to just the mark
        text = re.sub(r",\s*(?=[.!?…])", "", text)
        if text == prev:
            return text


# "ideas. ideas in there" -> "ideas in there". Guards: >=4 letters (skips the
# "it. it" function-word collisions), a hard stoplist of real interjections, bail
# if the 2nd copy is followed by a comma, and an identical backreference so
# phonetic mid-word splits ("outline. line") never match. Case-sensitive: a real
# repeated uppercase acronym ("HTTP. HTTP") is left alone. Looped for triplets.
def collapse_word_duplication(text):
    pat = re.compile(r"\b([a-z]{4,})\.\s+\1\b(?=([.,]?\s+[a-z]|[.,]?\s*$))")

    def repl(m):
        word, follow = m.group(1), m.group(2)
        if word in DEDUP_STOPLIST:
            return m.group(0)
        if follow.startswith(","):
            return m.group(0)
        return word

    while True:
        prev = text
        text = pat.sub(repl, text)
        if text == prev:
            return text


# A restart-stutter across a boundary ("i like the. the incumbents"). A cross-
# boundary repeat is only UNAMBIGUOUSLY a stutter when the word CANNOT legitimately
# end a sentence, so the whitelist is strictly articles + coordinating conjunctions
# plus first-person openers ("i"/"i'm"/"i've"/"i'll"). Everything else — pronouns,
# auxiliaries, prepositions — is left alone, as are intentional doublings ("blah,
# blah", "no, no"). Looped so a triple restart ("the. the. the") fully collapses.
STUTTER_WORDS = {
    "a", "an", "the", "and", "but", "or", "nor", "i", "i'm", "i've", "i'll",
}


def collapse_stutter(text):
    word = r"[a-z][a-z'’]*"
    pat = re.compile(r"\b(" + word + r")\s*[.?!,…]\s+(\1)\b", re.I)

    def repl(m):
        w = m.group(1)
        return w if w.lower() in STUTTER_WORDS else m.group(0)

    while True:
        prev = text
        text = pat.sub(repl, text)
        if text == prev:
            return text


# Peel a trailing standalone filler ("thank you" / bare "you"). End-anchored, and
# only when preceded by a sentence boundary or string start (a standalone segment)
# — "...to thank you" and "i love you" are structurally safe. Looped to unwind.
def peel_trailing_filler(text):
    pat = re.compile(r"(^|[.!?…]|\*[^*]*\*)\s*(?:thank\s*you|you)\.?\s*$", re.I)
    while True:
        prev = text
        text = pat.sub(lambda m: m.group(1), text)
        if text == prev:
            return text


# Peel a LEADING standalone "thank you." with a real word after it ("thank you.
# perhaps ..."). The mandatory period is the discriminator: "thank you for ..."
# has no period and is never touched. Looped to unwind stacks.
def peel_leading_filler(text):
    while True:
        prev = text
        text = re.sub(r"^\s*thank\s*you\.\s+(?=[a-z])", "", text, flags=re.I)
        if text == prev:
            return text


# Strip an isolated mid-record standalone "thank you." wedged between a real
# sentence boundary and a lowercase continuation ("...nsfw data. thank you.
# and..."). The mandatory period means "thank you bro" (an address) is untouched.
def strip_mid_record_filler(text):
    while True:
        prev = text
        text = re.sub(r"([.!?…]|\*[^*]*\*)\s+thank\s*you\.(?=\s+[a-z])", r"\1", text, flags=re.I)
        if text == prev:
            return text


# Whole-record emptiness + final trim. If the ONLY content was filler ("thank
# you" / "you" / sound-tags / punctuation), the whole record was silence -> "".
def emptiness_normalize(text):
    text = re.sub(r"^[.,\-\s]+", "", text)
    text = re.sub(r"[\-,\s]+$", "", text)

    stripped = re.sub(r"\bthank\s*you\b", "", text, flags=re.I)
    stripped = re.sub(r"\*[^*]*\*", "", stripped)
    stripped = re.sub(r"\byou\b", "", stripped, flags=re.I)
    stripped = re.sub(r"(?<![\w-])u[hm]+(?![\w-])", "", stripped, flags=re.I)
    stripped = re.sub(r"[.\-,*\s]", "", stripped)
    if stripped == "":
        return ""
    return text


def structural_cleanup(text):
    text = strip_asterisk_tags(text)
    text = delete_lone_markers(text)
    text = strip_spoken_fillers(text)
    text = whitespace_squeeze(text)
    text = collapse_word_duplication(text)
    text = collapse_stutter(text)
    text = peel_trailing_filler(text)
    text = peel_leading_filler(text)
    text = strip_mid_record_filler(text)
    text = whitespace_squeeze(text)
    text = emptiness_normalize(text)
    return text


# Lowercase-with-acronym-restore + dictionary replacement.
def lexical_normalize(text, dictionary):
    # Find all-caps words (2+ letters) before lowercasing so we can restore them.
    acronyms = [(m.group(0), m.start()) for m in re.finditer(r"\b[A-Z]{2,}\b", text)]

    result = text.lower()
    for word, offset in reversed(acronyms):
        result = result[:offset] + word + result[offset + len(word):]

    # Keys starting with "_" are comments (dictionary.example.json uses "_readme"),
    # not replacements. Word-boundary anchored so a short key ("bow") only matches
    # the standalone word, never a substring ("rainbow", "elbow").
    for wrong, right in dictionary.items():
        if wrong.startswith("_"):
            continue
        pat = re.compile(r"\b" + re.escape(wrong) + r"\b", re.I)
        result = pat.sub(lambda m, r=right: r, result)

    return result


def postprocess(text):
    """The single cleanup entry point for /transcribe. Lexical normalize ->
    structural cleanup -> re-append the single trailing space the app expects. A
    whole-record silence-garbage input cleans down to "" (returned as "", not a
    lone space)."""
    cleaned = structural_cleanup(lexical_normalize(text, load_dictionary()))
    if cleaned == "":
        return ""
    # Drop a single trailing sentence period for a casual, chat-style feel. Keeps
    # "?" and "!" (they carry tone) and every internal period. Only a "." right
    # after a word char — never an ellipsis ("toss...") or a decimal.
    cleaned = re.sub(r"(?<=[a-z0-9])\.$", "", cleaned)
    return cleaned + " "


# Human-readable manifest of the active rules, surfaced in the app's "Cleanup
# Rules" viewer. These are the shipped, mechanical rules — the SAME for everyone.
# Your personal word-fixes live in the Dictionary (its own panel + dictionary.json),
# NOT here. Keep in sync with the functions above + POSTPROCESS.md.
RULES = [
    {"section": "Style", "name": "Lowercase + acronyms", "desc": "Lowercases everything, but keeps real acronyms (NASA, HTTP)."},
    {"section": "Remove noise", "name": "Strip fillers", "desc": "Removes uh / um and elongations (umbrella, uh-oh survive)."},
    {"section": "Remove noise", "name": "Strip sound-tags", "desc": "Removes *laughs*, *music* event tags."},
    {"section": "Remove noise", "name": "Delete lone marks", "desc": "Removes a stray space-bounded . or - (decimals, u.s., ellipses safe)."},
    {"section": "Fix repetition", "name": "Collapse word echo", "desc": "\"ideas. ideas in there\" → \"ideas in there\"."},
    {"section": "Fix repetition", "name": "Collapse restart-stutter", "desc": "\"i like the. the plan\" → \"i like the plan\"."},
    {"section": "Silence hallucination", "name": "Peel \"thank you\"", "desc": "Removes ASR's silence-invented \"thank you.\" — leading, trailing, and mid-record."},
    {"section": "Finalize", "name": "Whitespace squeeze", "desc": "Collapses extra spaces; removes space before punctuation."},
    {"section": "Finalize", "name": "Emptiness normalize", "desc": "If only filler remained, it was silence → nothing pasted."},
    {"section": "Finalize", "name": "Drop trailing period", "desc": "Removes the final sentence period for a casual feel (keeps ? ! and internal periods)."},
    {"section": "Finalize", "name": "Trailing space", "desc": "Ends with a space so dictations join cleanly."},
]
