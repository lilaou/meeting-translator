# Face-to-face partner language (Korean, Japanese, English) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the face-to-face screen the app's user (Chinese) can choose the other person's language: Korean, Japanese or English.

**Architecture:** `ConversationSide` gains `japanese` and `english`; "which two sides talk" becomes a value (`partner`) held by one visit. Changing the language ends the visit and builds a new one (new session, pack check and recorder), so no object ever changes its language. A small core model, `FaceToFaceModel`, owns that rule and is tested with fakes.

**Tech Stack:** Swift 6, SwiftPM package `Packages/MeetingCore`, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-28-face-to-face-languages-design.md` (addendum to `2026-11-27-face-to-face-design.md`)

## Global Constraints

- Partner is exactly one of Korean, Japanese, English; the user's side is always Chinese.
- Speech locales: `zh-CN`, `ko-KR`, `ja-JP`, `en-US`. Translation languages: `zh-Hans`, `ko`, `ja`, `en`. Checking, downloading and translating use one definition.
- Stored data keeps its shape: no schema change, no migration. `speakerCode` is `chinese`, `korean`, `japanese` or `english`; `languageCodes` is `["zh", "ko"|"ja"|"en"]`. Existing records display exactly as before.
- Default partner on first use: Korean. The last choice is remembered under the `UserDefaults` key `partnerLanguage`.
- The app never releases a reserved speech locale.
- Meeting captions are not changed.
- Swift 6, warnings are errors, no source file over 200 lines (`ConversationSession+Turn.swift` is already over; do not grow it), no third-party dependencies, no networking code.
- Core tests: `swift test --package-path Packages/MeetingCore` (this Mac has no iOS 26 SDK, so the app target is not built here; do not try).
- Commit messages end with:
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01A4t3X6uy1PL6VNA6nKj1ro`
- Do not read or commit `macbookair.md`. Do not connect to other machines. Do not push.

## Review Focus

1. Changing language while a pack install is running: the old job is cancelled and its late result changes nothing in the new visit.
2. A remembered value that is missing, unknown or `chinese`: the partner is Korean, never Chinese–Chinese.
3. A language change asked for while a turn is starting, listening or finishing (including one waiting for the foreground): nothing changes and nothing is lost.
4. History records written before this change (`korean`, `["zh","ko"]`): same labels and header as before.
5. An English or Japanese turn that fails: the partner half shows only its own language's fixed line; the reason appears only in Chinese.

---

### Task 1: Languages in the core

**Files:**
- Modify: `Packages/MeetingCore/Sources/MeetingCore/Conversation/ConversationLanguages.swift`, `ConversationPacks.swift`, `ConversationPacks+Jobs.swift`, `ConversationRecorder.swift`, `ConversationShownNotice.swift`
- Modify: `Packages/MeetingCore/Sources/MeetingCore/Presentation/TranscriptDocument.swift`
- Test: `Packages/MeetingCore/Tests/MeetingCoreTests/` — `ConversationLanguagesTests`, `ConversationPacksTests`, `ConversationPacksCancelTests`, `ConversationRecorderTests`, `ConversationNoticeTests`, `HistoryListTests`, `TranscriptExportTests`, plus the fakes they use

**Interfaces:**
- Produces:
  - `enum ConversationSide: String, Sendable, CaseIterable { case chinese, korean, japanese, english }`
  - `static let partners: [ConversationSide]` = `[.korean, .japanese, .english]`
  - `var speechLocale: Locale`, `var translationLanguage: Locale.Language`
  - `var chineseName: String` = `中文` / `韩语` / `日语` / `英语`
  - `var nativeName: String` = `中文` / `한국어` / `日本語` / `English`
  - `static func storedPartner(_ raw: String?) -> ConversationSide`
  - `func counterpart(partner: ConversationSide) -> ConversationSide` — `partner` for `.chinese`, else `.chinese`
  - `ConversationSide.other` is removed.
  - `ConversationPacks(checking:partner:)`, `let partner: ConversationSide`, `var all: [ConversationPack]` in the order speech(chinese), speech(partner), translation(from: chinese), translation(from: partner); `func target(from: ConversationSide) -> ConversationSide`
  - `ConversationRecorder(store:partner:now:)`

- [ ] **Step 1: Write the failing tests**

Update the existing tests to the new signatures (their Korean expectations stay as they are), and add:

