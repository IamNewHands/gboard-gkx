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
