# Gboard-GKX (iOS Gboard 键盘增强补丁)

**中文** | [English](README.en.md)

在 **iOS Gboard 2.3.19** 官方输入法基础上进行无源码逆向定制与轻量增强，通过 Objective-C 动态库（`libgkx.dylib`）注入与无损二进制改写实现。

> **核心设计哲学**：**保持绝对原生，拒绝过度侵入**。
> 100% 完整保留 Google 官方原生 Mozc 拼音引擎、键盘排布与滑行输入（Glide Typing）手感，杜绝界面遮挡与内存闪退，只专注于最刚需的核心体验提升。

---

## 🌟 核心特性

### 1. Rime 万象词库集成（轻量防 Jetsam 杀后台）
* **语料精选**：从 Rime 万象方案全量词表中严格筛选出 **60,000 条高频核心词库**（Top 45,000 高频词 + 10,000 常用成语俗语 + 3,000 全国行政地名 + 2,000 缩写简语），涵盖日常 99% 的核心拼音输入。
* **Protobuf 内存与体积瘦身**：
  * 在 Protobuf 序列化中剔除了冗余的 `comment` 字段，单文件二进制体积从 2.18 MB 骤降至 **1.61 MB**。
  * 在 Mozc C++ 反序列化时**避免了 60,000 次堆内存分配**，扩展运行时内存增量控制在 **4~6 MB** 安全区间，彻底解决 iOS 键盘扩展因 Jetsam 物理内存超限导致的闪退问题。
* **无感部署**：初次安装或更新后，扩展启动时自动将词库无感写入 App Group 共享容器（`group.zunbengege.top/user_dictionary.db`），即装即用。
* **只随包带一份**：词库只落在主 App 的 `Frameworks/user_dictionary.db`。键盘扩展的 `LC_RPATH` 是 `@executable_path/../../Frameworks`，指的就是这一份；再往 `.appex` 里复制一份只是白占 1.7 MB 安装体积，运行时永远读不到。部署代码按「bundle 内 → 主 App Frameworks → 相对上跳两级」逐条 `fileExistsAtPath` 探测，两个进程都能找到。

### 2. 九键表情键智能切换（重输 / 换行）
* **替换范围**：九键拼音及其 **123／符号页**，只替换原生 `key_pos_9keys_emoji` 表情键；原生回车键和 **26 键及其数字／符号页保持不变**。不根据坐标猜测按键身份。
* **双模动态切换**：
  * **拼音组字状态（Composing 活跃）**：显示「**重输**」；点击沿用原有 Gboard `resetKeyboard`／`abortComposing` 清空未上屏拼音，配合中度触觉反馈。
  * **未输入拼音状态**：显示「**换行**」；点击调用 `insertText:@"\n"` 插入换行符，配合轻度触觉反馈。
* **原生外观**：保留表情键原生背景层、边框和主题，仅替换前景内容；文字取原生字体与前景色。「重输」和「换行」不另加红色、不透明背景或高亮配色。
* **状态同步**：使用当前可见布局、`viewDidLayoutSubviews`、`textDidChange:` 与 0.2s 轮询；点击时重新验证目标键、当前模型和按钮绑定。原生运行时表现仍需用新编译包真机验证，离线检查不证明 CPU／内存性能。

