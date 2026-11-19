# AI writing and translation

Status: Implemented — not yet verified on a device
Related: `docs/ios-intelligence.md` ("Translate a selection", "One model layer"), `ios-app/HeyPigeon/Features/Compose/AIAssist.swift`

## What and why

Translation and the composer's assistant worked and were not usable: a
translation came back in two languages, and a rewrite was weak. Both went
through one generic call, `ai_edit_text`, whose prompt says "the sender's
own draft, keep its language, keep the sender's voice", answered by
default by the small on-device model, whole, at default sampling. Each
task now has its own call and instruction, and translation goes to
Apple's translation models first.

**Out of scope:** translating a whole message or a thread in place;
streaming; a sample of the user's sent mail as a voice reference; sending
a request to a larger provider than the one the user picked (the panel
says when the on-device model is not made for a language, and Settings ›
AI is where the provider changes); changing the default keyed models.

## Behaviour

Translation (a selection in a received message):

- R1. The translate circle shows for every received message, with or
  without an AI provider.
- R2. The source language is detected on the device. A selection already
  in the language asked for is shown as it is: "already in <language>",
  nothing sent.
- R3. When Apple's translation has the language pair on the device, it
  translates, paragraph by paragraph, and nothing leaves the device. A
  pair it supports but has not downloaded gets the system's download
  sheet once per panel; declined, the request goes on to R4.
- R4. Otherwise the AI provider translates through `ai_translate`: its
  own instruction, the source (when detected) and target by name, the
  passage fenced as material, exact decoding on the Apple models. With no
  provider the panel says one is needed.
- R5. On the on-device model the passage is sent in parts of at most
  1,200 characters, cut on paragraphs, then sentences, then words; parts
  appear as they arrive. Other providers get the selection whole (at most
  6,000 characters, as before).
- R6. A part whose answer still has a paragraph in the source language is
  asked again in smaller parts; the second answer is kept only when it is
  clean.
- R7. Every model request names the provider the privacy line was drawn
  from; when another one answers now, nothing is sent and Try again goes
  under the new line.
- R8. When the on-device model translated and is not made for the source
  or the target language, a line under the result says so.

The composer's assistant (phone sheet and Mac panel):

- R9. "Fix spelling and grammar" is `ai_proofread`: the text alone,
  corrected, nothing rephrased, exact decoding.
- R10. A new message from a brief is `ai_write_message`: the brief is a
  brief, not a draft; who writes to whom and the subject go with it.
- R11. The other presets, the tones and a typed instruction are
  `ai_edit_text` with an instruction that says what to change, how far
  and what must stay.
- R12. Both platforms send who writes to whom (`AIWriteContext`); the
  phone used to send none. The privacy line says so.
- R13. A writing or exact prompt is never split and its parts
  re-answered (that is for summaries). The core cuts the conversation to
  its newest messages that fit the provider; a draft that still does not
  fit the on-device model fails with a sentence.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`desktop-app/crates/core`, adapters) | nothing |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | `ai_translate`, `ai_proofread`, `ai_write_message`; their prompts; `CompletionStyle` on `AiBackend::complete`; `trim_history`; three more fields in `AiPrompts` |
| Shared shell (`ios-app/HeyPigeon`) | `AI/SystemTranslator.swift` (Apple's translation), `AI/Translation.swift` (codes, detection, parts, the language check), `TranslationPanel`, `AIAssist` presets and routing, `FoundationModelsBackend` (style → chunking and decoding) |
| iPhone / iPad only | `AIEditSheet` takes the `AIWriteContext` |
| Mac only (`macos-app/HeyPigeonMac`) | nothing |

Syncs between devices: no (the last target language stays per device, as before).
Leaves the device: nothing when Apple's translation answers or the
selection is already in the language — "Translated on this <device> by
Apple's translation. Nothing left the device." With a model: the selected
text, to the provider the line names, as before. The assistant's line
lists the text, the instruction, the conversation and now, on the phone
too, who is writing to whom.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | sheet | popover | popover |
| Entry points | translate circle beside a selection; sparkle in the composer | same | same; ⌘J in the composer |
| Settings | Settings › AI (provider) | same | same |
| Status | built, CI | built, CI | built, CI |

## Platform differences

None in behaviour. The simulator has no translation models, so there the
model route always answers (the tests run on it).

## Acceptance criteria

- [x] R2, R5, R6 — `TranslationTests` (`aPassageIsCutIntoPartsOnItsParagraphs`, `aParagraphLeftInTheSourceLanguageIsNoticed`, `aLanguageNameHasItsCode`)
- [x] R4, R9, R10, R13 — `settings.rs` `translate_proofread_and_write_go_out_under_their_own_prompt`, `each_text_task_has_its_own_prompt`, `a_long_history_keeps_its_newest_messages`
- [x] R7 — `aTranslationIsPinnedToTheProviderItsFootnoteNames`
- [x] R8 — `theOnDeviceModelsRoughLanguageIsNamed`
- [x] R9, R10 routing — `AIAssistTests.proofreadingAndWritingHaveTheirOwnCalls`
- [x] `MockEngine` covers the new operations
- [ ] R3 — needs a device: Apple's translation does not run in the simulator
- [ ] Quality on the model — `WritingEvaluation.scoreTranslationAndEditsOnDevice`, on a device with Apple Intelligence
- [ ] `rust-ci`, `ios-ci`, `macos-ci` green

## Open questions / assumptions

- The Translation framework's default strategy is assumed to translate on
  the device (`TranslationSession(installedSource:target:)`); the privacy
  line depends on it. Check Apple's wording for the iOS 27 `Strategy`
  options before changing the strategy.
- The language check (R6) uses NaturalLanguage; close languages (Slovak
  and Czech) can be mistaken for each other, which costs one more request,
  never a wrong result.
- The assistant's privacy line lists the most a tap sends; proofreading
  sends less (the text alone).

## Verification

Not verified on a device yet: the Rust tests pass locally; the Swift was
written without a compiler and is checked by `ios-ci` / `macos-ci`.
