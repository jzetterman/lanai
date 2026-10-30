# User docs in ASD-STE100

Small tier: one combined spec and plan. It changes `README.md` and
`docs/guide.md` on the `readme-cut` branch (PR #24).

## Problem

John asked (2026-10-29, EDT) that all user-facing docs use ASD-STE100
(Simplified Technical English, STE). The README and the user guide do not. The
guide has long sentences, passive voice, `-ing` forms, semicolons, and
paragraphs of up to 20 sentences. Some README sentences break the same rules.

The user-facing docs are `README.md` and `docs/guide.md`. `docs/development.md`
is for contributors, and the specs and plans are for the project's own work, so
they are out of scope. App strings (button labels and the panel's words) follow
the repo's rules, not this task.

The reference is ASD-STE100 Issue 9 (2025), the free PDF from
<https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf>. It holds the
writing rules (part 1) and the dictionary (part 2). The PDF is not added to the
repo. Rule numbers below are Issue 9's.

## Requirements

1. **STE writing rules.** Both files follow every writing rule in Issue 9 part 1.
   The rules that these docs break most often:
   - Words (section 1): use approved words only as their part of speech and with
     their approved meaning (1.2, 1.3). Technical nouns (1.5) and technical verbs
     (1.12) are allowed, such as Lanai, QEMU, btrfs, file names, "boot", "click"
     and "install". Do not use a technical noun as a verb (1.7) or a technical
     verb as a noun (1.13). A word can be both only when it fits a technical
     noun category and a technical verb category (as "update" does), with one
     `TECH` entry for each part of speech. Use a technical verb only when no
     approved verb gives the same information (1.12), so a `TECH` entry for a
     word that the dictionary lists as unapproved says why its STE alternative
     does not fit. Use one
     technical noun for one item (1.11). Use American spelling (1.14).
   - Noun clusters of at most 3 words (2.1).
   - Verbs (section 3): only the infinitive, imperative, simple present, simple
     past, simple future and the past participle as an adjective (3.2). No
     complex auxiliary forms (3.4), such as "has stopped". The `-ing` form of a
     verb only as a technical noun or in one (3.5). The approved words with an
     `-ing` form (such as "during", "missing", "remaining", "something") are
     allowed. Active voice. Passive only in descriptive text when the agent
     is unknown (3.6).
   - Sentences (section 4): no omitted words, no contractions (4.2). Vertical
     lists for complex text (4.3). Articles before nouns where applicable (4.5).
   - Procedures (section 5): at most 20 words (5.1). The limit also applies to
     every sentence of a warning, caution or other safety instruction. One instruction per
     sentence, unless the actions occur at the same time (5.2). The imperative
     (5.3). A condition the reader must know first starts the sentence and a
     comma divides it from the command (5.4). Notes give information, not
     instructions (5.5).
   - Descriptions (section 6): at most 25 words (6.3). One topic per paragraph
     (6.5). At most 6 sentences per paragraph (6.6). A lead-in sentence and its
     list count as one sentence of the paragraph, as in the 6.6 example. Each
     list item is a sentence for length only (8.4).
   - Safety (section 7): each safety instruction names its risk level (7.1),
     starts with a clear command or condition (7.2), and says the risk or
     result (7.3). STE uses "Warning" for a risk of injury or death and
     "Caution" for a risk of damage, so no case here is a "Warning". The
     data-loss cases are a forced stop and a restore. In the guide, each gets a
     caution with the result the guide gives. The writer also checks the
     guide's removal sentences on `VirtioFsSvc` and the driver removal against
     section 7, since nothing saved the earlier settings. Project choices, not
     STE rules:
     - In the README, the restore line and "Do not click **Shut down** unless
       ..." stay plain instructions, since the README gives no result for them
       (John, 2026-10-29, EDT).
     - In the guide, shutting down while `setup.cmd` runs also gets a caution,
       with the result the guide gives (setup stops, and the user chooses how
       to go on).
     - Starting the container while Lanai runs stays a plain instruction where
       its file gives no result (the README). The guide's caution says only
       what the guide says (the start fails safely with the verified dockur
       behavior, and future dockur changes remain a risk).
     - Each caution comes before the step it applies to, in the form
       `**Caution:**` at the start of a paragraph or list item.
   - Punctuation and counts (section 8): no semicolons (8.1). Parentheses only
     for the uses in 8.3. Count words by 8.4 to 8.7: a colon in a vertical list
     ends a sentence. Each of these counts as one word (8.6, 8.7): a number, a
     number with its unit, an abbreviation, an alphanumeric identifier, quoted
     text, a title, heading or label, a proper noun of a person, group,
     organization or place, and a hyphenated word. Link text that names a
     heading kept by requirement 4 is a title.
     Text in parentheses counts as one word in its sentence, and is also a
     sentence of its own with the same limit (8.5). A project rule: a product
     name with more than one word ("Looking Glass", "Windows PowerShell") also
     counts as one word.
   - Style (section 9): no phrasal verbs (9.3), such as "go on", "set up" or
     "turn off" used as a verb, except the few the dictionary approves, in
     their approved meaning. A consistent style (9.4).
   - Technical verbs chosen for these docs (1.12): "click", "boot", "install",
     "download", "shut down", "sign in" and "sign out". The dictionary gives
     STOP for "shut down", but STOP would merge the clean **Shut down** with
     **Force stop**, so "shut down" stays a technical verb.
2. **Protected text.** These stay as they are, and count as one word each:
   - Lanai UI names: bold or quoted text that is a whole string in the app
     (`LanaiPanel.qml`, `Widget.qml`, `lib/*.sh`), such as **Continue setup**.
     Plain-text UI names come only from a hand list, the `UI` table, which
     starts with "Shut down" and the Verify rows "Display driver", "Windows
     agents", "Scale task" and their states "Not checked", "Waiting", "Done"
     and "Failed", and the six step names Check, Packages, Snapshot, Prepare,
     Drivers and Verify. A trailing period inside bold ("**Verify.**") is
     stripped before the match. A plain word that is also an app string ("Restore" at the
     start of a sentence) is ordinary prose.
   - Names that are not Lanai's: Windows labels ("Installed apps", "Device
     Manager", "Settings > System > Display > Scale", "Smart App Control",
     "Command Prompt" and the others the writer finds), Looking Glass labels
     ("Capture Enabled", "Capture Disabled") and key names (Enter, Escape,
     Space, Tab, Scroll Lock, Fn). They go in the `UI` table too.
   - Code spans, fenced code blocks, paths, URLs and link targets.
   Bold text that is not a UI name is emphasis, and the writer can change it.
   Link text is ordinary prose and counts word by word.
3. **No fact lost or changed.** Every fact, step, warning, number, limit and
   condition in each file stays in that same file. No content moves between the
   README and the guide, so the README keeps what `docs/plugin/spec.md` (the
   paragraph after requirement 32) says it must hold. A caution can gain its
   risk word and result (requirement 1, section 7) only from what its own file
   already says.
4. **Anchors and links.** The headings that another file links to keep their
   text, so those links resolve: README "Requirements" and "Install", and guide
   "Daily use", "Removal" and "Windows lock and trust exposure" (the set
   `link_check.py` finds across the repo). They are the one exception to
   requirement 1. Every other heading follows requirement 1, and the links to
   it in its own file (such as the guide's contents list) change with it.
5. **Length.** The README aims to stay at or below 180 lines (160 today). The
   guide may grow, since lists and short sentences take more lines.
   Requirement 3 wins over this one: if the README needs more than 180 lines to
   keep every fact, the writer keeps the facts and reports the count to John.
6. **Unslop.** No em dashes and no AI tells, per John's standing rule. No new
   tables.

## Acceptance criteria

- `ste_check.py` passes its fixtures. On both files it reports no hard fail: a
  sentence over its limit, a paragraph over 6 sentences, a semicolon, em dash
  or contraction in prose, or a word that is not an approved form, a `TECH`
  entry or protected text.
- Its review list (below) is empty, or each listed item is fixed or covered by
  a `KEEP` entry with a reason.
- `fact_check.py` passes its fixtures. For each file, no protected item or
  number occurs fewer times after than before, and each item that occurs more
  times has a reason in its `MORE` table.
- `link_check.py` (from the README cut) reports 0 broken links and anchors in
  `README.md`, `docs/guide.md`, `docs/development.md` and `docs/plugin/spec.md`.
- A reviewer reads the before and after side by side and finds no fact lost,
  added or changed in meaning. The reviewer also reads the whole after text
  against every rule in Issue 9 part 1, since the scripts check only part of
  it, and checks each caution against section 7 and each `TECH`, `TYPE`,
  `KEEP` and `MORE` entry for its reason.

## Plan

The checks are scratchpad scripts, not repo files, like the README cut's
checks. They live in
`/tmp/claude-1000/-home-john-Development-github-jzetterman-windows-on-omarchy/932cdcfe-2d78-4113-bd9b-215209d544a0/scratchpad/ste-docs/`.
The PDF and its text (`pdftotext -layout`) are in `../ste-ref/`. The old
versions of the docs are the files at the branch head before this task
(1df589c).

The scripts have two kinds of output. A hard fail is something a script can
judge exactly. A review item is a likely problem that needs a person, and the
script lists each one with its sentence.

1. **Fixtures first, then the checks.** Write each script's fixtures, see them
   fail, then write the script, then run it on today's files for a baseline.
   - `ste_check.py <file>...`:
     - Prose: skips fenced code blocks, protected text and the linked headings
       of requirement 4. Other headings are checked as titles.
     - Words: counts by requirement 1, section 8, and requirement 2.
     - Sentence type: a sentence is a procedure when it sits in a numbered
       step, sits in a caution, or has a command at the start of any clause
       (the start of the sentence, after a leading adverb such as "Then" or
       "Always", after "Do not", after any comma, or after "then"). A command is the base form
       of any verb, approved, unapproved or `TECH`. This errs to the stricter
       20-word limit, and a `TYPE` entry can set a sentence's type by hand,
       with a reason. Any other sentence is descriptive. Text in parentheses
       is checked again as its own sentence, with the type of the sentence
       around it.
     - Dictionary: parses the approved headwords with their listed forms, and
       the unapproved headwords with their STE alternative, including
       multi-word headwords (such as MAKE SURE, PUT ON, `shut down`, `turn
       off`), matched as phrases. The regular plural of an approved noun is
       approved, as part 2's "Forms of approved words" says, unless its entry
       says otherwise. A `TECH` entry names a word or phrase, its one part of
       speech and its 1.5 or 1.12 category, and accepts its `-s` and `-ed`
       forms. A hard fail names the word and prints its STE alternative. A
       phrasal headword also matches with up to 4 words between the verb and
       its particle ("turns the Windows lock off" matches "turn off"). The
       parser's totals must equal part 2's counts: 875 approved and 1274
       unapproved words.
     - Review items: a word with an approved entry in one part of speech and
       an unapproved entry in another (about 27 in these docs, such as
       "check", "use", "then", "as", "finish"), unless a `TECH` entry covers
       it; words in a small `RESTRICTED` table ("about", "since", "then" for
       "so"); `-ing` forms that are not approved words; passives (a form of
       "be" plus a past participle); parentheses; and phrasal verbs from a
       list ("go on", "set up", "turn off", "find out", "come back" and others
       the writer finds). A `KEEP` entry names a word and its kept sense once
       (for example "then: adverb, next in time"), and the script lists every
       occurrence it covers for the review.
     - Fixtures that must fail: the guide's "When the check could not run
       ..." sentence (a procedure over 20 words); a 26-word descriptive
       parenthesis; a 21-word sentence in a caution; "If the panel names X, Y
       or Z, click W" at 21 words; a paragraph of 7 sentences; a semicolon; an
       em dash; "it's" and "that's"; "allow", which prints LET; "About 1 GB"
       with no `KEEP` entry; "turns the Windows lock off".
     - Fixtures that must pass: a parenthesis counts as one word in its
       sentence; a list lead-in colon ends a sentence; "steps" as the plural
       of STEP; "approximately"; "In the setup window, open ...", "Then
       start ... again" and "Do not start ..." at 20 words each, typed as
       procedures; the possessives "Lanai's" and "Windows'"; the quoted panel message with "You'll" (guide, Setup in
       Windows), skipped as protected; "click" with its `TECH` entry.
   - `fact_check.py <old> <new>`: extracts the protected text of requirement 2
     and every number, and counts each item's occurrences. A number is a
     numeral with its unit when it has one ("2 minutes" is one item, and "two
     minutes" is the same item), or "once" as an adverb and "one time" (1
     time) or "twice" and "two times" (2 times). Singular and plural units,
     the hyphen form ("20-second" is "20 seconds") and each end of a range
     ("11–13 seconds" or "11 to 13 seconds") are the same item. "Once" as a
     conjunction ("Once setup finishes"), "one" as a pronoun and list markers
     are not numbers; a sentence-initial "Once" goes on the review list. Other number words ("six", "half") go on the review list for
     the side-by-side read. A count that goes down is a hard fail. A count
     that goes up is a hard fail unless its `MORE` table gives a reason.
     - Fixtures that must fail: a changed character in the
       `DisableLockWorkstation` command; one of several **Continue setup**
       labels dropped; the setup limit changed from 2 minutes to 5 minutes
       while both numbers occur elsewhere; "twice" changed to "one time"; a
       repeated label with no `MORE` reason.
     - Fixtures that must pass: a reworded prose line with every item kept;
       "once" changed to "one time"; "Once setup finishes" changed to "When
       setup finishes"; "1–64 cores" changed to "1 to 64 cores".
2. **Rewrite the README.** One section at a time, then run the three checks.
3. **Rewrite the guide.** One section at a time, then run the three checks.
   Break long paragraphs into short paragraphs or lists under the same
   headings.
4. **Diff gate.** The step-4 gate on the diff. The checks' final output goes in
   the PR body with the gate log.

The writer is a Claude subagent on the bulk taste worker row (opus-5.5), since
the output is judged on its prose. It reads Issue 9 part 1 in full before it
starts.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| Doc | a (gpt-6.1-sol) | 1 | 10 P2, all confirmed against Issue 9 and integrated; the reviewer's PDF link also gave the plan the real dictionary |
| Doc | a (gpt-6.1-sol) | 2 | 4 P2, all confirmed against Issue 9 (rules 5.1 and 8.5, part 2's noun forms) and integrated |
| Doc | a (gpt-6.1-sol) | 3 (cap) | 3 P2, 2 P3, all confirmed and integrated (occurrence counts, a full part 1 review, setup.cmd shutdown as a caution, the approved `-ing` words and phrasal verbs) |
| Doc | b single (opus-5.5) | 1 | 9 should-fix, 3 nits, 0 refuted; all integrated |
| Doc | b single (opus-5.5) | 2 | 9 should-fix, 6 nits, 0 refuted; all integrated, and the checks split into hard fails and a review list to stop them growing |
| Doc | b single (opus-5.5) | 3 (cap) | 6 should-fix, 8 nits, 0 refuted. John chose plain instructions for the README's restore and setup.cmd lines (finding 6); all 14 integrated |
| Doc | John | - | Gate closed at the cap; start the rewrite (2026-10-29, EDT) |