### 3. 原生纯粹与零遮挡保障
* **零界面遮挡**：不给键盘增加高度、不移动原生容器。工具栏左缘同时避开 G 的已测量可见图片右缘 +4pt 与 G 按键的完整触摸区域；挂在根视图，自有点击条带默认 28pt，宿主行只有 22pt 时压到行高（下限 18pt）而不是整条消失；文字和分割线单独对齐真实 G 图片中心，不把点击条带挤进相邻原生行。原字号文字放不下时仍不显示。空位不足 200pt、存在独立可见 26 键体、组字中或与原生候选／按键／功能图标重叠时，整条不显示。
* **不隐藏原生内容**：工具栏使用透明底色，不改 G、语音按钮等原生内容的 `alpha` 或 `hidden`；原生内容出现时工具栏让位，不以隐藏原生内容换取出场。
* **竖向跟实际图片图层**：G 使用 `GKBImageViewWithBackground`／`GKBImageLayer`，不是普通 `UIImageView`。用实际 `contentsGravity`、`CGImage` 像素尺寸与 `contentsScale` 算显示矩形，再与真实父图层 `masksToBounds` 裁剪区域相交；不把 36pt 载体当作 22pt 图片，不使用虚构方块兜底。动画、变换、蒙版或不完整绑定无法可靠测量时保持原生。顶条行里的 G 常被 26pt 高、`masksToBounds=1` 的祖先裁成 2pt 可见高度，此时用未裁剪的绘制矩形（仍须过 8..64pt 校验）作锚点，不因可见尺寸不合格就判定没有 G。条高默认 28pt、行高不足时压到行高；可见图片矩形不等于不透明像素边界。
* **外观跟原生功能键走**：字体只读九键回车键 `key_pos_9keys_return` 的 `idToViewDict[@"label"]`，不再读取任意标签或候选词字号；来源失效立即退回原包验证过的 Roboto-Regular 16pt（同尺寸系统字体兜底）。文字色优先读当前绑定的原生表情键图标，退回回车标签与系统主题色。不自动缩小原生字号；五格保留 0.5pt、18% 透明度分割线，随文字对齐 G 中心且完整留在点击条带内，不增加 arrangedSubviews。
* **工具栏能力**：九键界面提供「全选／复制／粘贴／剪切／收起」五个按钮。组字中拒绝改文本并提示"先完成拼音"；剪切仅在已有选区时生效，无选区只提示"先选中"，绝不做逐字符 `deleteBackward` 循环；「全选」后 15 秒内可直接「剪切」同一段文本。操作成功不弹提示（避免连点卡顿），只有失败才短暂改按钮标题。
* **缓存不掩盖原生变化**：布局／文本／生命周期事件重建弱引用障碍注册表；隐藏键盘体和暂时没有图片的载体也先注册，每次复用读取当前可见性／内容。九键继承 26 键类，必须先判九键、再排除独立 26 键，不能只看旧九键是否仍在。
* **滑行触摸链 100% 原生**：绝不全局 Hook `GKBSoftKeyView` 的触摸事件（`touchesBegan`/`touchesMoved`/`touchesEnded`），全键盘与九键滑行输入如丝顺滑。

### 4. G 图标分页裁剪与搜索历史单条删除
* **去掉两个分页**：G 图标展开页不再出现 YouTube 与联系人两页，三层兜底——`GKBFeatureFlagManager` 的 `enableYouTubeMiniApp`／`enableContactsMiniApp` 返回 `value = NO` 的 flag 对象、`GKBMiniAppExtensionBase` 的 `isMiniAppEnabled:` 对命中项返回 `NO`、`GKBMiniAppManager` 的 `availablePickerItems` 过滤掉这两项。任一类在新版 Gboard 中消失就自动跳过，降级为原生行为。
* **再隐藏 GIF 与贴纸两页**：26 键表情面板里的「GIF」「贴纸」两个分类同样从分页项里过滤掉，只留 emoji 与颜文字。identifier 真实值是 `gif`／`sticker`（从 `gboard_framework` 的 `__data` CFString 常量里读出来的），按整词比较，避免误伤 `gift` 这类词。
* **identifier 按内容匹配**：`youtube`／`contacts` 的常量在二进制里取不到可靠值，仍用 `NSString` 小写包含匹配；`gif`／`sticker` 走整词相等，不按域名或 URL 判断。
* **搜索历史单条删除**：搜索分页每条历史记录右侧叠一个 28pt 的「×」，点击即从当前建议数组删掉该条并重刷列表，同时把持久化记录里同名的条目去掉（只删不造：只有键名含 `RecentQueries` 且确实命中才写回）。
* **不碰 cell 布局**：× 是 `contentView` 上的叠加按钮（`autoresizingMask` 跟随），不参与原生自动布局、不改行高、不改约束。

### 5. 地图分页定位：完全还原原生（不做任何跳转）
* **一行代码都不留**：地图分页的「开启位置信息服务」就是 Gboard 原生行为。不装 hook、不叠按钮、不改卡片布局，也不做任何「先唤起主 App 再弹提示」的中转——这套方案在真机上达不到目的，已整体删除。
* **为什么做不到**：键盘扩展的 `NSExtensionContext` 只放行宿主 App 自己的 URL scheme；主 App 里 `prefs:root=Privacy&path=LOCATION` 同样被系统静默拒绝，唯一能开的 `UIApplicationOpenSettingsURLString` 只到「设置 → Gboard」，进不了定位页。快捷指令能跳是因为它有独立授权，第三方 App 与键盘扩展都没有。
* **回归护栏**：`tests/test_location_jump.py` 断言源码里不再出现 `GXKLocation*` / `prefs:root=Privacy` / `App-Prefs:root` / `UIApplicationOpenSettingsURLString` / `x-gxk-location`，避免这套无效方案被重新带回来。

