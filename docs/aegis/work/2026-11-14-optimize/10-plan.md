# 实施方案：性能 P1 + 隐私上报屏蔽

> 目标来源：用户 m00656（2026-11-14）
> 「两个都做；隐私那块只屏蔽没有用处的、涉及隐私信息的、无意义的上报（比如崩溃上报），
> 不要影响翻译、YouTube 搜索、天气这些正常功能。先列好实施方案，拆分实施步骤，做好测试。」
>
> 范围：仅 `dylib/gkx.m`（+ 新增离线测试）。不改 `tools/inject.py`、不改 Info.plist、不改词库、不碰根视图几何。

---

## 0. 约束（来自 README 红线与既有契约，实施时必须逐条守住）

| 编号 | 约束 | 本方案如何满足 |
| --- | --- | --- |
| R1 | 禁改 `_keyboardHeader` / `_keyboardBody` / `GKBNibView` 约束与高度 | 不涉及 |
| R2 | 禁全局拦截 `GKBSoftKeyView` 及父类的 `touchesBegan/Moved/Ended` | 不 swizzle 任何 touches*；隐私拦截只碰 CCT*/Breakpad 类 |
| R3 | 词库 ≤70000 条 / ≤2.5MB；禁常驻大静态结构 | 只加 4 个 static 标量/弱引用 + 2 个触觉 generator，无数组 |
| R4 | 打包保留 Unix 权限 | 不改 inject.py |
| R5 | 无损注入、App Group 等长改写 | 不改 inject.py |

额外的既有源码契约（`tests/test_action_key.py`，20 项）必须继续全绿：
- `gkx_init` 函数体内不得出现 `touchesBegan`/`touchesMoved`/`touchesEnded`/`hitTest` 字面量。
- 全源码不得出现 `softKeyDef =`（只读）、`allSoftKeys`、`bestCandidate` 等。
- 动作键段不得 `sub.hidden = YES/NO`、不得加 cornerRadius/自定义颜色。
- `[proxy insertText:@"\n"]` 保持单反斜线。

---

## 1. 性能 P1：现状与目标

### 1.1 已定位的三个热点（证据来自 `dylib/gkx.m` 现行 revision 73427f1f）

| 编号 | 位置 | 现状 | 每次成本 |
| --- | --- | --- | --- |
| H1 | `gkx.m:543` `NSTimer 0.20s` → `GXKUpdateActionKey` | 每秒 5 次无条件全量刷新 | — |
| H2 | `gkx.m:424` `GXKFindNineKeyEmojiKey(root)` | 每次刷新都从 root 全树重扫（上限 1500 节点，含 `isDescendantOfView:`） | ~1 次全树 |
| H3 | `gkx.m:506` `GXKIsComposingActive(vc)` | 每次刷新全树扫描（上限 1500 节点，每节点 `NSStringFromClass` + `valueForKey:@"text"/@"attributedText"` KVC） | ~1 次全树 + KVC |
| H4 | `gkx.m:500` `GXKNativeActionFont(currentKey, root)` | 每次刷新全树找 `key_pos_9keys_return`（上限 300 节点） | ~1 次浅树 |
| H5 | `gkx.m:539` `GXKEnsureUserDictionaryDeployed()` | 每次弹键盘都跑（`containerURL...` + 2 次 `attributesOfItemAtPath:`） | 2 次磁盘 stat |
| H6 | `gkx.m:400` / `gkx.m:406` | 每次点击 `[[UIImpactFeedbackGenerator alloc] init...]`，无 `prepare()` | 每次分配 + 首次触觉延迟 |

合计：**每秒 5 次 × 约 3300 次视图访问 + 1500 次 KVC**，全部在主线程。

### 1.2 目标（可验证）

1. 空闲（无组字、布局未变）时，0.2s 轮询的单次成本降到 **O(1)**：不遍历视图树、不做 KVC。
2. 全树扫描只发生在「布局变化 / 文本变化 / 需要重绑定」这些真实事件上。
3. 词库部署在每个进程生命周期内最多执行 **1 次成功路径**（失败仍可重试）。
4. 触觉 generator 复用 + `prepare()`，点击到触觉延迟降低，不再每次分配。
5. 行为零变化：「重输」/「换行」判定、外观、点击命中全部保持。

