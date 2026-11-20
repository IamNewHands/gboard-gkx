# Gboard-NTR 项目接手与工程架构指南 (Agent.md)

> 本文档专为后续接手维护、开发与排错的 AI Agent（及开发者）编写。
> 汇总了项目核心架构、逆向注入机制、iOS 键盘扩展沙盒底层细节、历代重大 Bug 根因与规避红线。接手前请务必通读本文档。

---

## 1. 项目定位与核心边界

- **项目目标**：在 **iOS Gboard 2.3.19**（官方 IPA）基础上进行无源码逆向增强，在**100% 保留原生 Mozc 拼音引擎、官方界面排布与九键/全键盘滑行输入性能**的前提下，聚焦以下核心体验提升：
  1. **Rime 万象方案词库预置**（精选 60,000 高频词，Protobuf 精简无 comment，运行时防 Jetsam 杀后台）；
  2. **九键及其 123／符号页原生表情键智能切换**（输入拼音时为「重输」，清空拼音；只出候选未组字时为「收起」，直接收起键盘；空闲时为「换行」）。原生回车与26键不替换，保留原生键帽背景、边框与主题；两种标题不另加红色或高亮配色；
  3. **九键工具栏**（全选／复制／粘贴／剪切／收起），复用官方 G 图标 band，不加高度；
  4. **G 图标展开页裁剪**：去掉 YouTube 与联系人两页；
  5. **搜索历史单条删除**：每条历史右侧叠「×」，点掉即删（列表 + 持久化记录）；
  6. **常用语分页**：G 图标内与搜索／翻译／地图同级，叠加层展示已维护的短语，点击即上屏；钉子固定后连续输入，未固定点一条即关；维护入口两处——键盘面板右上角「编辑」（保底，不依赖主 App），以及主 App「设置 → Gboard」主菜单里的一行「常用语」（hook `mainMenuPageDescriptor` 复制原生行）。**键盘扩展进程里绝不能出现输入框**（alert 带输入框或内联 `UITextField`）：那会去要系统键盘，而系统键盘就是这个扩展自己，真机必闪退；键盘侧新增/修改一律走剪贴板；键盘侧也不要 present 任何提示框（扩展里 present 会再拉呈现上下文，同样闪退），提示只改导航标题。
   7. **打字流畅度**：轮询按需补帧（普通打字 2 拍 / 组字翻转 5 拍，空闲停表）且只挂默认 runloop 模式（绝不加 `NSRunLoopCommonModes`，否则动画/滚动期间继续抢主线程）、全树扫描按类指针缓存类名并 0.25s 节流 + 尾随补扫、`textDidChange` 与 `viewDidLayoutSubviews` 用序号合并成每帧最后一次、扫描热路径的类指针一次解析长期复用、工具条同宿主行复用 stack 与按钮且约束先撤后加、`GXKToolbarBand` 按邻居签名复用结果（挂载/撤走时 `gToolbarBandEpoch++` 失效）、诊断关闭时不建 ident 数组也不拼日志、工具条中心未变不失效布局、标点键未换不重挂手势、包内无词库时立刻 settle 不再逐次摸盘、触觉引擎闲置 2 秒释放、词库只随包带一份（主 App 的 `Frameworks/`）。详见 README 第 7 节与 `tests/test_perf.py`。
- **已移除**：地图分页的定位跳转（键盘接管、`prefs:` 级联、主 App 中转 alert）在真机上达不到目的，已整体删除，详见避坑 7。
- **极简原则**：工具栏仅叠加透明五格到根视图，以真实 G 图片图层可见区域定位，不增加键盘高度、不移动原生容器、不修改原生 alpha／hidden。候选、按键与独立 26 键体优先；无可靠几何证据或空位不足则不显示。字体唯一来源为九键回车键 label，禁止任意 UILabel／候选字号兜底。顶条 22pt 行是合法宿主：条高可压到行高（下限 18pt），标题偏移只用公开的 `titleEdgeInsets`，禁止覆写 UIKit 布局矩形回调（见避坑 9／10）。诊断接线已随 54734ad 全部移除。
- **技术载体**：Objective-C 动态库注入（`libgkx.dylib`），在扩展初始化时进行最小必要生命周期 Hook。
- **目标环境**：iOS 12.0 ~ iOS 18+，arm64 设备，支持 LCSign、SideStore、SideInstaller 等免越狱自签工具。

---

## 2. 仓库目录结构索引

