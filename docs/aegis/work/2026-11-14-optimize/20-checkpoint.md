# 性能与隐私改动 · 检查点（2026-11-14 第四轮）

## 状态

| 步骤 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 全局状态 + 词库一次性 + 触觉复用 | 完成 |
| 2 | 组字状态缓存 + 廉价路径（P1-1/P1-2） | 完成 |
| 3 | 遍历零临时数组（P1-5） | **跳过**（见下） |
| 4 | 隐私上报拦截（clearcut + Breakpad） | 完成 |
| 5 | 离线全量回归 + 文档 | 完成 |
| 6 | 推送 → CI → 打包 → 真机验收 | 待执行 |

## 实际改动

### 性能

1. `gComposingActive` 缓存：`GXKComposingFromProxy`（O(1) 读 markedText）与 `GXKComposingFullScan`（原全树逻辑）拆分；`GXKRefreshComposingState` 只在 `viewDidAppear` / `viewWillAppear` / `viewDidLayoutSubviews` / `textDidChange:` 与点击时执行，`GXKComposingStateCached` 供轮询与标题使用。
2. `GXKUpdateActionKey` 入口新增廉价路径：绑定仍有效时只做 frame/颜色/标题刷新，不调用 `GXKFindNineKeyEmojiKey`。校验条件包含 restorationIdentifier、宿主一致性、可见性、icon 与 softKeyDef 同一性、actionsArray 非空；任一不满足即落回原完整路径，失败闭合语义不变。
3. `gDictDeploySettled`：`GXKEnsureUserDictionaryDeployed` 首行短路；只有「包内与目标一致」或「拷贝成功」置位，失败不置位以便下次重试。
4. `GXKImpact` / `GXKReleaseHaptics`：两个 `UIImpactFeedbackGenerator` 复用并每次 `prepare()` 预热；`viewWillDisappear` 置 nil 释放。
5. 点击路径改为 `GXKRefreshComposingState` 取真实状态（低频事件，避免陈旧缓存决定重输/换行）。

### 隐私

`GXKDisableTelemetryUpload` 逐条 `method_setImplementation` 13 个上报出口：

- `CCTClearcutLogger`：`log:`、`logWithExtension:`、`logCounters:`
- `CCTClearcutUploader`：`startAutoUpload`、`startPeriodicUploadWithTimeInterval:`、`startPeriodicUploadWithTimeInterval:leeway:`、`startAutoUploadOnBackground`、`startAutoUploadOnForegroundWithDelay:`、`startCollectForDebugPeriodicUpload`
- `GKBClearcutUploader`：`uploadClearcutLogs`、`shouldUploadClearcutLogs`
- `BreakpadController`：`start:`、`sendStoredCrashReports`

编码全部取自 `dist/inspect-layout-20261114-013-encodings.txt`（实测 dump，非推断）。

不碰：`crashIfNecessary`/`crashIfMultipleUploadersInstantiated`/`crashOnErrors`/`newEvent`/`uploadWithCompletionHandler:*`/`initSingleton`/`GKBClearcutClient` 的 99 个 `log*`/`dealloc`。不按域名拦截。不改 Info.plist。

`GXKApplyTelemetryBlockIfNeeded` 幂等：构造函数时若 framework 未就绪则跳过，首次 `viewWillAppear` 补装；`NSClassFromString` 取不到即降级不拦截。

## 为什么跳过 P1-5

`addObjectsFromArray:` 的三处（`GXKComposingFullScan`、`GXKFindNineKeyEmojiKey`、`GXKNativeActionFont`）已在 P1-1/P1-2 之后变成**低频路径**：全树扫描只在布局/文本事件与点击时发生，0.2s 轮询不再进入。改成游标复用能省的只是低频路径里的临时数组分配，收益远小于改坏遍历顺序（`lastObject` 出栈语义）的风险。按最小改动原则保留原实现。

## 离线回归