### 1.3 改法（P1-1 ~ P1-4）

**P1-1 轮询改「廉价路径优先」**（改 `GXKUpdateActionKey` 的入口段）

```
if (gEmojiSoftKeyView && gActionKeyButton && gActionHost &&
    gActionKeyButton.superview == gActionHost &&
    gEmojiSoftKeyView.softKeyDef == gActionSoftKeyDef &&
    GXKNativeIconForKey(gEmojiSoftKeyView) == gActionNativeIcon &&
    GXKKeyIsVisible(gEmojiSoftKeyView, root)) {
        // 廉价路径：只更新标题（用缓存的组字状态），不遍历。
} else {
        // 完整路径：原有 全树定位 → 校验 → 重绑定 流程
}
```

- `GXKKeyIsVisible` 是 O(祖先数)，不是全树，可接受。
- 廉价路径里标题变化只依赖 `GXKComposingStateCached(vc)`（见 P1-2）。
- **不改变**任何失败闭合（fail-closed）语义：条件不满足就落回完整路径。

**P1-2 组字状态：mark 文本优先 + 事件驱动全树**

- 新增 `static BOOL gComposingActive;` 与 `static NSInteger gComposingFullScanStamp;`
- `proxy.markedText` 有值 → 直接 YES（现行逻辑已如此，成本 O(1)）。
- 全树 fallback（Composing/Preedit 文本、右下角「确认」）**只在** `gkx_viewDidLayoutSubviews` 与 `gkx_textDidChange` 里执行一次，结果写入 `gComposingActive`。
- 0.2s 轮询只读 `gComposingActive`，不再全树。
- 理由：组字状态变化必然伴随布局重排或文本变化；Gboard 的 preedit 更新一定走 `textDidChange:`。

**P1-3 词库部署一次性**

- 新增 `static BOOL gDictDeploySettled;`
- `GXKEnsureUserDictionaryDeployed()` 首行 `if (gDictDeploySettled) return;`
- 只有「已确认目标文件与包内一致（needCopy == NO）」或「拷贝成功」时置 `gDictDeploySettled = YES`；失败不置位，下次弹键盘重试。

**P1-4 触觉复用**

- 新增 `static UIImpactFeedbackGenerator *gFbMedium; static UIImpactFeedbackGenerator *gFbLight;`
- 首次使用时创建并 `prepare()`；点击时 `impactOccurred` 后再次 `prepare()`。
- `viewWillDisappear` 里释放（置 nil），避免扩展常驻内存。

**P1-5（附带，低风险）遍历不用临时数组**

- `GXKFindNineKeyEmojiKey` / `GXKIsComposingActive` / `GXKNativeActionFont` 里的 `[stack addObjectsFromArray:v.subviews]` 改为「显式索引游标」或复用同一个 `NSMutableArray`（`removeAllObjects` 后逐个 add）。
- 目的：去掉每次遍历的临时数组分配。**不改遍历顺序**（先序、lastObject 出栈语义必须保持一致，否则 `test_ambiguous_visible_emoji_is_not_chosen_by_tree_order` 的语义会变）。

---

## 2. 隐私：只掐 clearcut 与 Breakpad 上报

### 2.1 取证结论（决定「掐哪里」）

| 事实 | 证据 |
| --- | --- |
| 扩展自身**没有** CCT*/Breakpad 类，全部来自 `gboard_framework` | `dist/inspect-layout-20261114-010-privacy.txt` 全 MISSING；`-012-telemetry.txt` binds 命中 8 个 `_OBJC_CLASS_$_CCT*/GoogleBreakpadController/PHTBreakpadDecorator` |
| 扩展**主动调用** `uploadClearcutLogs`、`setUploadingEnabled:`、`setUploadInterval:` | `-012-telemetry.txt` selrefs 段 |
| clearcut 出口只有两个 host | `https://play.googleapis.com/log`、`https://play.googleapis.com/log/batch`（`_kDefaultClearcutServerURL` / `_kDefaultClearcutBatchServerURL`） |
| Breakpad 崩溃上报由 `BreakpadController` 驱动 | 24 个方法，含 `start:`、`sendStoredCrashReports`、`threadUnsafeSendReportWithConfiguration:withBreakpadRef:` |
| 翻译 / YouTube / 天气走完全不同的 host | `translation.googleapis.com`、`www.googleapis.com/youtube/v3/*`、`www.weather.com` |

