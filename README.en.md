# Gboard-NTR (iOS Gboard enhancement patch)

[中文](README.md) | **English**

A no-source reverse-engineering patch for the official **iOS Gboard 2.3.19** keyboard, delivered as an Objective-C dylib (`libgkx.dylib`) injected into the stock app plus lossless binary rewriting. No jailbreak required.

> **Design philosophy: stay native, never invade.**
> The stock Google Mozc Pinyin engine, the original key layouts and Glide Typing are kept 100% intact. No layout shifts, no view occlusion, no memory-kill crashes. Only the features that actually matter are added.

---

## What this patch changes

### 1. Bundled Rime "Wanxiang" dictionary (light enough to survive Jetsam)
* **60,000 curated entries**: top 45,000 high-frequency words, 10,000 idioms, 3,000 place names and 2,000 abbreviations, covering roughly 99% of everyday Pinyin input.
* **Slim Protobuf**: the redundant `comment` field is dropped during serialization, shrinking the file from 2.18 MB to **1.61 MB**, and avoiding 60,000 heap allocations while Mozc deserializes. Runtime memory growth stays within **4–6 MB**, which keeps the keyboard extension away from the Jetsam limit (typically 30–50 MB).
* **Zero-touch deployment**: on first launch the extension copies the dictionary into the shared App Group container (`group.zunbengege.top/user_dictionary.db`).
* **Shipped once**: the dictionary lives only in the main app's `Frameworks/`. The extension's `LC_RPATH` is `@executable_path/../../Frameworks`, which resolves to that same copy, so duplicating it into the `.appex` would waste 1.7 MB of install size and never be read. The deployment code probes "app bundle → main app Frameworks → two levels up" in order, so both processes find it.

### 2. Nine-key emoji key becomes "retype / dismiss / newline"
* **Scope**: the nine-key Pinyin layout and its 123/symbol pages only. The single native key `key_pos_9keys_emoji` is replaced; the native return key and the full 26-key layout (including its number/symbol pages) stay untouched. Key identity is never guessed from coordinates.
* **Three modes** (priority: composing > suggestions > idle): while Pinyin is composing, the key reads **重输 (retype)** and clears the uncommitted composition through Gboard's own `resetKeyboard`/`abortComposing` with a medium haptic; when the candidate strip already holds text without composition, it reads **收起 (dismiss)** and calls the public `dismissKeyboard` with a light haptic, because once the whole sentence is offered the cheapest next step is to put the keyboard away; when idle it reads **换行 (newline)** and inserts `\n` with a light haptic.
* **Suggestion detection**: produced by the same full-tree pass as the composing flag — once a `GKBCandidatesCollectionView`/`GKBFixedNumberCandidatesView` is hit, only its visible cells' `UILabel` text is inspected and the whole candidate subtree is pruned, so hundreds of cells never enter the stack. Composition invalidates the flag immediately, and leaving the keyboard clears it. A single `GXKActionTitle` decides the label; the cheap and full paths must not duplicate that logic.
* **Native look**: the original background layer, border and theme are preserved; only the foreground content changes, using the native font and foreground color. Neither label adds a red tint, an opaque background or a highlight.
* **State sync**: driven by the visible layout, `viewDidLayoutSubviews`, `textDidChange:` and a 0.2 s poll, and the target key, current model and button binding are re-validated on every tap.

### 3. Native purity and zero occlusion
* **No added height**: no native container moves. The left edge clears both the measured visible G image +4 pt and the native G key's complete hit carrier. Root-hosted hit bounds stay inside the native row at a minimum 28 pt height; titles and dividers independently align to the real G image center. The hit band defaults to 28 pt and shrinks to the host row (18 pt floor) when the row is only 22 pt, instead of dropping the whole bar. An unfit native-size title still cannot authorize display. Under 200 pt free width, composition, an independent visible QWERTY body or overlapping native candidates/keys/icons hides the toolbar; native content is never masked.
* **Measure the real image layer**: G uses `GKBImageViewWithBackground` / `GKBImageLayer`. Actual contents gravity, CGImage pixels and contentsScale determine the image rectangle, clipped by real ancestor masksToBounds. A 36 pt carrier is not a 22 pt image. No imaginary square fallback: masks, transforms, animations and incomplete bindings fail closed. A header-row G is often clipped by a 26 pt ancestor with `masksToBounds=1` down to a 2 pt visible sliver; that case anchors on the unclipped drawn rect (still gated by the 8..64 pt check) instead of concluding there is no G. The bar defaults to 28 pt and shrinks to the row height. Visible image bounds are not opaque pixels; device alignment remains to be verified.
* **Appearance follows the native return key**: only `key_pos_9keys_return` and its `idToViewDict[@"label"]` own the font, never arbitrary labels or candidate text. Text color prefers the currently bound native emoji icon, then the return label and system theme color. Invalid bindings fall back to verified stock Roboto-Regular 16 pt, then a same-size system font. Titles do not auto-shrink. Five cells retain 0.5 pt dividers at 18% opacity, centered with the G image and bounded by the hit band, without extra arranged subviews. Hidden keyboard owners and image-capable carriers are registered on lifecycle/layout/text events and revalidated live on reuse.
* **Actions**: select all, copy, paste, cut and dismiss. Cutting requires a selection — the patch never loops `deleteBackward`. Successful actions stay silent to avoid stutter; only failures flash the button title.
* **Glide Typing untouched**: the patch never swizzles `touchesBegan/Moved/Ended` on `GKBSoftKeyView`, so swipe typing stays exactly as smooth as stock.