### 6. 常用语分页（G 图标内，与搜索／翻译／地图同级）
* **分页入口**：`GKBMiniAppManager` 的 `availablePickerItems` 末尾追加一项「常用语」（`GKBExtensionSegmentedControlItem`，identifier `gxk_phrases`，图标用 `UIGraphicsImageRenderer` 现画「语」字，不依赖资源名）。`GKBMiniAppExtensionBase` 的 `miniAppPicker:didSelectItem:atIndex:` 命中该 identifier 时改为弹自己的面板，其余分页原样回落。
* **分页项必须是 `GKBExtensionSegmentedControlItem`**（真机崩溃换来的结论）：分页条是 `GKBExtensionSegmentedControl`，它建按钮时对每个 item 依次发 `badgeableViewType`／`controlItemType`／`accessibilityIdentifier`／`accessibilityLabel`。早先用的 `GKBAppStripItem` 这四条一条都不响应，26 键点表情第一次打开分页条就 `-[GKBAppStripItem badgeableViewType]: unrecognized selector` 崩掉整个键盘扩展（九键的表情键被换成了重输/换行，所以历史版本从未走到这条链路）。该类只有无参 `init`，属性逐个 set；`setIdentifier:` 内部会同步 `accessibilityIdentifier`。
* **面板是叠加层**：`GXKPhrasesPanel` 铺满键盘视图 `bounds`，`layoutSubviews` 手算 frame，**不新增任何约束、不改键盘高度**。顶部有标题、钉子按钮、「编辑」与关闭「×」，中间是常用语列表，底部一行提示。
* **面板配色跟随键盘皮肤，而不是跟随系统外观**：Gboard 皮肤可以和系统深浅模式不一致，所以面板不读系统外观开关，改为直接采样键盘本体里面积最大的那块不透明背景色当底色、取同键盘原生标签的文字色当主文字色，再按底色亮度补一层对比度保护（对比度不够才退回内置色）。键盘换肤或深浅切换时由 `didMoveToWindow`／`traitCollectionDidChange:` 重算，且只在颜色真的变了才刷新；单元格不再露出系统白底，编辑器与钉子按钮同样处理。
* **钉子固定**：钉子关闭（默认）时点一条常用语就上屏并立即关闭面板；钉子打开后点多少条都不关，可以连续输入。状态存 App Group 的 `GXKPhrasesPinned`。
* **上屏方式**：通过 `UITextDocumentProxy` 的 `insertText:` 写入，和原生输入完全同一条路。
* **维护入口两处，键盘里那个才是保底**：
  * 键盘面板右上角「编辑」→ 直接弹出编辑器，**不依赖主 App**，任何情况下都能增删改。
  * 主 App「设置 → Gboard」**主菜单里的一行「常用语」**，和「搜索设置」「键盘设置」同一层级。做法是 hook `GKBSettingsViewController` 的 `mainMenuPageDescriptor`，复制一条原生设置行（沿用它的 `type`／`settingID`）只换标题与 `key`，插到「搜索设置」后面；点击由 `GKBSettingsPageViewController` 的 `collectionView:didSelectItemAtIndexPath:` 认领，非本行原样回落原生。
  * 编辑器是 `GXKPhrasesEditorController`：`+` 新增，点行编辑，左滑删除，自带「完成」。改完发 `GXKPhrasesChangedNotification`，键盘面板收到即刷新。
  * **键盘进程里没有任何「能打字」的入口**：点「+」/点行不再弹带输入框的 alert，改为读剪贴板——先把文字复制好，回来点「+」即新增、点某行即用剪贴板内容替换。剪贴板为空时也不弹提示框，只让导航标题闪一下「先复制文字」。原因见下条。
  * 数据存 App Group 的 `GXKPhrases` 数组，键盘与主 App 共享同一份。