```
gboard-ntr/
├── dylib/
│   └── gkx.m                          # 核心动态库源码：词库部署 + 九键重输/换行 + G 图标 band 工具栏 + 分页裁剪 + 搜索历史单条删除 + 常用语分页/设置主菜单维护
├── .github/workflows/
│   └── build-dylib.yml                # CI 云端编译流：macOS-15 runner，原生 clang 编译 arm64，ldid 伪签名
├── tools/
│   ├── inject.py                      # 本地注入核心：纯 Python Mach-O 零移动无损注入，原地改写 App Group，保留 Unix 755/644 权限
│   ├── dict_converter.py              # 词库转换器：万象词库解析、声调清洗、6万词容量上限与零 comment 紧凑 Protobuf 序列化
│   └── inspect_signed.py              # 签名与 Mach-O 结构自检工具
├── dist/                              # 本地构建输出与产物目录
│   ├── gboard-ntr-1.0-unsigned.ipa        # 重打包最新未签名 IPA
│   ├── user_dictionary.db             # 紧凑万象词库 (1.61 MB)
│   └── libgkx.dylib                   # CI 编译下载的动态库 (约 60 KB)
├── README.md                          # 仓库主说明与开发规范
└── agent.md                           # 本指南文件
```

---

## 3. 架构与注入底层机制

### 3.1 纯 Python Mach-O 零移动无损注入 (`tools/inject.py`)
- **零外部二进制依赖**：不使用 `optool`、`insert_dylib` 或 `LIEF`，完全用原生 Python `struct` 解析与修改 64 位 Mach-O。
- **Padding 空间复用原理**：
  Mach-O 文件头部的 Load Commands 之后到第一个真实 Section 之间有一段 `\0` 字节填充区（Padding）。
  `inject.py` 计算出新增一条 `LC_LOAD_DYLIB @rpath/libgkx.dylib` 所需的字节数，直接在 Padding 区域原地写入该命令，并更新 Header 的 `ncmds` 与 `sizeofcmds`。
  **由于没有移动后续任何 Section 数据，文件的所有 Section Offset / File Offset 完全保持原生有效，绝不破坏二进制完整性。**

### 3.2 App Group 原地改写机制
- **根因**：Gboard 官方二进制中强行绑定了 8 个 Google 官方 App Group（如 `group.com.google.keyboard`）。第三方自签描述文件无法获批该 Group 权限，系统在沙盒内返回 `nil` 路径，导致 Gboard 启动即抛异常闪退。
- **解决**：`inject.py` 原地扫描 Mach-O 数据，将所有的 `group.com.google.xxx` 原地替换为自定义 Group（`group.zunbengege.top`），并用 `\0` 补齐截断对齐。

### 3.3 Frameworks 落点与 `@rpath` 路径机制
- **关键细节**：Gboard 键盘扩展 `Gboard.appex/Gboard` 的 `LC_RPATH` 为 `@executable_path/../../Frameworks`。
  这表明动态链接器（dyld）寻找 `@rpath/libgkx.dylib` 的实际基准路径是**主 App 的 Frameworks 目录**（`Payload/Gboard.app/Frameworks/`），而非扩展自身的 Frameworks 目录。
- 注入脚本会自动解析 `LC_RPATH` 并落点至主 App 的 `Frameworks/`，同时保留正确的 Unix `0o755` 执行权限。

---

## 4. 历代重大教训与开发规范红线 (Must Read!)

后续若有任何新需求或调整，**必须以此清单为绝对准绳**，切勿重蹈覆辙：

### 🚫 避坑 1：严禁篡改键盘根视图高度约束（高度避让的惨痛教训）
* **历史教训**：曾试图通过 `updateViewConstraints` 向键盘根视图追加 `+34pt` 约束并位移视图来强塞工具条。结果在真机上导致候选词栏（`CandidateBar`）与拼音 Preedit 行被整体推下或遮挡，严重破坏正常输入。
* **开发准则**：**绝对不要动键盘根高度与 Header 容器的约束**！任何附加 UI 必须是原位按键替换或利用原有空余元素，不得挤压原生跑道。

### 🚫 避坑 2：严禁全局拦截按键触摸事件（滑行输入保护红线）
* **历史教训**：曾尝试在 `GKBSoftKeyView` 的 `touchesBegan/Moved/Ended` 上做全局 Hook。Gboard 的滑行打字（Glide Typing）依赖极高频的触摸采样，全局 swizzle 立即导致滑行断触、卡顿、丢轨迹。
* **开发准则**：**禁止全局拦截触摸事件链**。定制按键必须采用向目标按键添加独立子视图（如单一覆盖的 `UIButton`）的方式，让触摸直接由该按钮控件自身响应。