→ **禁用点必须落在 `gboard_framework` 的 CCT*/Breakpad 类上；绝不能按域名拦截**，否则会误伤翻译/YouTube/天气。

### 2.2 禁用清单（全部是 void 或 BOOL 返回，no-op 无副作用）

| 类（来自 gboard_framework） | 选择器 | 编码 | 替换为 |
| --- | --- | --- | --- |
| `CCTClearcutLogger` | `log:` | `v24@0:8@16` | 空实现（事件根本不落盘） |
| `CCTClearcutLogger` | `logWithExtension:` | `v24@0:8@16` | 空实现 |
| `CCTClearcutLogger` | `logCounters:` | `v24@0:8@16` | 空实现 |
| `CCTClearcutUploader` | `startAutoUpload` | `v16@0:8` | 空实现 |
| `CCTClearcutUploader` | `startPeriodicUploadWithTimeInterval:` | void + double | 空实现 |
| `CCTClearcutUploader` | `startPeriodicUploadWithTimeInterval:leeway:` | void + double×2 | 空实现 |
| `CCTClearcutUploader` | `startAutoUploadOnBackground` | `v16@0:8` | 空实现 |
| `CCTClearcutUploader` | `startAutoUploadOnForegroundWithDelay:` | void + double | 空实现 |
| `CCTClearcutUploader` | `startCollectForDebugPeriodicUpload` | `v16@0:8` | 空实现 |
| `GKBClearcutUploader` | `uploadClearcutLogs` | `v16@0:8` | 空实现 |
| `GKBClearcutUploader` | `shouldUploadClearcutLogs` | `B16@0:8` | `return NO` |
| `BreakpadController` | `start:` | `v20@0:8B16` | 空实现（不启动崩溃捕获 → 不产生 minidump） |
| `BreakpadController` | `sendStoredCrashReports` | void | 空实现（历史残留也不发） |

### 2.3 明确「不碰」清单（防误伤）

- ❌ 不 no-op `CCTClearcutUploader` 的 `init*` / `crashIfNecessary` / `crashIfMultipleUploadersInstantiated` / `dealloc` —— 该类有自我保护，动它可能触发自检 crash。
- ❌ 不 no-op `CCTClearcutLogger` 的 `newEvent` —— 返回值被调用方使用，返回 nil 可能崩。
- ❌ 不 no-op `uploadWithCompletionHandler:*` —— 会让 pending completion handler 永不回调，可能卡住内部状态机。
- ❌ 不 no-op `GoogleBreakpadController -initSingleton` —— 返回 nil 可能崩。
- ❌ 不按 URL/域名拦截（会误伤翻译/YouTube/天气）。
- ❌ 不 no-op `GKBClearcutClient` 的 99 个 `log*` —— 上层入口多，从 `CCTClearcutLogger -log:` 单点截断即可，改一个点收益最大、风险最小。
- ❌ 不改 Info.plist（删 `BreakpadProduct` 等键不阻止上报，且会动二进制结构）。

### 2.4 失败安全

- 每个类用 `NSClassFromString` 取；**取不到就跳过**（换新版 Gboard 时自然降级为不拦截，不崩）。
- 每个方法先 `class_getInstanceMethod` 判断存在，再 `method_setImplementation`。
- 全部在 `gkx_init` 末尾、`gkx_privacy` 独立函数里执行；用 `GXK_LOG` 记录实际拦截数量，便于真机看日志确认。

---

## 3. 实施步骤（每步可独立编译、独立回归）

### 第 1 步：性能 P1-3 + P1-4（最低风险，先落地）
1. 加 `gDictDeploySettled`，改 `GXKEnsureUserDictionaryDeployed` 入口与置位点。
2. 加两个静态触觉 generator + `prepare()`，替换 `gkx.m:400` / `gkx.m:406` 的临时对象。
3. `viewWillDisappear` 释放 generator。
4. 跑 `python tests/test_action_key.py` + `python tests/test_native_resources.py`（应 26/26 全绿，无需改契约）。