* **一律全屏 modal，不 push**：主 App 的设置页跑在 Google 自绘的 `GOONavigationController` 里，往它上面 push 出来的控制器真机上是白屏（早先挂在「搜索设置」导航栏的那版就栽在这里）。所以编辑器统一包一层 `UINavigationController` + `UIModalPresentationFullScreen` present 出来。
* **键盘扩展里连普通 alert 也不要弹**：不只是带输入框的 alert——扩展内 `presentViewController:` 任何控制器都会再拉一次呈现上下文，真机实测「剪贴板为空时点 +」照样闪退。键盘侧所有提示统一走 `gxkFlashHint:`（改 `self.title` 1.8 秒后复原），只有编辑器本身是唯一允许 present 的控制器。
* **键盘扩展里绝不能弹输入框**：`UIAlertController` + `addTextFieldWithConfigurationHandler`（或任何内联 `UITextField`）会去要系统键盘，而系统键盘就是这个扩展自己，系统会递归激活同一扩展并杀掉进程。真机实测：G 图标 → 常用语 → 编辑 → 新增，必闪退；删除与上屏不受影响。所以 `GXKIsKeyboardExtension()` 为真时一律走剪贴板，主 App 侧（普通 App 进程）仍保留 alert 输入。
* **为什么复制原生行而不是硬造**：二进制里查不到任何 `GKBSettingType*` 字符串，`GKBSettingsItem` 的 type 枚举值无法静态确定，硬塞会有崩风险；复制一条真实存在的行才能保证渲染、点击、埋点行为与原生完全一致。

### 7. 打字流畅度：把每键的刷新成本压到常数级
* **轮询窗口按需**：状态同步仍靠 `NSTimer`（0.2s），但补帧次数从每键 15 拍降到普通打字 2 拍（`GXK_POLL_SETTLE`），只有「组字 ↔ 空闲」真的翻转时才用 5 拍（`GXK_POLL_BURST`）。空闲自动停表，不留常驻定时器。
* **类名判定按类指针缓存**：全树扫描原本对每个节点调一次 `NSStringFromClass` 再做两次 `containsString`；现在第一次见到某个 `Class` 就把结果记进 `gViewKindCache`，之后直接查表。
* **全树扫描节流 + 尾随**：`GXKComposingFullScan` 最快 0.25s 跑一次（`GXK_COMPOSING_SCAN_MIN_INTERVAL`）；被节流跳过的那次用一次 `dispatch_after` 尾随补扫，且只有状态真的翻转才触发界面刷新。代理已经明确给出组字标记时走 O(1) 路径，完全不扫。
* **工具条不再每拍重建**：同一宿主行（G 图标行）复用已有 `UIStackView` 与 5 个按钮，只同步配色；约束先 `deactivateConstraints:` 再 `activateConstraints:`，不层层叠加。装饰扫描按 band 记忆，同一个 band 只走一次 800 节点。
* **触觉引擎闲置即释放**：`prepare` 会让 Taptic 一直预热，停手 2 秒（`GXK_HAPTIC_IDLE_SECONDS`）就把两个 `UIImpactFeedbackGenerator` 置空，下次点击再懒建。连续点击期间不重建，手感不变。
* **钉子状态不强制落盘**：`GXKPhrasesPinned` 只有键盘进程自己读写，去掉 `synchronize`；常用语正文 `GXKPhraseSave` 的 `synchronize` 必须保留——主 App 编辑、键盘读取，跨进程要立刻可见。
* **轮询只挂默认模式**：`scheduledTimerWithTimeInterval:` 本身已把表挂到默认模式，原先再补一行 `addTimer:forMode:NSRunLoopCommonModes` 会让 0.2 秒的状态轮询在滚动、动画、触摸跟踪期间继续抢主线程——那正是「动画卡顿」的来源。现在全源不出现 `NSRunLoopCommonModes`。
* **高频回调合并成最后一次**：`textDidChange` 与 `viewDidLayoutSubviews` 一帧内可能连来几十次。两者都改成「递增序号 + `dispatch_async` + 块内比对序号」，只有最后一次真正刷新，前面排队的直接丢弃；布局回调的同步段不再直接跑任何全量刷新。
* **扫描热路径类指针缓存**：`NSClassFromString` 原本在 1500 节点的循环里对每个软键都要查一次运行时类表。现在统一走 `GXKClassCached(name, &slot)`，第一次解析成功才写缓存（类晚加载时会自动重试），五个扫描函数体内已无 `NSClassFromString`。
* **band 结果按邻居签名复用**：`GXKToolbarBand` 的邻居可见性判定要沿父链 `convertRect`，是这条路径上唯一还会每拍重复的工作。现在先算一个只读 `frame/hidden/alpha` 的邻居签名，行尺寸、G 图标位置、装饰数量、签名、代次全都没变就直接返回上次结果；挂载与撤走时自增 `gToolbarBandEpoch` 强制失效。
* **回归护栏**：`tests/test_perf.py` 锁住上述各条（缓存必须早于 `NSStringFromClass` 返回、扫描必须节流且带尾随、普通打字只补两拍、约束必须先撤后加、触觉闲置释放、钉子不同步、词库只打一份、轮询不挂 CommonModes、高频回调合并到最后一次、热路径类指针缓存、band 邻居签名复用）。