### 🚫 避坑 3：iOS 键盘扩展 Jetsam 内存硬红线（防闪退核心）
* **历史教训**：最初将万象全量数十万词库打包进去（文件达 10MB+），键盘一弹出即崩溃闪退。iOS 键盘扩展通常只有 30~50MB 物理内存上限，Mozc 反序列化超大 Protobuf 时直接瞬间触发 Jetsam 强杀（SIGKILL），且无任何崩溃堆栈。
* **开发准则**：
  1. 词库总条数严格压在 **60,000 条左右**；
  2. 转换 Protobuf 时**坚决清空 `comment` 字段**（省掉 6 万次散列字符串堆分配，体积从 2.18MB 降至 1.61MB）；
  3. 运行时内存增量严控在 4~6MB 内。

### 🚫 避坑 4：严禁对全屏容器（`win` / `UIInputSetContainerView`）设置不透明背景
* **历史教训**：曾试图通过给 `win` 或 `UIInputSetContainerView` 设置深色背景来消灭底栏浅色，结果导致键盘呼出时整块手机屏幕（上方聊天界面）变成一块不透明黑幕。
* **开发准则**：全屏容器 `win.backgroundColor` 必须恒为 `[UIColor clearColor]`。键盘外观应跟随原生 UIKit 的 `traitCollection` 毛玻璃背景，严禁暴力递归覆盖。

### 🚫 避坑 5：swizzle 必须按真实返回值类型声明原实现指针
* **历史教训**：`GKBFeatureFlagManager` 的 `enableYouTubeMiniApp`／`enableContactsMiniApp` 名字像 BOOL，实际返回 `GKBBoolFeatureFlag` 对象。若把原实现指针声明成 `BOOL (*)(id, SEL)`，返回值被截断，hook 里拿到垃圾地址，必崩。
* **开发准则**：写 hook 前先用 `dump_types.py` 查 method type encoding；`method_setImplementation` 的原实现指针签名必须与 encoding 严格一致。返回对象的 getter 想关掉功能时，优先改原对象的 `value`（保留对象身份），而不是伪造新对象。

### 🚫 避坑 7：定位设置页跳不过去，别再尝试（已整条删除）
* **历史教训（2026-11-17）**：为「G 图标 → 地图 → 开启位置信息服务」做过三轮尝试，全部真机无效并已删除：① 键盘扩展里直接开 `prefs:root=Privacy&path=LOCATION`（hook `GKBLocationPermissionCardView` + 叠按钮 + 三通道 extensionContext → `gkb_openURL:` → `UIApplication`），点击毫无反应；② 改为只记时间戳、由主 App 被中转拉起后弹「去系统设置」，用户判定"不符合需求，做了也没什么用"；③ 主 App 侧同样打不开 `prefs:`。
* **根因**：`NSExtensionContext` 的 `openURL:` 只放行宿主 App 自己的 URL scheme；`prefs:`／`App-Prefs:` 对第三方 App 也被系统静默拒绝。唯一能开的 `UIApplicationOpenSettingsURLString` 只到「设置 → Gboard」，进不了定位页。快捷指令能跳是因为它有独立授权。
* **开发准则**：涉及 iOS 隐私设置深链的需求先明确拒绝并说明原因，不要用「中转 + 弹窗」包装成看起来能用的方案。`tests/test_location_jump.py` 会断言这些符号不再出现，改动时不要绕过它。
* **配套准则**：用户不接 Console.app，所以任何"看日志判断"的设计都不可执行——失败必须画在屏幕上（改按钮标题等），日志只作辅助。

### 🚫 避坑 6：Windows 打包必须显式保留 Unix 权限（0o755 / 0o644）
* **历史教训**：在 Windows 上用标准 zipfile 解包重打包后，所有文件的外部属性变为 `0o666`，丢失可执行权限（Execute 标志），导致真机加载 dylib 时报权限拒绝。
* **开发准则**：`inject.py` 必须记录原包元数据，重打包时将 `create_system` 标记为 Unix(3)，主 App/扩展 Mach-O 与 `libgkx.dylib` 必须强制赋予 `0o755`，数据文件赋予 `0o644`。