### 4. G-logo page trimming and single search-history deletion
* **YouTube and Contacts pages removed** with a three-layer fallback: `GKBFeatureFlagManager`'s `enableYouTubeMiniApp`/`enableContactsMiniApp` return a flag object whose `value` is `NO`, `GKBMiniAppExtensionBase`'s `isMiniAppEnabled:` returns `NO`, and `GKBMiniAppManager`'s `availablePickerItems` filters both out. If a class disappears in a future Gboard build, that layer is skipped and behaviour degrades to native.
* **GIF and Sticker tabs removed** from the 26-key emoji panel, keeping only emoji and kaomoji. Their identifiers are literally `gif` and `sticker` (read from the `__data` CFString constants of `gboard_framework`) and are compared as whole words so `gift` is never matched.
* **Single history deletion**: a 28 pt "×" is overlaid on each search-history row; tapping removes that entry from the current suggestion array and from the persisted record (only written back when the key name contains `RecentQueries` and the entry really matched). The button sits on `contentView` with an autoresizing mask, so no native layout, row height or constraint changes.

### 5. Map page location: fully reverted to native
The "enable location services" card on the map page is stock Gboard behaviour. The patch installs no hook, adds no button and performs no "open the main app first" detour, because that detour cannot work on a real device: a keyboard extension's `NSExtensionContext` only opens the host app's own URL scheme, and `prefs:root=Privacy&path=LOCATION` is silently rejected for third-party apps too. `tests/test_location_jump.py` asserts that none of these symbols come back.

### 6. Phrases page (inside the G-logo picker, next to Search / Translate / Map)
* **Entry point**: an item is appended to `GKBMiniAppManager`'s `availablePickerItems` as a `GKBExtensionSegmentedControlItem` with identifier `gxk_phrases`; its icon is a "语" glyph drawn at runtime with `UIGraphicsImageRenderer`, so no asset name is required. `GKBMiniAppExtensionBase`'s `miniAppPicker:didSelectItem:atIndex:` presents the patch's own panel for that identifier and falls through to native for everything else.
* **The picker item must be a `GKBExtensionSegmentedControlItem`** — a real-device crash taught this: the segmented control asks every item for `badgeableViewType`, `controlItemType`, `accessibilityIdentifier` and `accessibilityLabel`. The earlier `GKBAppStripItem` responds to none of them, so the first tap on the emoji key crashed the whole extension with `-[GKBAppStripItem badgeableViewType]: unrecognized selector`.
* **The panel is an overlay**: `GXKPhrasesPanel` fills the keyboard view's `bounds` and computes frames by hand in `layoutSubviews`. No constraints are added and the keyboard height never changes.
* **Panel colors follow the keyboard skin, not the system appearance**: a Gboard skin can disagree with the system light/dark setting, so the panel does not read the appearance switch. It samples the largest opaque background color inside the keyboard body as its background, takes the native label color as its primary text color, and only falls back to built-in colors when the resulting contrast is too low. `didMoveToWindow` and `traitCollectionDidChange:` recompute it, and a refresh happens only when a color actually changed. Cells no longer show the system's white block underneath.
* **Pinning**: with pinning off (default), tapping a phrase inserts it and closes the panel; with pinning on, taps keep the panel open for continuous input. The state lives in the App Group key `GXKPhrasesPinned`.
* **Insertion** goes through `UITextDocumentProxy`'s `insertText:`, exactly the native path.
* **Two maintenance entry points, the in-keyboard one being the fallback**:
  * The "Edit" button in the panel opens the editor directly, with no dependency on the main app.
  * The main app's "Settings → Gboard" main menu gains a "Phrases" row on the same level as Search Settings and Keyboard Settings, by hooking `mainMenuPageDescriptor`, copying a real native row and replacing only its title and key.
  * The editor is `GXKPhrasesEditorController`: "+" adds, tapping a row edits, swiping left deletes, with its own Done button. Changes post `GXKPhrasesChangedNotification`, which the panel observes.
  * **No text-input UI may exist inside the keyboard process.** An alert with a text field (or any inline `UITextField`) asks the system for a keyboard, and that keyboard is this very extension, so iOS recursively activates it and kills the process. Inside the extension, adding or editing reads the pasteboard instead: copy the text, then tap "+" to add or tap a row to replace it. No alert is presented either — the navigation title flashes a hint — because presenting any controller from an extension pulls a second presentation context and crashes the same way.
  * Data lives in the App Group key `GXKPhrases`, shared between the keyboard and the main app.