- `tests/test_action_key.py` 20 项 OK
- `tests/test_native_resources.py` 6 项 OK
- `tests/test_perf.py` 7 项 OK（新增）
- `tests/test_privacy.py` 7 项 OK（新增）
- `git diff --check` 干净

## 推送、CI 与测试包

- 提交 `1a779c5`，推送 `b630aa4..1a779c5`，远端 main = `1a779c5e42e4a1bcf418cdfb0115f47ce1a8c3c1`。
- CI run `43608139450`（push，macos-15-arm64，conclusion success）。
- 产物 `dist/libgkx-1a779c5/libgkx.dylib`：79424 字节，SHA256 `4308af3ff2b4dc75b502331e7c26045c040e1afc20a786ac552b04fbbd24b0a5`；符号含 `GXKActionHostForKey`、`GXKApplyTelemetryBlockIfNeeded`、`CCTClearcutLogger`、`BreakpadController`、`startCollectForDebugPeriodicUpload`、`insertText:`。
- 测试包 `dist/gboard-gkx-1a779c5-unsigned.ipa`：36656841 字节，SHA256 `f3c6e2898901dc7525974f858ffcd730f26bcf55b5dad0bce68acd4e834dee78`。
- 字节级复核：2051 成员 0 重复、`testzip()` 无错、无 `_CodeSignature`/`SC_Info`、包内 dylib 与 CI 产物同 SHA256 且 mode 0755、`LC_LOAD_DYLIB @rpath/libgkx.dylib` 与 `LC_RPATH @executable_path/../../Frameworks` 均在、`group.zunbengege.top` 在 dylib 1 处与 framework 8 处、旧 Google group 串 0、词库在 appex 与 Frameworks 各一份。

## 未验证

- 真机：性能体感、翻译/YouTube/天气可用性、换行与重输行为

## 第 6 轮：主 App 注入、埋点置空、轮询按需

三项授权改动（用户 "做1,2,3"）已全部落地，提交 `5dd6a88`。

### 1. 主 App 二进制也注入 dylib

`tools/inject.py` 原先只遍历 `.appex`，容器 App 进程完全不受拦截（实测主 App 二进制含 `BreakpadController` 2 处、`CCTClearcutLogger` 6 处、`GoogleBreakpadController` 2 处）。改动：

- 新增 `bundle_executable(bundle)`：读任意 bundle 的 `CFBundleExecutable`。
- 新增 `resolve_app_frameworks_dir(app, binary_path)`：主 App 的 `LC_RPATH @executable_path/Frameworks` 解析为 `<app>/Frameworks`。**不能复用 `resolve_frameworks_dir`** —— 同一个 rpath 字符串在 appex 里语义不同（那里指 appex 自己的 Frameworks），复用会写错目录。
- `main()` 在 appex 循环之前插入主 App 注入块，`add_load_command` 结果非 `added`/`already-present` 即 `raise SystemExit`，不允许静默降级。
- 主 App padding 余量实测：ncmds=49、sizeofcmds=5856、可用 24412 字节且全零 → 无损追加可行。

两条 rpath 最终落在同一物理目录 `Payload/Gboard.app/Frameworks/`，所以 dylib 只有一份，两个进程共享。

### 2. `GKBClearcutClient` 的 78 个 `log*` 置空

`GXKDisableTelemetryUpload` 只拦了 13 个上传出口，事件对象仍在构造。新增 `GXKDisableClearcutClientEvents`：`class_copyMethodList` 遍历，`strncmp(name, "log", 3) == 0` 且 `method_getTypeEncoding` 首字符为 `v` 才替换为变参 no-op `gxk_noop_any`。有返回值的读方法（`isEnabled`、`isRegexRule:`、`featureFlagEventsForDailyLog`、`EXPRExpressionEvent` 等 21 个）不动 —— 置空会改变调用方分支。

写成独立函数而非并入 `GXKDisableTelemetryUpload`，是因为 `tests/test_privacy.py` 的契约要求那个函数体内不出现 `GKBClearcutClient` 字样（防止误伤读方法）。

### 3. 0.2 秒轮询按需启停

