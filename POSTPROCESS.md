# Post-processing rules

Every transcription passes through `Sources/Postprocessor.swift` before it is
pasted. The pipeline is **deterministic string surgery — it never rewrites your
words with an LLM.** It only removes mechanical dictation artifacts and applies
your dictionary.

Edit the Swift implementation by hand or via your agent. After a change, run:

```sh
swift test --filter PostprocessorTests
```

The 81 fixtures in `Tests/Fixtures/postprocess.json` verify behavior rather than
source structure, and each is checked for idempotency
(`process(process(x)) == process(x)`). The suite also locks in near-misses that a
rule must not alter.

---

## Pipeline order

```text
process(text)
  ├─ lexicalNormalize  → lowercase (acronyms preserved) + dictionary replacement
  └─ structural rules  → the ordered steps below, with no trailing whitespace
```

Lexical normalization runs first so structural rules see lowercased text. Some
structural rules loop to a fixpoint.

---

## A. Lexical — `lexicalNormalize`

**Lowercase with acronym restore.** All-caps words (`\b[A-Z]{2,}\b`, e.g. `NASA`,
`HTTP`) are noted, the text is lowercased, then those acronyms are restored at
their original offsets. This enforces a lowercase house style while keeping real
acronyms uppercase.

**Dictionary replace.** This is the one step driven by **your personal data**, not
shipped code — it's the Dictionary you manage from the menubar (its own panel), so
it does **not** appear in the app's "Cleanup Rules" list. It runs here only because
lexicalNormalize is the natural place to do word-level fixes.

Each `dictionary.json` entry `"heard": "meant"` is applied **word-boundary
anchored** — `\b<escaped>\b`, case-insensitive. The `\b` matters: without it,
a short key like `cel` would corrupt `cancel`/`excel`. Keys starting with `_` are
treated as comments, not rules.
- e.g. `wisper → whisper`, `get hub → github`. See [dictionary.example.json](dictionary.example.json).

---

## B. Structural cleanup

### Step 2 — strip asterisk sound-tags
`/\*[^*\n]*\*/g → ""`
Removes ASR "sound events": `*laughs*`, `*sad music*`.
`"that's funny *laughs* anyway" → "that's funny  anyway"` (whitespace squeezed later).

### Step 3 — delete lone floating periods / dashes
`/(?:^|(?<=\s))[.\-](?=\s|$)/g → ""`
Deletes a `.` or `-` that is **space-bounded on both sides** (a stray fragment).
Immune because they always have a non-space neighbor: decimals (`4.7`),
abbreviations (`u.s.`), ellipses (`toss...`), hyphenated compounds (`in-depth`).
`"the plan . we ship" → "the plan we ship"`

### Step 3b — strip spoken fillers (uh / um)
core token `FILLER = (?<![\w-])u[hm]+(?![\w-])` (matches `uh`, `um`, `uhh`, `umm`, `uhm`…)
Real disfluencies, always safe to drop. Fenced against letters/hyphens so
`umbrella`, `human`, `number`, and `uh-oh` survive. Also swallows one adjacent
comma so `"so, uh, yeah" → "so, yeah"` (not a double comma). **Looped** so runs of
fillers fully unwind.

### Step 4 / 9a — whitespace squeeze
`/[ \t]{2,}/g → " "` and `/\s+([.,!?…])/g → "$1"`
Collapse multiple spaces; remove space *before* punctuation. Runs after step 3b
and again at the end.

### Step 5 — collapse single-word boundary echo
`/\b([a-z]{4,})\.\s+\1\b(?=([.,]?\s+[a-z]|[.,]?\s*$))/g → the word`
`"ideas. ideas in there" → "ideas in there"`. Guards: word must be **≥4 letters**
(skips `it. it` / `is. is` function-word collisions); a hard `DEDUP_STOPLIST`
(`okay, yeah, that, path, testing, exactly, sure, really, thanks, good, hello,
wait, stop, done`) of real enumerations; bail if the 2nd copy is followed by a
comma; **identical backreference** so phonetic mid-word splits (`outline. line`)
never match. No `i` flag — a repeated uppercase acronym (`HTTP. HTTP`) is left
alone. Looped for triplets.

### Step 5b — collapse restart-stutter
`/\b(${word})\s*[.?!,…]\s+(\1)\b/gi` where the word is in `STUTTER_WORDS`
`"i like the. the incumbents" → "i like the incumbents"`. The punctuator closes a
"sentence" on a think-pause, leaving the restarted word
straddling a mark. Whitelist is **strictly** words that can never legitimately end
a sentence: articles + coordinating conjunctions + first-person openers —
`a, an, the, and, but, or, nor, i, i'm, i've, i'll`. Everything else (pronouns,
auxiliaries, prepositions, and intentional doublings like `blah, blah` / `no, no`)
is left alone. Looped so `the. the. the` fully collapses.

### Preserving spoken “thank you”

The previous pipeline deleted standalone `thank you` segments as presumed silence
hallucinations. Real use proved that unsafe: a spoken closing “thank you” was
removed from transcription 14627. Native cleanup therefore preserves `thank you`
and bare `you` everywhere. Ambiguous speech is kept rather than silently erased.

### Emptiness normalize

Trims orphaned leading/trailing space, comma, and dash runs. It returns `""` only
when nothing remains after unambiguous noise removal (sound tags, spoken
`uh`/`um`, and punctuation). Meaningful words are never used as a silence signal.

---

## C. Drop the trailing sentence period

`/(?<=[a-z0-9])\.$/ → ""` — the final `.` is removed for a casual, chat-style feel.
`"that's the ball game." → "that's the ball game"`. `?` and `!` are kept (they carry
tone), as is every *internal* period, so a genuinely multi-sentence dictation still
reads as sentences. The lookbehind means an ellipsis (`toss...`) or decimal is never
touched. When dictations are chained, the paste layer inserts the separator before
the next transcript.

## D. Joining at the cursor (not a cleanup rule)

`postprocess` emits **no trailing space**. The app decides how to attach a
dictation to whatever is already before the cursor: a chained dictation that lands
right after a word gets `". "` (closing the previous one — `"there. how"`), text
after `.!?` or a comma gets `" "`, and a cursor already sitting on whitespace or an
empty field gets nothing. When a terminal or Electron control does not expose
cursor text through Accessibility, WhisperOwn remembers the prior dictation in the
same application. After a word it types the period directly, then pastes a plain
leading `" "` plus the next transcript; this avoids CMUX rendering a period inside
the clipboard payload as `" ."`. Ordinary keyboard input or switching applications
resets that fallback. Globe presses and clicks that remain in the same application
preserve it. It never emits trailing whitespace.

This lives in the app, not here, on purpose. An earlier design appended a trailing
space and then *backspaced it away* to make the inserted period hug the word — but a
synthesized delete that loses the race leaves `"there . how"`. Emitting nothing to
delete removes the failure entirely.

---

*Editing tip: add the smallest fenced rule that fixes your case, add fixtures for
both the desired behavior and a near-miss it must not touch, then run the focused
Swift suite. The near-miss is what stops a rule from over-reaching.*
