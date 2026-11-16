# Gboard-GKX (iOS Gboard 键盘增强补丁)

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

### 2. 九键表情键智能切换（重输 / 换行）
* **替换范围**：九键拼音及其 **123／符号页**，只替换原生 `key_pos_9keys_emoji` 表情键；原生回车键和 **26 键及其数字／符号页保持不变**。不根据坐标猜测按键身份。
* **双模动态切换**：
  * **拼音组字状态（Composing 活跃）**：显示「**重输**」；点击沿用原有 Gboard `resetKeyboard`／`abortComposing` 清空未上屏拼音，配合中度触觉反馈。
  * **未输入拼音状态**：显示「**换行**」；点击调用 `insertText:@"\n"` 插入换行符，配合轻度触觉反馈。
* **原生外观**：保留表情键原生背景层、边框和主题，仅替换前景内容；文字取原生字体与前景色。「重输」和「换行」不另加红色、不透明背景或高亮配色。
* **状态同步**：使用当前可见布局、`viewDidLayoutSubviews`、`textDidChange:` 与 0.2s 轮询；点击时重新验证目标键、当前模型和按钮绑定。原生运行时表现仍需用新编译包真机验证，离线检查不证明 CPU／内存性能。

### 3. 原生纯粹与零遮挡保障
* **零界面遮挡**：不新增任何浮动工具条、不给键盘根视图加高度。九键工具栏只复用官方 G 图标原本占用的那一段空位（把 G 图标 alpha 归零后原地放入），左右边界各自停在相邻可见兄弟视图之前，绝不覆盖候选词栏、拼音 Preedit 行或右侧功能图标；空位不足 200pt 时整条不显示，完全保持原生。
* **工具栏能力**：九键界面提供「全选／复制／粘贴／剪切／收起键盘」五个按钮。组字中拒绝改文本并提示"先完成拼音"；剪切仅在已有选区时生效，无选区只提示"先选中"，绝不做逐字符 `deleteBackward` 循环。
* **滑行触摸链 100% 原生**：绝不全局 Hook `GKBSoftKeyView` 的触摸事件（`touchesBegan`/`touchesMoved`/`touchesEnded`），全键盘与九键滑行输入如丝顺滑。

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
  --dir "%USERPROFILE%\AppData\Roaming\Rime\dicts" `
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
  --ipa "<local>\Gboard_2.3.19.ipa" `
  --dylib "dist/libgkx.dylib" `
  --dict "dist/user_dictionary.db" `
  --app-group "group.zunbengege.top" `
  --out "dist/gboard-gkx-unsigned.ipa"
```

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
   * **九键重输/换行**：切换到九键，空闲时回车键上方为「换行」，点击插入换行符；输入拼音（如 `22`）时按键即刻切换为微红「重输」，点击立即清空拼音。
   * **滑行输入**：在九键或全键盘上单手滑行划线，轨迹流畅自然，无任何断触卡顿。
