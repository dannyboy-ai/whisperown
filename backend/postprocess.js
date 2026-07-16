const fs = require("fs");
const path = require("path");
const { DATA_DIR } = require("./paths");

const DICTIONARY_PATH = path.join(DATA_DIR, "dictionary.json");

function loadDictionary() {
  try {
    const raw = fs.readFileSync(DICTIONARY_PATH, "utf-8");
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

// ---------------------------------------------------------------------------
// Structural cleanup. These rules remove the artifacts real dictation produces:
// Whisper's silence "thank you" hallucination, stray "." fragments, asterisk
// sound-tags (*laughs*), spoken fillers (uh/um), restart-stutters, and word
// echoes (a word repeated across a segment boundary — models emit this on
// restarts and boundary splits).
//
// Guiding principle for filler removal: a hallucinated "thank you" is ALWAYS its
// own period-terminated segment ("thank you."), because Whisper closes the
// "sentence" it invents on silence. A REAL "thank you" flows into the sentence
// ("thank you for...", "thank you bro"). So we only ever strip a "thank you"
// that is a complete standalone segment — never one with a lexical continuation.
//
// All pure synchronous string ops. Steps loop to a fixpoint where needed so the
// whole pipeline is idempotent: postprocess(postprocess(x)) === postprocess(x).
// ---------------------------------------------------------------------------

// Step 5 stoplist: words whose duplication across a "." is real
// interjection/enumeration, not a boundary echo.
const DEDUP_STOPLIST = new Set([
  "okay", "yeah", "that", "path", "testing", "exactly", "sure", "really",
  "thanks", "good", "hello", "wait", "stop", "done",
]);

// --- whitespace squeeze (steps 4 and 9a) ---------------------------------
function whitespaceSqueeze(text) {
  return text
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\s+([.,!?…])/g, "$1");
}

// --- Step 2: strip asterisk sound-tags (*laughs*, *sad music*) -----------
function stripAsteriskTags(text) {
  return text.replace(/\*[^*\n]*\*/g, "");
}

// --- Step 3: delete free-floating lone periods and dashes ----------------
// Only a "." or "-" that is space-bounded (or string-edge-bounded) on BOTH
// sides. A real sentence period is glued to its word ("lab."), and decimals
// ("4.7"), abbreviations ("u.s."), ellipses ("toss...") and hyphenated
// compounds ("in-depth") all have a non-space neighbour, so they're immune.
function deleteLoneMarkers(text) {
  return text.replace(/(?:^|(?<=\s))[.\-](?=\s|$)/g, "");
}

// --- Step 3b: strip spoken fillers ("uh" / "um" and elongations) ---------
// Unlike the "thank you" hallucination, these are REAL disfluencies the speaker
// utters, and they're pure filler wherever they land — so they're always safe
// to drop. The core token is `u[hm]+` (matches uh, um, uhh, umm, uhm, ...). Each
// side is fenced against a letter or hyphen so real words ("umbrella", "human",
// "number") and the interjection "uh-oh" are immune. We also swallow one
// adjacent comma so "so, uh, yeah" collapses to "so, yeah" rather than leaving a
// double comma. Looped to a fixpoint so runs of fillers fully unwind.
const FILLER = String.raw`(?<![\w-])u[hm]+(?![\w-])`;
function stripSpokenFillers(text) {
  let prev;
  do {
    prev = text;
    text = text
      // filler that is its OWN segment after a sentence mark ("bro. um. no" ->
      // "bro. no"): drop the filler and its redundant period. Matching starts
      // AFTER the preceding mark (lookbehind) so a real ellipsis is left whole
      // ("toss... um. ok" -> "toss... ok").
      .replace(new RegExp(String.raw`(?<=[.!?…])\s*${FILLER}\s*\.(?=\s|$)`, "gi"), "")
      // filler fenced by commas: "so, uh, yeah" -> "so, yeah"
      .replace(new RegExp(String.raw`,\s*${FILLER}\s*(?=,)`, "gi"), "")
      // filler right after a comma: "so, uh yeah" -> "so, yeah"
      .replace(new RegExp(String.raw`(,\s*)${FILLER}\s+`, "gi"), "$1")
      // filler right before a comma: "uh, so" / "thing uh, and" -> drop both
      .replace(new RegExp(String.raw`${FILLER}\s*,\s*`, "gi"), "")
      // bare filler: "and uh the" / "uh so" / "thing uh" -> drop it
      .replace(new RegExp(FILLER, "gi"), "")
      // a comma orphaned against a sentence mark by the drop ("thing, um." ->
      // "thing, ." ) collapses to just the mark
      .replace(/,\s*(?=[.!?…])/g, "");
  } while (text !== prev);
  return text;
}

// --- Step 5: collapse single-content-word boundary duplication -----------
// "ideas. ideas in there" -> "ideas in there". Guards: >=4 letters (skips the
// "it. it"/"is. is" function-word collisions), a hard stoplist of real
// interjections/enumerations, bail if the 2nd copy is followed by a comma, and
// an identical backreference so phonetic mid-word splits ("outline. line", non-
// identical) never match. NO "i" flag: text is already lowercased, so a real
// repeated uppercase acronym ("HTTP. HTTP") is left alone. Looped for triplets.
function collapseWordDuplication(text) {
  let prev;
  do {
    prev = text;
    text = text.replace(
      /\b([a-z]{4,})\.\s+\1\b(?=([.,]?\s+[a-z]|[.,]?\s*$))/g,
      (match, word, follow) => {
        if (DEDUP_STOPLIST.has(word)) return match;
        if (/^,/.test(follow)) return match;
        return word; // keep one copy, drop the period + duplicate
      }
    );
  } while (text !== prev);
  return text;
}

// --- Step 5b: collapse a restart-stutter across a boundary ---------------
// When the speaker re-starts a word after a think-pause ("i like the. the
// incumbents"), the punctuator closes a "sentence" on the pause, leaving the same
// word straddling a period or comma. Keep one copy, drop the boundary.
//
// The hard constraint learned from the corpus: a cross-boundary repeat is only
// UNAMBIGUOUSLY a stutter when the word CANNOT legitimately end a sentence.
// "plan for it. it should…", "on that. that because…", "yes it is. is it…" are
// all REAL sentence boundaries that merely happen to share a token — collapsing
// them corrupts meaning. So the whitelist is strictly: articles + coordinating
// conjunctions (never a sentence's last word) plus first-person openers
// ("i"/"i'm"/"i've"/"i'll", which start clauses and essentially never end one).
// Everything else — pronouns, auxiliaries, prepositions — is left alone, as are
// intentional doublings ("blah, blah", "no, no", "twenty, twenty"). Looped so a
// triple restart ("the. the. the") fully collapses.
const STUTTER_WORDS = new Set([
  "a", "an", "the", "and", "but", "or", "nor", "i", "i'm", "i've", "i'll",
]);
function collapseStutter(text) {
  const word = "[a-z][a-z'’]*";
  let prev;
  do {
    prev = text;
    text = text.replace(
      new RegExp(String.raw`\b(${word})\s*[.?!,…]\s+(\1)\b`, "gi"),
      (m, w) => (STUTTER_WORDS.has(w.toLowerCase()) ? w : m)
    );
  } while (text !== prev);
  return text;
}

// --- Step 6: peel trailing standalone filler ("thank you" / bare "you") --
// End-anchored, so it only ever fires on the LAST tokens, and only when they
// are preceded by a sentence boundary or the string start (a standalone
// segment). "...to thank you" (no boundary before "thank") and "i love you"
// (no boundary before "you") are structurally safe. Looped to unwind stacks.
function peelTrailingFiller(text) {
  let prev;
  do {
    prev = text;
    text = text.replace(
      /(^|[.!?…]|\*[^*]*\*)\s*(?:thank\s*you|you)\.?\s*$/i,
      (match, boundary) => boundary
    );
  } while (text !== prev);
  return text;
}

// --- Step 7: peel a leading standalone "thank you." ----------------------
// ONLY a leading "thank you" that is its own period-terminated segment with a
// real word after it ("thank you. perhaps ..."). The mandatory period is the
// discriminator: "thank you for ...", "thank you everyone ..." have no period
// and are never touched. Bare leading "you." is deliberately NOT stripped (too
// ambiguous with a real terse answer). Looped to unwind stacks.
function peelLeadingFiller(text) {
  let prev;
  do {
    prev = text;
    text = text.replace(/^\s*thank\s*you\.\s+(?=[a-z])/i, "");
  } while (text !== prev);
  return text;
}

// --- Step 8: strip an isolated mid-record standalone "thank you." --------
// A "thank you." wedged between a real sentence boundary on the left and a real
// lowercase continuation on the right ("...nsfw data. thank you. and..."). The
// mandatory period after "thank you" means "thank you bro/everyone/claude" (a
// real address with no period) is never touched. Looped so adjacent runs fully
// collapse and the result is idempotent.
function stripMidRecordFiller(text) {
  let prev;
  do {
    prev = text;
    text = text.replace(
      /([.!?…]|\*[^*]*\*)\s+thank\s*you\.(?=\s+[a-z])/gi,
      "$1"
    );
  } while (text !== prev);
  return text;
}

// --- Step 9: whole-record emptiness + final trim -------------------------
function emptinessNormalize(text) {
  // Trim whitespace and now-orphaned leading/trailing space/comma/dash runs —
  // never a real trailing sentence period.
  text = text.replace(/^[.,\-\s]+/, "").replace(/[\-,\s]+$/, "");

  // Emptiness test on a throwaway string: if the ONLY content was filler
  // (thank you / you / sound-tags / punctuation), the whole record was silence.
  const stripped = text
    .replace(/\bthank\s*you\b/gi, "")
    .replace(/\*[^*]*\*/g, "")
    .replace(/\byou\b/gi, "")
    .replace(/(?<![\w-])u[hm]+(?![\w-])/gi, "")
    .replace(/[.\-,*\s]/g, "");
  if (stripped === "") return "";

  return text;
}

// Joined-string cleanup (steps 2-9), run on the lowercased+acronym-restored
// string. Returns the cleaned string WITHOUT the trailing space.
function structuralCleanup(text) {
  text = stripAsteriskTags(text); // step 2
  text = deleteLoneMarkers(text); // step 3
  text = stripSpokenFillers(text); // step 3b
  text = whitespaceSqueeze(text); // step 4
  text = collapseWordDuplication(text); // step 5
  text = collapseStutter(text); // step 5b
  text = peelTrailingFiller(text); // step 6
  text = peelLeadingFiller(text); // step 7
  text = stripMidRecordFiller(text); // step 8
  text = whitespaceSqueeze(text); // step 9a
  text = emptinessNormalize(text); // step 9b/c
  return text;
}

// Lowercase-with-acronym-restore + dictionary replacement (original behavior).
function lexicalNormalize(text) {
  const dictionary = loadDictionary();

  // Find all-caps words (2+ letters) before lowercasing so we can restore them.
  const acronyms = [];
  text.replace(/\b[A-Z]{2,}\b/g, (match, offset) => {
    acronyms.push({ word: match, offset });
  });

  // Lowercase everything.
  let result = text.toLowerCase();

  // Restore acronyms at their original positions.
  for (const { word, offset } of acronyms.reverse()) {
    result = result.slice(0, offset) + word + result.slice(offset + word.length);
  }

  // Apply dictionary replacements. Keys starting with "_" are comments
  // (dictionary.example.json uses "_readme" keys), not replacements.
  for (const [wrong, right] of Object.entries(dictionary)) {
    if (wrong.startsWith("_")) continue;
    const escaped = wrong.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    // Word-boundary anchored so a short/common key ("bow") only matches the
    // standalone word, never a substring inside another ("rainbow", "elbow").
    result = result.replace(new RegExp(`\\b${escaped}\\b`, "gi"), right);
  }

  return result;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// postprocess: the single cleanup entry point for /transcribe. Lexical
// normalize -> structural cleanup -> re-append the single trailing space the
// app expects. A whole-record silence-garbage input cleans down to ""
// (returned as "", not a lone space).
function postprocess(text) {
  const lexical = lexicalNormalize(text);
  let cleaned = structuralCleanup(lexical);
  if (cleaned === "") return "";
  // Drop a single trailing sentence period for a casual, chat-style feel. Keeps
  // "?" and "!" (they carry tone) and every internal period (so a multi-sentence
  // dictation still reads as sentences). Only a "." right after a word char — never
  // an ellipsis ("toss...") or a decimal.
  cleaned = cleaned.replace(/(?<=[a-z0-9])\.$/, "");
  return cleaned + " ";
}

// Human-readable manifest of the active rules, surfaced in the app's "Cleanup
// Rules" viewer. These are the shipped, mechanical rules — the SAME for everyone.
// Your personal word-fixes live in the Dictionary (its own panel + dictionary.json),
// NOT here, even though lexicalNormalize applies them in the same pass.
// Keep in sync with the functions above + POSTPROCESS.md.
const RULES = [
  { section: "Style", name: "Lowercase + acronyms", desc: "Lowercases everything, but keeps real acronyms (NASA, HTTP)." },
  { section: "Remove noise", name: "Strip fillers", desc: "Removes uh / um and elongations (umbrella, uh-oh survive)." },
  { section: "Remove noise", name: "Strip sound-tags", desc: "Removes *laughs*, *music* event tags." },
  { section: "Remove noise", name: "Delete lone marks", desc: "Removes a stray space-bounded . or - (decimals, u.s., ellipses safe)." },
  { section: "Fix repetition", name: "Collapse word echo", desc: "\"ideas. ideas in there\" → \"ideas in there\"." },
  { section: "Fix repetition", name: "Collapse restart-stutter", desc: "\"i like the. the plan\" → \"i like the plan\"." },
  { section: "Silence hallucination", name: "Peel \"thank you\"", desc: "Removes ASR's silence-invented \"thank you.\" — leading, trailing, and mid-record." },
  { section: "Finalize", name: "Whitespace squeeze", desc: "Collapses extra spaces; removes space before punctuation." },
  { section: "Finalize", name: "Emptiness normalize", desc: "If only filler remained, it was silence → nothing pasted." },
  { section: "Finalize", name: "Drop trailing period", desc: "Removes the final sentence period for a casual feel (keeps ? ! and internal periods)." },
  { section: "Finalize", name: "Trailing space", desc: "Ends with a space so dictations join cleanly." },
];

module.exports = { postprocess, RULES };