* **Always present full-screen, never push**: the main app's settings page runs inside Google's own `GOONavigationController`, and pushing onto it shows a blank screen on device. The editor is therefore wrapped in a `UINavigationController` and presented with `UIModalPresentationFullScreen`.

### 7. Typing smoothness: constant-cost refresh per keystroke
* **Polling on demand**: state sync still uses a 0.2 s `NSTimer`, but extra frames drop from 15 per keystroke to 2 for ordinary typing (`GXK_POLL_SETTLE`), rising to 5 (`GXK_POLL_BURST`) only when composing actually flips. The timer stops when idle.
* **Class lookups cached by class pointer**: the full-tree scan used to call `NSStringFromClass` plus two `containsString` checks per node; the result is now memoized per `Class` in `gViewKindCache`.
* **Throttled full scans with a trailing pass**: `GXKComposingFullScan` runs at most every 0.25 s (`GXK_COMPOSING_SCAN_MIN_INTERVAL`); a skipped pass is re-run once through `dispatch_after`, and the UI refreshes only when the state really flipped. When the proxy already reports the composing flag, the O(1) path is used and no scan happens.
* **The toolbar is reused, not rebuilt**: the same host row keeps its `UIStackView` and five buttons; constraints are deactivated before being activated again. The decoration scan is memoized per band.
* **Haptics released when idle**: `prepare` keeps the Taptic engine warm, so both `UIImpactFeedbackGenerator`s are released after 2 s of inactivity (`GXK_HAPTIC_IDLE_SECONDS`) and recreated lazily.
* **The pinned flag is not force-flushed**: `GXKPhrasesPinned` is only read and written by the keyboard process, so `synchronize` was dropped; `GXKPhraseSave` keeps it because the main app writes and the keyboard reads across processes.
* **The poll timer only joins the default runloop mode**: the original extra `addTimer:forMode:NSRunLoopCommonModes` let the 0.2 s poll compete with scrolling and animations, which was the actual source of stutter. The source no longer contains `NSRunLoopCommonModes`.
* **High-frequency callbacks merged to the last one**: `textDidChange` and `viewDidLayoutSubviews` can fire dozens of times per frame; both now use an incrementing sequence number plus `dispatch_async` and drop everything but the last call.
* **Hot-path class pointers cached**: `NSClassFromString` used to run once per soft key in a 1500-node loop; it now goes through `GXKClassCached(name, &slot)`, and none of the five scan functions calls `NSClassFromString` any more.
* **Band results reused by neighbour signature**: `GXKToolbarBand`'s visibility check walks the parent chain with `convertRect`, the only remaining per-tick work. A read-only signature of `frame/hidden/alpha` is compared first, and the cached result is returned when row size, glyph position, decoration count, signature and epoch are unchanged; mounting and unmounting bump `gToolbarBandEpoch`.
* **Regression guards**: `tests/test_perf.py` locks every item above.

---

## Development red lines

### Red line 1: never touch the keyboard root constraints or height
`_keyboardHeader`, `_keyboardBody` and `GKBNibView` have a strict official constraint system. Adding a root height constraint or recursively offsetting containers pushes the candidate bar or the preedit line off-screen, or produces black and white gaps in landscape. Any added UI must be an in-place key replacement or reuse of existing spare space.

### Red line 2: never intercept key touch events globally
Glide Typing depends on high-frequency, continuous touch sampling. Swizzling `touchesBegan/Moved/Ended` on `GKBSoftKeyView` immediately breaks the swipe trail. Custom keys must be added as an independent subview (a single overlay `UIButton`) on the target key.