```swift
@Test func partnersAndTheirLanguages() {
    #expect(ConversationSide.partners == [.korean, .japanese, .english])
    #expect(ConversationSide.japanese.speechLocale.identifier(.bcp47) == "ja-JP")
    #expect(ConversationSide.english.speechLocale.identifier(.bcp47) == "en-US")
    #expect(ConversationSide.japanese.translationLanguage == Locale.Language(identifier: "ja"))
    #expect(ConversationSide.english.translationLanguage == Locale.Language(identifier: "en"))
    #expect(ConversationSide.japanese.rawValue == "japanese")
    #expect(ConversationSide.english.chineseName == "英语")
    #expect(ConversationSide.chinese.counterpart(partner: .japanese) == .japanese)
    #expect(ConversationSide.japanese.counterpart(partner: .japanese) == .chinese)
}

@Test(arguments: [(nil, ConversationSide.korean), ("", .korean), ("chinese", .korean),
                  ("malay", .korean), ("japanese", .japanese), ("english", .english),
                  ("korean", .korean)])
func rememberedPartner(raw: String?, expected: ConversationSide) {
    #expect(ConversationSide.storedPartner(raw) == expected)
}
```

- Packs, partner `.japanese`: with nothing installed the step is `.missing([.speech(.chinese), .speech(.japanese), .translation(from: .chinese), .translation(from: .japanese)])`; the fake is asked for translation states `zh-Hans → ja` and `ja → zh-Hans` and for no other pair; `download()` installs `zh-CN` then `ja-JP`.
- Recorder with partner `.japanese`: the record's `languageCodes` is `["zh", "ja"]`, the turns' speaker codes are `chinese` and `japanese`. With `.english`: `["zh", "en"]`. With `.korean`: `["zh", "ko"]` (unchanged).
- Notice: for `.japanese` and `.english` sides, `.failed("x").shown(on: partner, speaker: partner) == .failed`, `.failed("x").shown(on: partner, speaker: .chinese) == nil`, and `.failed("x").shown(on: .chinese, speaker: partner) == .reason("对方这次出错了：x")`.
- History: a `["zh","ja"]` conversation has metadata `["语言：中文 ↔ 日语"]` (use whatever Chinese name `CaptionStrings.languageName` gives `zh`, as the existing Korean test does) and a `japanese` turn is labelled `日语方`; `english` → `英语方`; the existing Korean expectations are untouched.

- [ ] **Step 2: Run the tests and see them fail** (`swift test --package-path Packages/MeetingCore`; expected: compile errors naming the new members)
- [ ] **Step 3: Implement.** `speechLocale` for `.korean` stays `SourceLanguage.korean.locale`; `.chinese.translationLanguage` stays `TranslationTarget.language`. `ConversationShownNotice` treats every non-Chinese side as the Korean side is treated now. `TranscriptDocument` labels a known speaker `chineseName + "方"`.
- [ ] **Step 4: Run the whole test suite; all pass, no warnings.**
- [ ] **Step 5: Commit** `feat(core): Japanese and English as face-to-face partner languages`

---

### Task 2: The visit and the language change

**Files:**
- Create: `Packages/MeetingCore/Sources/MeetingCore/Conversation/FaceToFaceModel.swift`
- Test: `Packages/MeetingCore/Tests/MeetingCoreTests/FaceToFaceModelTests.swift`

**Interfaces:**
- Consumes: `ConversationSide.partners`, `storedPartner`, `ConversationPacks(checking:partner:)`, `ConversationSession` (`phase`, `leave()`).
- Produces:

```swift
/// What one visit with one partner language owns.
@MainActor public struct ConversationVisit {
    public let partner: ConversationSide
    public let session: ConversationSession
    public let packs: ConversationPacks
    public init(partner: ConversationSide, session: ConversationSession, packs: ConversationPacks)
    /// Never waits: cancels the packs, and `session.leave()` runs in a task of its own.
    public func close()
}

@MainActor @Observable public final class FaceToFaceModel {
    public private(set) var visit: ConversationVisit
    /// True only while the session is idle.
    public var canChoose: Bool { get }
    public init(storedPartner: String?, save: @escaping (String) -> Void,
                makeVisit: @escaping @MainActor (ConversationSide) -> ConversationVisit)
    public func choose(_ partner: ConversationSide)
    public func close()
}
```

`choose` does nothing when the language is the current one, is not in `partners`, or `canChoose` is false. Otherwise: close the current visit, `save(partner.rawValue)`, `visit = makeVisit(partner)`.