### 第 2 步：性能 P1-1 + P1-2（核心，需新契约）
1. 加 `gComposingActive` / `gComposingFullScanStamp`。
2. `GXKIsComposingActive` 拆成两半：
   - `GXKComposingFromProxy(vc)`：只读 `markedText`，O(1)。
   - `GXKComposingFullScan(vc)`：现有全树逻辑，改名保留。
3. `GXKUpdateActionKey` 入口加廉价路径（P1-1 伪代码）。
4. 在 `gkx_viewDidLayoutSubviews` / `gkx_textDidChange` 里刷新 `gComposingActive`。
5. 新增 `tests/test_perf.py`（见 §4.1）。

### 第 3 步：性能 P1-5（遍历零临时数组）
1. 三处 `addObjectsFromArray:` 改成复用数组。
2. 保持遍历顺序与 `lastObject` 出栈语义完全一致。
3. `tests/test_perf.py` 增加断言。

### 第 4 步：隐私屏蔽（中风险，独立提交）
1. 新增 `static void GXKDisableTelemetryUpload(void)`，按 §2.2 表格逐条 `method_setImplementation`。
2. 加两个通用 IMP：`gxk_noop_void(id,SEL)` 与 `gxk_noop_void_obj(id,SEL,id)`、`gxk_noop_void_bool(id,SEL,BOOL)`、`gxk_noop_void_double(id,SEL,double)`、`gxk_noop_void_double_double`、`gxk_noop_bool_no(id,SEL)`。签名必须与编码严格对应。
3. 在 `gkx_init` 末尾调用。
4. 新增 `tests/test_privacy.py`（见 §4.2）。

### 第 5 步：离线全量回归 + 文档
1. `python tests/test_action_key.py && python tests/test_native_resources.py && python tests/test_perf.py && python tests/test_privacy.py`
2. `git diff --check`
3. 更新 `20-checkpoint.md` / `90-evidence.md`。

### 第 6 步：推送 → CI 编译 → 打包 → 真机验收（按用户既有偏好「推送即出包」）
1. `git push`（`git -c credential.helper='!gh auth git-credential'`）。
2. 等 `build-dylib.yml` 成功，下载 `libgkx.dylib`。
3. `python tools/inject.py --ipa ... --dylib ... --dict ... --app-group group.zunbengege.top --out ...`
4. 交付未签名 IPA + SHA256。

---

## 4. 测试计划

### 4.1 `tests/test_perf.py`（新增，源码级契约）

| 断言 | 防什么 |
| --- | --- |
| `GXKEnsureUserDictionaryDeployed` 函数体含 `gDictDeploySettled` 且首行有 `return` | 防止回退成每次弹键盘都 stat |
| 该函数只在「成功/一致」分支置 `gDictDeploySettled = YES` | 防止失败也被永久跳过 |
| 源码含 `UIImpactFeedbackGenerator` 静态变量声明（`static UIImpactFeedbackGenerator`） | 防止回退成每次点击新建 |
| 触觉调用点不再出现 `[[UIImpactFeedbackGenerator alloc]` | 同上 |
| `GXKUpdateActionKey` 内含廉价路径标记（`gActionHost` 与 `superview ==` 的早返回分支） | 防止回退成每 tick 全树 |
| 0.2s 轮询仍存在（`scheduledTimerWithTimeInterval:0.20`） | 防止把轮询删掉导致组字状态不刷新 |
| `gkx_viewDidLayoutSubviews` 与 `gkx_textDidChange` 内都出现 `gComposingActive` 刷新 | 防止事件驱动刷新被漏掉 |

### 4.2 `tests/test_privacy.py`（新增，源码级契约）