原先 `gkx_viewWillAppear` 建无条件常驻表，每秒唤醒 5 次。改为 `GXKBumpPolling(GXK_POLL_BURST)`（15 tick ≈ 3 秒补帧窗口）+ `GXKStopPolling()`：文本变化、布局、出现、点击各抬一次计数，计数耗尽自动 `invalidate`，`viewWillDisappear` 立即停。空闲时零唤醒，打字时行为与原先一致。

### 离线回归

- `tests/test_action_key.py` 20 项 OK
- `tests/test_native_resources.py` 6 项 OK
- `tests/test_perf.py` 8 项 OK（新增 `test_polling_stops_when_idle`）
- `tests/test_privacy.py` 8 项 OK（新增 `test_clearcut_client_events_are_nooped_without_touching_readers`）
- `tests/test_inject.py` 5 项 OK（新增）
- `git diff --check` 干净

### 主 App/appex 二进制内 2 处 `group.com.google.keyboard` 未改写：非回归，无需修

复核发现 `Payload/Gboard.app/Gboard` 与 appex 二进制里各有 2 处旧 group 串，`group.zunbengege.top` 在这两个文件里 0 处。查明结论：

- 原始 `Gboard_2.3.19.ipa` 同样是 2 处，`1a779c5` 版本也是 2 处 → **既有行为，不是本轮引入**。
- 这 2 处**都不是以 NUL 结尾的 C 字符串**：一处在内嵌 XML plist 的 `<string>group.com.google.keyboard</string>` 里，另一处在紧随其后的二进制 plist 结构里（长度前缀 `\x0c\x19` = 25，即 `tion-groups` 段）。`patch_app_groups` 要求命中位置后一字节为 NUL，因此正确地跳过了它们。
- 它们是被剥离签名的内嵌 entitlements 快照，运行时权限由重签时的描述文件决定，不参与 `containerURLForSecurityApplicationGroupIdentifier:` 调用；真正读 group 的字符串在 `libgkx.dylib`（1 处）与 `gboard_framework`（8 处），两者都已改写。
- 若要强改需变长度重排 plist 结构 → 违反红线 5（无损注入）。不做。

### 推送、CI 与测试包（第 6 轮）

- 提交 `5dd6a88`，推送 `7b504af..5dd6a88`。
- CI run `43680024919`（build-dylib，push，main）conclusion success，14s。
- 产物 `dist/libgkx-5dd6a88/libgkx.dylib`：79904 字节，SHA256 `478337adfc6e36248f0631854110fa71dc379858573f8ba362104b577ca9cb19`。
- 测试包 `dist/gboard-gkx-5dd6a88-unsigned.ipa`：36657484 字节，SHA256 `c636122f9b94f50ae4aeb174573d6f122089a04aaa383d366eb66a3aa2848138`。
- 注入输出：主 App `add=added ncmds=50 sizeofcmds=0x1710 验证=OK`，appex `add=added ncmds=48 sizeofcmds=0x17f8 验证=OK`，两者 rpath 均落 `Payload/Gboard.app/Frameworks`。
- 字节复核：2051 成员 0 重复、`testzip()` 无错、签名目录 0、dylib 仅一份且 mode 0755、词库两份 mode 0644、两个可执行文件各含 1 处 `@rpath/libgkx.dylib`。
- dylib 字符串确认新代码已编入：`GXKBumpPolling` 2 处、`class_copyMethodList` 2 处、`method_getTypeEncoding` 2 处、`sel_getName` 2 处；中文串以 UTF-16-LE 存放（`埋点已置空`、`隐私上报已拦截`、`初始化注入`、`重输`、`换行` 均命中）。

### 未验证（真机）

- 空闲时不再有 0.2 秒轮询后的手感：换行/重输切换是否仍即时。
- 翻译、YouTube 搜索、天气是否仍可用（本轮只拦上报出口与埋点，不碰网络请求）。
- 崩溃上报是否不再外发（需抓包确认 `play.googleapis.com` 无请求）。