### Red line 3: memory and Jetsam limits are hard
A keyboard extension usually gets 30–50 MB of physical memory. The external dictionary must stay at or below **70,000 entries** and **2.5 MB**; every Protobuf entry must omit `comment`; and no large static data or unreleasable cache may be added to `libgkx.dylib`.

### Red line 4: Windows packaging must preserve Unix permission metadata
Unpacking and repacking a ZIP on Windows sets every file to `0o666` and loses the executable bit, which makes the dylib fail to load or the extension get SIGKILLed. `tools/inject.py` records the original Unix modes and re-applies `0o755` to `libgkx.dylib` and the app/extension binaries, `0o644` to data files.

### Red line 5: lossless injection with equal-length App Group rewriting
A `LC_LOAD_DYLIB` command is written in place into the all-zero padding right after the load commands, so no section offset moves. App Group strings are overwritten in place with an equal or shorter value and `\0` padded; they must never exceed the original slot.

---

## Repository layout

```
gboard-ntr/
├── dylib/gkx.m                    # the injected source
├── .github/workflows/build-dylib.yml  # macOS-15 runner, arm64 clang, ldid pseudo-sign
├── tools/
│   ├── inject.py                  # pure-Python Mach-O injection, App Group rewrite, Unix modes
│   ├── dict_converter.py          # Wanxiang YAML/text → compact Protobuf (60k entries)
│   └── inspect_signed.py          # read-only Mach-O / permission self-check
├── tests/                         # source-level regression guards (unittest)
├── README.md / README.en.md       # Chinese / English docs
└── agent.md                       # reverse-engineering notes and pitfalls
```

---

## Build and package

### 1. Dictionary (only when the source dictionary changed)
```powershell
python tools/dict_converter.py --dir "%APPDATA%\Rime\dicts" -o "dist/user_dictionary.db" --max 60000
```

### 2. Compile `libgkx.dylib` in the cloud
Push `dylib/gkx.m` to GitHub; `build-dylib.yml` compiles it with arm64 clang on a macOS-15 runner and pseudo-signs it with `ldid`. Download the artifact:
```powershell
gh run download <RUN_ID> -n libgkx -D dist/artifact
Copy-Item dist/artifact/libgkx.dylib dist/libgkx.dylib -Force
```

### 3. Inject and repack locally

The original IPA is expected at `../ipa/Gboard_2.3.19.ipa` next to the repo; adjust `--ipa` if yours lives elsewhere.

```powershell
python tools/inject.py `
  --ipa "../ipa/Gboard_2.3.19.ipa" `
  --dylib "dist/libgkx.dylib" `
  --dict "dist/user_dictionary.db" `
  --app-group "group.zunbengege.top" `
  --out "dist/gboard-ntr-1.0-unsigned.ipa"
```

`--app-group` is mandatory (the script exits with code 2 without it). `group.zunbengege.top` is only an **example** group authorized by one self-signing provisioning profile: change `GXKGroup` in `dylib/gkx.m`, the default in `tools/inject.py` and this flag together, or the app crashes on launch and the keyboard stays stuck on the 26-key layout.

The script unpacks the original IPA, records Unix modes and timestamps, writes `LC_LOAD_DYLIB @rpath/libgkx.dylib` into the extension binary's padding, deploys the dylib to the main app's `Frameworks/`, rewrites the 8 Google App Group strings in place, and repacks with `0o755` on executables.

---

## Signing and on-device verification

1. Self-sign `dist/gboard-ntr-1.0-unsigned.ipa` with LCSign, SideInstaller, SideStore or TrollStore and install it.
2. Enable **Allow Full Access** in **Settings → General → Keyboard → Keyboards → Gboard**; the dictionary and shared configuration depend on the App Group container.
3. iOS caches keyboard extensions aggressively. If nothing changed after an overwrite install, remove the Gboard keyboard in Settings, add it again, and re-grant Full Access; or restart the host app.
4. Checks: type `aerjinshan` and `wanxiang` to see the bundled entries near the top; on the nine-key layout the key above return reads "newline" when idle and switches to "retype" while composing; swipe typing must stay smooth on both layouts.

---

## ⚠️ Disclaimer and license

* This repository contains **no** Google binary and no IPA — only injection source, dictionary tooling and documentation. You must obtain a genuine **Gboard 2.3.19** IPA yourself.
* Patched builds are for **personal, self-signed testing only**. Do not redistribute or use commercially. Gboard and Mozc remain the property of Google.
* Provisioning profiles, certificates and App Groups are your responsibility; `group.zunbengege.top` is a placeholder.
* The patch performs unsigned binary injection; behaviour may change after a system or signing-tool update. Use at your own risk.