- [ ] **Step 1: Write the failing tests** (use the existing conversation and pack fakes)
  - `init` with `nil` makes one Korean visit; with `"japanese"` a Japanese one; `save` is not called by `init`.
  - `choose(.english)` when idle: `makeVisit` called once more with `.english`, `save` receives `"english"`, the old session's utterances are empty after its leave completes.
  - `choose(current)` and `choose(.chinese)`: no new visit, no save, same session object.
  - While the session is starting, listening, and finishing (translation held by the fake), `canChoose` is false and `choose` changes nothing; the turn then completes normally.
  - Choosing while the old packs' speech install is suspended: the old packs end with their task cancelled, and releasing the install afterwards leaves the new visit's packs unchanged.
- [ ] **Step 2: Run and see them fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run the whole suite; all pass**
- [ ] **Step 5: Commit** `feat(core): change the partner language by starting a new visit`

---

### Task 3: The screens, the wiring and the documents

**Files:**
- Modify: `MeetingTranslator/App/AppAssembly.swift`, `App/RootView.swift` (only if a signature it uses changes)
- Modify: `MeetingTranslator/Features/FaceToFace/{FaceToFacePage,ConversationHalf,ConversationPacksView,ConversationTranslationDownload}.swift`
- Create: `MeetingTranslator/Features/FaceToFace/{HalfTexts,PartnerPicker}.swift`
- Modify: `README.md`, `docs/phase1-acceptance.md`

New files under `MeetingTranslator/` are picked up by XcodeGen from the folder; no project file edit.

**Interfaces:**
- Consumes: everything Tasks 1 and 2 produce.

**Requirements:**
- `FaceToFaceSetup` keeps one translator to Chinese and one per partner from Chinese, for the life of the app, and offers `makeModel() -> FaceToFaceModel` using `UserDefaults.standard` key `partnerLanguage`. Each visit gets its own `AudioCapture`, `ConversationRecorder(store:partner:)`, session and `ConversationPacks`.
- `FaceToFaceVisit` is replaced by the core's `ConversationVisit`. The page keeps the model in `@State`, made once in `onAppear`, and closes it in `onDisappear`; scene phase goes to `model.visit.session`.
- The content that depends on the partner (pack screen or board, the translation download modifier, the `refresh()` task) carries `.id(model.visit.partner)` so a change discards its view state and runs `refresh()` again. `lastSpeaker` returns to `.chinese` on a change. The screen-awake modifier stays outside the id.
- `PartnerPicker`: a menu labelled `对方语言：日语`; items `韩语 한국어`, `日语 日本語`, `英语 English` with the current one marked; disabled when `canChoose` is false. It sits at the top of the Chinese half and on the pack screen.
- Pack screen title `面对面翻译（中文 ↔ 日语）`; pack names `中文识别包`, `日语识别包`, `中文 → 日语翻译包`, `日语 → 中文翻译包` (same pattern for the others).
- The translation download uses `packs.target(from: side)` as its target.
- The top half is `model.visit.partner`; each half gets `.typesettingLanguage(side.translationLanguage)`.
- `HalfTexts` (moved out of `ConversationHalf.swift`), in the order speak, stop, starting, listening, finishing, notHeard, translationFailed, failed:
  - chinese and korean: as now
  - japanese: `話す`, `終了`, `準備中…`, `聞いています…`, `翻訳中…`, `よく聞き取れませんでした`, `翻訳に失敗しました`, `エラーが発生しました`
  - english: `Speak`, `Stop`, `Getting ready…`, `Listening…`, `Translating…`, `Didn't catch that`, `Translation failed`, `Something went wrong`
- Keep the existing previews working and add one preview with a Japanese partner.
- README: the face-to-face bullet says the partner language is Korean, Japanese or English, chosen on the page and remembered; Malay and other languages are not offered; not verified on an iPhone. `docs/phase1-acceptance.md`: the face-to-face section title becomes `面对面（中文 ↔ 韩语 / 日语 / 英语）`; add rows, result columns blank: F8 each of Japanese, Korean, English: download online, then in airplane mode three travel sentences each way; F9 change language: screen cleared, two history records with correct labels; F10 kill and reopen: the last language is still selected. Note that translation quality is recorded as an observation, not a pass condition.

- [ ] **Step 1: Implement the app changes**
- [ ] **Step 2: `swift test --package-path Packages/MeetingCore` still passes; `grep -rn "\.other\b\|FaceToFaceVisit\|ConversationPack.all" MeetingTranslator Packages` finds no stale use**
- [ ] **Step 3: Update README and the acceptance document**
- [ ] **Step 4: Commit** `feat(app): choose the other side's language on the face-to-face screen`

(The app target is compiled and checked in a simulator by the controller on the MacBook Air.)