---

## 📐 开发规范与架构红线 (Development Standards)

为了保证后续功能的迭代与调整不会破坏键盘的核心稳定性，所有后续开发必须严格遵守以下**五大红线规范**：

### 🚫 红线 1：最小侵入原则，严禁篡改键盘根视图约束与高度
* **规范**：Gboard 的 `_keyboardHeader`、`_keyboardBody` 和 `GKBNibView`（候选词行）均有官方严密的约束系统。
* **禁区**：严禁通过 `updateViewConstraints` 强行添加根高度扩张约束，严禁递归位移 Header/Body 容器。任何根高度与坐标的篡改都会导致特定机型或横屏下候选词被挤出屏幕或产生上下黑白空隙。

### 🚫 红线 2：滑行触摸保护，严禁全局拦截按键触摸事件
* **规范**：Gboard 的滑行输入（Glide Typing）对触摸采样率和事件连贯性要求极高。
* **禁区**：严禁在 `GKBSoftKeyView` 或其父类上全局替换 `touchesBegan:withEvent:`、`touchesMoved:withEvent:`、`touchesEnded:withEvent:`。按键定制只能采用**在目标软键上挂载独立子视图控件（如单一 UIButton）**的方式进行局部呈现。

### 🚫 红线 3：内存与防 Jetsam 硬指标（必须严格受限）
* **规范**：iOS 键盘扩展进程受到内核 Jetsam 守护进程的严苛物理内存限制（通常仅 30MB ~ 50MB 水位）。
* **指标**：
  1. 外部词库 `user_dictionary.db` 总词条数**绝对禁止超过 70,000 条**（文件体积严禁超过 2.5 MB）。
  2. 转换 Protobuf 时，所有 Entry 必须省略非必要的 string 属性（如 `comment` 必须为空），避免 C++ 反序列化时产生几万次散列堆分配。
  3. 严禁在 `libgkx.dylib` 中引入庞大的静态数据结构或无法释放的常驻缓存。

### 🚫 红线 4：Windows 打包必须严格保留 Unix 权限元数据
* **规范**：在 Windows 文件系统上解包/重打包 ZIP 时，文件属性默认为 `0o666`，丢失可执行权限。
* **要求**：`tools/inject.py` 必须以二进制方式记录原 IPA 内的 Unix 权限，并在重新打包时将 `libgkx.dylib`、主 App 与扩展二进制显式标记为 `0o755`（`rwxr-xr-x`），数据文件标记为 `0o644`。缺失执行权限会导致自签工具报错或扩展启动被系统 SIGKILL。

### 🚫 红线 5：无损二进制注入与 App Group 等长改写
* **规范**：Mach-O 注入严禁依赖外部闭源或高风险二进制重写工具。
* **实现**：
  1. 仅在 Load Commands 后的原装全零填充区（Padding）原地写入 `LC_LOAD_DYLIB`，禁止移动后续任何 Section 偏移。
  2. 改写 App Group（如 `group.zunbengege.top`）必须使用等长或更短字符串原地覆盖并以 `\0` 补齐，严禁超出原槽位长度。

---

## 📂 仓库结构

```
gboard-gkx/
├── dylib/
│   └── gkx.m                      # 核心注入源码：万象词库部署 + 九键重输/换行按键管理
├── .github/workflows/
│   └── build-dylib.yml            # CI 编译流：macOS-15 runner，原生 clang arm64 + ldid 伪签名
├── tools/
│   ├── inject.py                  # 纯 Python Mach-O 注入、App Group 原地改写与 Unix 权限打包
│   ├── dict_converter.py          # 词库转换器：清洗万象 YAML/文本，精选 6 万词生成紧凑 Protobuf
│   └── inspect_signed.py          # 只读元数据自检工具：校验 Mach-O、依赖链与权限
├── dist/                          # 构建产物与词库生成目录
│   ├── user_dictionary.db         # 转换生成的紧凑万象词库 (1.61 MB)
│   ├── libgkx.dylib               # CI 编译产物
│   └── gboard-gkx-unsigned.ipa    # 最终交付的未签名 IPA
├── README.md                      # 本文档与开发规范
└── agent.md                       # 逆向工程细节与避坑历史记录
```