| 断言 | 防什么 |
| --- | --- |
| 源码含全部 13 个禁用选择器字面量 | 防止漏项 |
| 源码含 `CCTClearcutLogger`、`CCTClearcutUploader`、`GKBClearcutUploader`、`BreakpadController` 四个类名 | 防止漏类 |
| 源码**不含** `translation.googleapis.com`、`youtube`、`weather.com`、`googleapis.com` 任何字面量 | 防止误伤正常功能 |
| 源码不含 `NSURLProtocol`、`canInitWithRequest` | 防止走域名拦截路线 |
| `gkx_init` 函数体内不含 `touchesBegan/touchesMoved/touchesEnded/hitTest`（沿用既有断言） | 防违反红线 2 |
| 禁用函数内每个类都先 `NSClassFromString` 且带 `if (!cls) return;` 风格的空值保护 | 防止新版 Gboard 缺类时崩 |
| 禁用清单里不出现 `initSingleton`、`newEvent`、`uploadWithCompletionHandler`、`crashIf` | 防误伤自我保护逻辑 |
| 禁用清单里不出现 `GKBSoftKeyView` | 防越界到键盘触摸链 |

### 4.3 真机验收清单（必须人工确认，离线测试不证明运行时）

1. 九键拼音：输入 `nihao` → 按键显示「重输」→ 点击清空拼音，有中等触觉。
2. 九键空闲：按键显示「换行」→ 点击插入换行，有轻触觉（不返回表情页）。
3. 123 页 / 符号页：同样显示「换行」且可插入。
4. 26 键：不出现「换行」，原生回车保持。
5. 滑行输入（Glide Typing）：26 键与九键滑动输入正常，无卡顿。
6. 翻译：九键 → 翻译面板 → 输入一句 → 能正常翻译（证明未误伤 `translation.googleapis.com`）。
7. GIF/YouTube 搜索：表情/GIF 面板搜索能出结果（证明未误伤 `youtube/v3`）。
8. 天气建议条：能正常显示（证明未误伤 `weather.com`）。
9. 词库：首次安装后输入常用词有候选（证明 P1-3 未破坏部署）。
10. 连续弹收键盘 10 次：无卡顿、无崩溃、无内存告警。
11. Console 过滤 `[GXK]`：能看到「telemetry 已禁用 N 项」日志，N 符合预期。
12. 抓包（LOON，可选）：键盘使用 5 分钟，`play.googleapis.com/log` 无请求。

---

## 5. 风险与回滚

| 风险 | 概率 | 影响 | 缓解 | 回滚 |
| --- | --- | --- | --- | --- |
| 廉价路径条件写错导致标题不刷新 | 中 | 「重输」/「换行」切换滞后 | 保留 0.2s 轮询 + 事件驱动双保险；真机验收第 1/2 条必测 | 删廉价路径分支，回到全量刷新 |
| 全树组字扫描只在事件里跑，漏某路径 | 中 | 组字时仍显示「换行」 | `markedText` 是 O(1) 主路径；真机第 1 条必测 | 轮询里恢复全树 fallback（每 tick 一次） |
| no-op `CCTClearcutLogger -log:` 触发调用方异常 | 低 | 崩溃 | 该方法返回 void，调用方无返回值依赖；真机第 6/7/8 条覆盖表情/GIF/翻译面板 | 去掉该条，只保留 uploader 与 Breakpad 层 |
| `BreakpadController -start:` no-op 后崩溃表现异常 | 低 | 崩溃时无 minidump（预期行为） | 用户明确要求禁崩溃上报 | 去掉该条 |
| 方法编码与 IMP 签名不匹配 → 栈错乱 | 低 | 崩溃 | 每个 IMP 严格按 §2.2 编码表写；只处理 void/BOOL 返回 | 整段 `GXKDisableTelemetryUpload` 注释掉即可 |
| 新版 Gboard 类名变化 | 低 | 拦截失效（不崩） | 全部 `NSClassFromString` + 空值跳过；日志报数量 | 无需回滚 |

**回滚方式**：隐私与性能分成两个 commit，出问题可单独 revert 一个，不影响另一个。

---

## 6. 交付物

1. `dylib/gkx.m`（性能 P1-1~P1-5 + 隐私 `GXKDisableTelemetryUpload`）
2. `tests/test_perf.py`、`tests/test_privacy.py`（新增）
3. `docs/aegis/work/2026-11-14-optimize/20-checkpoint.md`、`90-evidence.md`
4. CI 产物 `libgkx.dylib` + 未签名 IPA + SHA256
