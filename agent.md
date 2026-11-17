# Gboard-GKX 项目接手与工程架构指南 (Agent.md)

> 本文档专为后续接手维护、开发与排错的 AI Agent（及开发者）编写。
> 汇总了项目核心架构、逆向注入机制、iOS 键盘扩展沙盒底层细节、历代重大 Bug 根因与规避红线。接手前请务必通读本文档。

---

## 1. 项目定位与核心边界

- **项目目标**：在 **iOS Gboard 2.3.19**（官方 IPA）基础上进行无源码逆向增强，在**100% 保留原生 Mozc 拼音引擎、官方界面排布与九键/全键盘滑行输入性能**的前提下，聚焦以下核心体验提升：
  1. **Rime 万象方案词库预置**（精选 60,000 高频词，Protobuf 精简无 comment，运行时防 Jetsam 杀后台）；
  2. **九键及其 123／符号页原生表情键智能切换**（输入拼音时为「重输」，清空拼音；空闲时为「换行」）。原生回车与26键不替换，保留原生键帽背景、边框与主题；两种标题不另加红色或高亮配色；
  3. **九键工具栏**（全选／复制／粘贴／剪切／收起），复用官方 G 图标 band，不加高度；
  4. **G 图标展开页裁剪**：去掉 YouTube 与联系人两页；
  5. **搜索历史单条删除**：每条历史右侧叠「×」，点掉即删（列表 + 持久化记录）；
  6. **常用语分页**：G 图标内与搜索／翻译／地图同级，叠加层展示已维护的短语，点击即上屏；钉子固定后连续输入，未固定点一条即关；维护入口两处——键盘面板右上角「编辑」（保底，不依赖主 App），以及主 App「设置 → Gboard」主菜单里的一行「常用语」（hook `mainMenuPageDescriptor` 复制原生行）。
- **已移除**：地图分页的定位跳转（键盘接管、`prefs:` 级联、主 App 中转 alert）在真机上达不到目的，已整体删除，详见避坑 7。
- **极简原则**：**已彻底废除并移除**悬浮工具条、键盘高度扩张约束、强制全屏深色注入及短语管理器。杜绝任何破坏原生界面视野与触摸链的做法。当前九键工具栏是**原地复用官方 G 图标 band**（G 图标 alpha 归零、工具条占同一段、空位不足即整条不显示），不新增视图高度、不位移任何原生容器。
- **技术载体**：Objective-C 动态库注入（`libgkx.dylib`），在扩展初始化时进行最小必要生命周期 Hook。
- **目标环境**：iOS 12.0 ~ iOS 18+，arm64 设备，支持 LCSign、SideStore、SideInstaller 等免越狱自签工具。

---

## 2. 仓库目录结构索引

```
gboard-gkx/
├── dylib/
│   └── gkx.m                          # 核心动态库源码：词库部署 + 九键重输/换行 + G 图标 band 工具栏 + 分页裁剪 + 搜索历史单条删除 + 常用语分页/设置主菜单维护
├── .github/workflows/
│   └── build-dylib.yml                # CI 云端编译流：macOS-15 runner，原生 clang 编译 arm64，ldid 伪签名
├── tools/
│   ├── inject.py                      # 本地注入核心：纯 Python Mach-O 零移动无损注入，原地改写 App Group，保留 Unix 755/644 权限
│   ├── dict_converter.py              # 词库转换器：万象词库解析、声调清洗、6万词容量上限与零 comment 紧凑 Protobuf 序列化
│   └── inspect_signed.py              # 签名与 Mach-O 结构自检工具
├── dist/                              # 本地构建输出与产物目录
│   ├── gboard-gkx-unsigned.ipa        # 重打包最新未签名 IPA
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

---

## 5. 调试与出包操作速查

```powershell
# 1. 重新生成紧凑万象词库
python tools/dict_converter.py --dir "%USERPROFILE%\AppData\Roaming\Rime\dicts" -o "dist/user_dictionary.db" --max 60000

# 2. 推送代码触发 GitHub Actions 编译 libgkx.dylib
git add dylib/gkx.m
git commit -m "feat/fix: ..."
git push origin main

# 3. 下载 CI 产物
gh run download <RUN_ID> -n libgkx -D dist/artifact
Copy-Item dist/artifact/libgkx.dylib dist/libgkx.dylib -Force

# 4. 一键注入打包未签名 IPA（--app-group 必填，漏掉脚本直接退出；--dict 漏掉词库不生效）
python tools/inject.py `
  --ipa "<local>\Gboard_2.3.19.ipa" `
  --dylib "dist/libgkx.dylib" `
  --dict "dist/user_dictionary.db" `
  --app-group "group.zunbengege.top" `
  --out "dist/gboard-gkx-unsigned.ipa"
#    若 dist 目录 ACL 拒绝创建临时目录（WinError 5），加 --keep 指向仓库外目录：
#    --keep "<local>\gkx-pack-<tag>"，产物仍写 dist。

# 5. 校验产物 Mach-O 与权限
python tools/inspect_signed.py "dist/gboard-gkx-unsigned.ipa"
```