---

## 🛠️ 构建与出包流程

### 1. 词库构建（如有新词库源）

```powershell
python tools/dict_converter.py `
  --dir "%APPDATA%\Rime\dicts" `
  -o "dist/user_dictionary.db" `
  --max 60000
```

### 2. 云端编译 `libgkx.dylib` (GitHub Actions)

修改 `dylib/gkx.m` 后，提交并推送到 GitHub：
```powershell
git add dylib/gkx.m
git commit -m "feat/fix: ..."
git push origin main
```
CI 将在 macOS-15 runner 上自动执行 arm64 clang 编译并使用 ldid 伪签名。构建成功后下载产物并放置到 `dist/libgkx.dylib`：
```powershell
gh run download <RUN_ID> -n libgkx -D dist/artifact
Copy-Item dist/artifact/libgkx.dylib dist/libgkx.dylib -Force
```

### 3. 本地无损注入与打包

```powershell
python tools/inject.py `
  --ipa "Gboard_2.3.19.ipa" `
  --dylib "dist/libgkx.dylib" `
  --dict "dist/user_dictionary.db" `
  --app-group "group.zunbengege.top" `
  --out "dist/gboard-gkx-unsigned.ipa"
```

`--app-group` 是必填参数，漏掉脚本直接退出（exit 2）。真机上漏掉这一步的包会表现为：打开 Gboard 应用闪退、键盘锁在 26 键切不到九键。

> `group.zunbengege.top` 只是本机自签描述文件授权的**示例** App Group。换用你自己的描述文件时必须同步改三处：`dylib/gkx.m` 顶部的 `GXKGroup`、`tools/inject.py` 里的默认 group、以及打包命令的 `--app-group`。三处不一致同样表现为启动闪退或切不到九键。

注入脚本将自动执行：
1. 解包原 IPA 并解析 Unix 文件权限与时间戳；
2. 在 `Gboard.appex/Gboard` 的 Mach-O Padding 区写入 `LC_LOAD_DYLIB @rpath/libgkx.dylib`；
3. 将 `libgkx.dylib` 部署至主 App 的 `Payload/Gboard.app/Frameworks/`（因扩展 `@rpath` 指向主 App）；
4. 原地改写二进制中 8 处 Google 官方 App Group 为自签描述文件支持的 `group.zunbengege.top`；
5. 重打包并赋予可执行文件 `0o755` 权限。

---

## 📱 签名安装与真机验证

1. **自签工具安装**：使用 **LCSign**（或 SideInstaller、SideStore、TrollStore）导入 `dist/gboard-gkx-unsigned.ipa` 进行自签并安装至 iOS 设备。
2. **完全访问权限**：安装后进入系统 **「设置」→「通用」→「键盘」→「键盘」→「Gboard」**，打开 **「允许完全访问」**（词库与配置读取依赖 App Group 容器）。
3. **扩展缓存刷新（关键技巧）**：
   * iOS 拥有强力的键盘扩展常驻缓存机制，覆盖安装后若未生效，建议先在设置中删除 Gboard 键盘，重新添加并重新赋予完全访问权限；或重启宿主 App（如微信、备忘录）。
4. **功能验收点**：
   * **词库测试**：拼音输入 `aerjinshan`（阿尔金山）、`wanxiang`（万象），候选栏前列能准确出现万象专有词。
   * **九键重输/换行**：切换到九键，空闲时回车键上方为「换行」，点击插入换行符；输入拼音（如 `22`）时按键即刻切换为「重输」，点击立即清空拼音。
   * **滑行输入**：在九键或全键盘上单手滑行划线，轨迹流畅自然，无任何断触卡顿。

---

## ⚠️ 免责声明与许可

* 本项目**不包含**任何 Google 官方二进制或 IPA，仓库里只有注入源码、词库转换脚本与文档。使用前需自行取得正版 **Gboard 2.3.19** IPA。
* 注入改造后的包**仅限个人设备自签测试**，不得分发、不得商用。Gboard 与 Mozc 的著作权归 Google 所有。
* 自签描述文件、证书与 App Group 需自行准备；仓库里的 `group.zunbengege.top` 只是示例值。
* 改造涉及未签名的二进制注入，升级系统或更换签名工具后行为可能变化，风险自负。
