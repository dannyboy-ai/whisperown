# Post-processing rules

Every transcription passes through `backend/postprocess.js` before it's pasted.
The pipeline is **deterministic string surgery — it never rewrites your words with
an LLM.** It only removes artifacts real dictation produces (silence
hallucinations, fillers, stutters, echoes) and applies your dictionary.

**How to manage these:** edit `backend/postprocess.js` by hand or via your LLM —
each rule below maps to one commented function. After any change, run the guard:

```sh
node backend/postprocess.test.js      # 154 fixtures — this is the real check
```

The fixtures verify *behavior*, not structure, and every rule is **idempotent**
(`postprocess(postprocess(x)) === postprocess(x)`). If a fixture goes red, you
broke the case in its comment. This test — not a rule count — is what keeps edits
honest.

---

## Pipeline order

```
postprocess(text)
  ├─ lexicalNormalize   → lowercase (acronyms preserved) + dictionary replace
  └─ structuralCleanup  → steps 2–9 below, then a single trailing space
```

`lexicalNormalize` runs first (so structural rules see lowercased text), then the
structural steps run in this exact order (some loop to a fixpoint):

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
anchored** — `new RegExp(\`\\b${escaped}\\b\`, "gi")`. The `\b` matters: without it,
a short key like `cel` would corrupt `cancel`/`excel`. Keys starting with `_` are
treated as comments, not rules.
- e.g. `wisper → whisper`, `get hub → github`. See [the dictionary](../dictionary.example.json).

---

## B. Structural — `structuralCleanup` (steps 2–9)

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

### Steps 6–8 — the "thank you" silence hallucination
ASR invents `"thank you."` on silence. The discriminator is that a **hallucinated**
one is always its own period-terminated segment, while a **real** one flows into a
sentence (`thank you for…`, `thank you bro`). So each rule only fires on a
standalone segment:
- **Step 6 — trailing:** `/(^|[.!?…]|\*[^*]*\*)\s*(?:thank\s*you|you)\.?\s*$/i` — peels a trailing `thank you`/bare `you` at the very end. `"...to thank you"` (no boundary before `thank`) and `"i love you"` (no boundary before `you`) are safe.
- **Step 7 — leading:** `/^\s*thank\s*you\.\s+(?=[a-z])/i` — peels a leading `thank you.` with a real word after. The mandatory period is the discriminator.
- **Step 8 — mid-record:** `/([.!?…]|\*[^*]*\*)\s+thank\s*you\.(?=\s+[a-z])/gi` — strips a `thank you.` wedged between a real boundary and a lowercase continuation. `thank you bro/everyone` (no period) is never touched.
All three are looped to a fixpoint.

### Step 9 — emptiness normalize
Trims orphaned leading/trailing space/comma/dash runs (never a real trailing
period). Then an **emptiness test** on a throwaway copy: if the only content was
filler (`thank you` / `you` / sound-tags / `uh`/`um` / punctuation), the whole
record was silence → returns `""` (the app pastes nothing).

---

## C. Drop the trailing sentence period

`/(?<=[a-z0-9])\.$/ → ""` — the final `.` is removed for a casual, chat-style feel.
`"that's the ball game." → "that's the ball game"`. `?` and `!` are kept (they carry
tone), as is every *internal* period, so a genuinely multi-sentence dictation still
reads as sentences. The lookbehind means an ellipsis (`toss...`) or decimal is never
touched. Trade-off: chaining several one-sentence dictations back-to-back yields no
separators — add periods by hand if you're composing a paragraph that way.

## D. Trailing space

`postprocess` appends a single trailing space to a non-empty result, so
consecutive dictations join cleanly and your cursor lands after the word — never
jammed against it.

---

*Editing tip: add the smallest fenced rule that fixes your case, add a fixture to
`postprocess.test.js` capturing both the fix AND a near-miss it must NOT touch,
then run the suite. The near-miss fixture is what stops a rule from over-reaching.*