### 🚫 避坑 8：卡顿不是内存问题，别去删二进制或资源包
* **历史教训（2026-11-17）**：用户反馈打字卡顿、动画掉帧。实测内存大头是 dyld 按需 mmap 的代码段（appex 24.2 MB、`gboard_framework` 15.5 MB、主 App 4.1 MB），删不掉也不该删；`Assets.car` 与各 `.bundle` 删了直接缺图缺字符串。真正的成本在每键触发的刷新循环：3 秒 × 5Hz 定时器 + 每拍 1500／800 节点全树扫描，连续打字时主线程每秒被吃掉 15~40 ms。
* **开发准则**：性能问题先量「每帧做了多少工作」，再谈内存。全树扫描必须 (a) 有常数级快路径，(b) 有最小间隔节流，(c) 被跳过的那次要能尾随补上。任何在 `layoutSubviews`／`textDidChange:` 路径上重建视图树的代码都要先问「能不能复用」。

### 🚫 避坑 9：严禁覆写 UIKit 的布局计算回调（键盘扩展闪退第一杀手）

* **历史教训（2026-11-19，47c08a3 包）**：工具栏要落在 22pt 顶条行上。UIButton 默认 `contentEdgeInsets` 上下各 6pt，把 22pt 行压成 10pt 内容区；16pt 标题行高 19.09pt 放不下，`titleRectForContentRect:` 返回 `CGRectZero`，整条被判「标题放不下」永不显示。为绕开它覆写了 `- (CGRect)contentRectForBounds:`（直接 return bounds）与 `- (CGRect)titleRectForContentRect:`（自己算矩形），结果真机**切到键盘直接闪退**。
* **根因**：键盘扩展的布局由系统布局循环反复求值，覆写里又回头读自身尺寸与标题，形成布局反馈循环，进程被系统杀掉；用户不接 Console.app，没有可用崩溃栈。
* **开发准则**：
  1. **禁止**覆写 `contentRectForBounds:`／`titleRectForContentRect:`／`titleRectForBounds:`／`backgroundRectForBounds:`／`intrinsicContentSize`／`sizeThatFits:` 这类由 UIKit 自己求值的布局回调。要偏移标题就用公开属性：`button.titleEdgeInsets = UIEdgeInsetsMake(-6.0, 0.0, -6.0, 0.0);`（负边距把 22pt 行的可用高度撑回整行）。
  2. 判定「放不放得下」只用纯算术：`[button.currentTitle sizeWithAttributes:@{NSFontAttributeName:font}]` 与 slot 尺寸比较；刷新路径里**不要**调用任何 UIKit 布局矩形方法。
  3. 闪退定位顺序：先做**两包逐 hunk diff**，找「唯一功能性新增」。d0398c0（能开、工具栏不显示）与 47c08a3（闪退）之间只多这两个覆写，删掉即恢复——有 diff 时不要靠推理猜。
  4. 任何让工具栏「整条静默不显示」的失败分支（标题放不下、band 不足 200pt、band 出根）都必须在真机可见处留信号；日志不是验收通道。

### 🚫 避坑 10：G 图标与 band 的测量契约（可见矩形 ≠ 绘制矩形）

* **历史教训（2026-11-18~19，d0398c0 前连续三包都不显示）**：真机日志显示 28 个采样全是 `scanGate=no-measurable-logo`，从未出现 `scan-success`。三个独立错误叠加：
  1. **可见矩形被祖先裁掉**：顶条行 logo 的 G 绘制矩形是 22x22，但被 402x26、`masksToBounds=1` 的祖先裁成 22x**2**，可见高度 2pt < 8pt 下限，于是「没有可测量的 G」。正解是保留未裁剪的**绘制矩形**作为兜底（`gToolbarImageDrawnRoot` 转 root 坐标后仍要过 8..64pt 校验），不能因为可见尺寸不合格就判定没有 G。
  2. **全宽容器不能当内容边界**：`GXKToolbarContentRect(logo)` 返回的是 402pt 宽的整行容器，拿它的右沿抬高 band 左界，left 直接顶到 right，band 宽 0 → `band-width`。正解：载体宽度 ≥ 行宽 − 8pt 时视为「就是这一行」，不参与抬高左界。
  3. **单候选失败即整条放弃**：九键候选行里的 G 会随布局短暂宽度归零，此时唯一可测候选消失，整条 toolbar 被 detach。正解是候选循环——失败就换下一个候选，而不是 return NO。
