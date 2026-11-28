# Annotated slide rehearsal implementation plan

**Goal.** Import a presenter's script and optional static Keynote PDF export once. Rehearse a section across several slides with legible directions and the actual artwork.

**Design.** A line beginning with `# ` starts a logical section. A line beginning with `## ` starts a slide. Its title is the author's own label. With a PDF selected, pair its first page with the first slide heading and continue in document order across sections. A prefix or section heading consumes zero pages. One presenter can import their own excerpt without supplying the rest of the deck or the original page numbers. The user supplies all directions. Follow the [MVP design](../specs/2026-11-25-spelum-mvp-design.md) and [contributor guide](../../../AGENTS.md).

**Architecture.** Derive display and spoken text from preserved script source. Keep slide/page associations with the revision that owns them. Use SwiftUI, SwiftData and Apple PDFKit on iPhone, offline. Use synthetic English test material. Private decks and scripts stay outside the repository and PR.

## 1. Parse once and keep the original

- [ ] Add a shared annotated-script parser under `Spelum/Library/`. Cover multiple sections, slides without an explicit section, LF/CRLF, leading text, empty or repeated titles, adjacent markers, literal hashes in prose, URLs and ordinary slashes in words. Preserve source text including blank lines. Plain scripts, including existing stored sections, remain usable.
- [ ] Recognize bracketed directions, short/medium/long pauses and pitch arrows, including a slash touching terminal punctuation. Treat unmatched delimiters as literal text. Derive spoken text and the first/last spoken lines for preview, handoff and transcript alignment. Preserve existing timing analysis of stage directions. Use the same interpretation in `EnglishWordTokenizer.swift` and `PresentationStoreHandoff.swift`.
- [ ] Pin grouping and meaning with parser tests and a handoff ending in a bracketed direction. Keep exact phrases, cue words and editable raw text consistent with historic behavior.

## 2. Import and preview the pairing

- [ ] Extend `ImportScriptSheet.swift` and the shared paste/UTF-8 file path. Parse heading-based scripts even without a deck. Allow an optional PDF selected through Files. Preview page and heading counts, actual thumbnails, heading labels and the first spoken line for each row.
- [ ] For mismatches, identify unmatched pages/headings and permit correcting the script or replacing/removing the PDF before saving. Require one page per explicit slide for a paired import. Cover corrupt, empty and locked PDFs, canceled picks and retries without losing the draft or partially creating a talk.
- [ ] Use `PresentationStore.swift`, `PresentationModels.swift` and the revision mutation paths to save sections, original text and ordered slide references atomically. Copy the PDF to app-owned storage using an opaque name. Bound page rendering to visible pages/display size. Cover save failure, relaunch without the original file, edits/splits/reorders, deletion and old recordings that still reference earlier revisions. Verify the previous on-disk model opens with existing data.

## 3. Rehearse with the slide visible

- [ ] Use one shared native SwiftUI rehearsal component from `PracticeViewSections.swift`, `FullRunViewSections.swift` and `FullRunFullscreenScriptContent.swift`. Display the active PDF page at its own aspect ratio with a way to enlarge it. Keep artwork visible while long script content scrolls. Show the section and slide position. Keep the source editor verbatim.
- [ ] Use large primary text for speech, a distinct labeled block for speaker directions, and accessible inline pauses and pitch marks. Preserve cue-word and recall concealment, including spoken content exposed to VoiceOver. Preserve reveal counting and existing recording controls.
- [ ] Support starting at a chosen slide and rehearsing a whole section. In full run, advance through slides inside a section before advancing the section and its speaker. Keep the uninterrupted recording and historical section timeline coherent. Slides with only directions or no speech still have a place in the run.
- [ ] Test a synthetic PDF with a three-slide section, a second section and a long final demo slide. Assert that image and text move together across the section boundary in both directions where navigation is available and after toggling fullscreen. Reopen a previously recorded take after editing the talk.

## 4. Verify and deliver

- [ ] Use focused parser, store, full-run and analysis regressions first. Run `xcodebuild -list -project Spelum.xcodeproj`, pinned SwiftLint in strict mode, the full MyApp test scheme on iPhone 17 / iOS 27.0, and an unsigned generic iOS Release build as specified in AGENTS.md.
- [ ] Inspect import and rehearsal with light/dark appearance, accessibility text size and VoiceOver labels/navigation order. Include actual simulator/toolchain versions, executed checks and limits in the PR. Report physical iPhone and TestFlight verification separately.
- [ ] Review the diff against the three outcomes above and submit one PR based on main. Keep the feature separate from the merged fullscreen PR.