* **开发准则**：
  1. 测量分两层：**可见矩形**（祖先裁切+动画+透明度后的真实可见区）用于判「能不能点」，**绘制矩形**用于判「是不是那个图标」。两者不能互相替代。
  2. 22pt 顶条行是合法宿主：band 高度必须允许压到行高（`barHeight = MIN(max(glyph.height,28), row.bounds.size.height)`，下限 18pt），不能因为 28pt > 22pt 就整条拒绝。
  3. 任何「找到唯一候选」的路径都要能降级成「遍历候选、逐个尝试」；键盘布局在动画期会短暂改变尺寸，单点采样不足以判定不存在。
  4. 回归测试要覆盖真机实测数值：22pt 行 + 22x20 glyph + 56 载体 → band (56,0,346,22)，见 `tests/test_toolbar_geometry.py`。

### 🚫 避坑 11：出包 ≠ 发布，Release 必须单独执行

* **历史教训（2026-11-20）**：当天连出三包（c86e7cb / 5b6bd55 / 61b8d32），每次都重打了 `dist/gboard-ntr-1.0-unsigned.ipa`、都跑了 CI、都做了逐文件验包，但 Release 页面上的资产一直是上一版的（正文 SHA 与实际包不符），用户第二次问「为什么又没发布 release」。根因不是漏操作，是流程里根本没有这一步：`README` 的第 3 步止于「本地注入打包」，`agent.md` 的速查止于「校验产物」，两个文档都没有写「上传 Release」。
* **开发准则**：
  1. **打包的最后一步是发布。** 每次 `dist/` 里的 IPA 变了，就必须跑 `python tools/publish_release.py --asset dist/gboard-ntr-1.0-unsigned.ipa --repo IamNewHands/gboard-ntr`，否则这次改动对外不存在。
  2. **只维护一条 release。** tag 固定 `v1.0`，资产名固定 `gboard-ntr-1.0-unsigned.ipa`，就地 `--clobber` 覆盖；下载地址 `releases/latest/download/gboard-ntr-1.0-unsigned.ipa` 因此长期有效。不要新建 tag、不要堆积多个 release。
  3. **`--clobber` 不会刷新 `published_at`。** 它只换文件，页面时间仍停在 tag 首次发布那天，看起来像没更新。`publish_release.py` 用「置草稿 → 立刻发布」把时间重置成本次出包时间（约 1 秒下载链接 404 窗口，已接受）。
  4. **发布后必须读回校验三项**：`publishedAt` 是刚才的时间、资产 size 与 `dist/` 一致、正文 SHA-256 等于本包哈希。三项任一不符就是没发成。
  5. **正文里的 SHA-256 要跟着换。** 资产换了但正文还写旧哈希，等于告诉用户下载了一个校验不过的包。

---

## 5. 调试与出包操作速查

```powershell
# 1. 重新生成紧凑万象词库
python tools/dict_converter.py --dir "%APPDATA%\Rime\dicts" -o "dist/user_dictionary.db" --max 60000

# 2. 推送代码触发 GitHub Actions 编译 libgkx.dylib
git add dylib/gkx.m
git commit -m "feat/fix: ..."
git push origin main

# 3. 下载 CI 产物
gh run download <RUN_ID> -n libgkx -D dist/artifact
Copy-Item dist/artifact/libgkx.dylib dist/libgkx.dylib -Force

# 4. 一键注入打包未签名 IPA（--app-group 必填，漏掉脚本直接退出；--dict 漏掉词库不生效）
python tools/inject.py `
  --ipa "../ipa/Gboard_2.3.19.ipa" `
  --dylib "dist/libgkx.dylib" `
  --dict "dist/user_dictionary.db" `
  --app-group "group.zunbengege.top" `
  --out "dist/gboard-ntr-1.0-unsigned.ipa"
#    若 dist 目录 ACL 拒绝创建临时目录（WinError 5），加 --keep 指向仓库外目录：
#    --keep "<repo 外的临时目录>\gkx-pack-<tag>"，产物仍写 dist。

# 5. 校验产物 Mach-O 与权限
python tools/inspect_signed.py "dist/gboard-ntr-1.0-unsigned.ipa"

# 6. 发布到 GitHub Release（必做，漏了等于没发）
python tools/publish_release.py --asset dist/gboard-ntr-1.0-unsigned.ipa --repo IamNewHands/gboard-ntr
#    脚本会覆盖资产、重置 published_at、读回校验大小、打印固定下载地址与远端 SHA-256
```

> **第 6 步不是可选项。** 本地 `dist/` 出包只完成一半，Release 资产没换就等于没发布。
> 验收：`gh release view v1.0 --json publishedAt,assets` 的 `publishedAt` 是刚才的时间、
> 资产 size 与 `dist/` 一致、正文 SHA-256 等于本包哈希。
