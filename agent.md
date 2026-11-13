# Gboard-GKX 项目接手与工程架构指南 (Agent.md)

> 本文档专为后续接手维护、开发与排错的 AI Agent（及开发者）编写。
> 汇总了项目核心架构、逆向注入机制、iOS 键盘扩展沙盒底层细节、历代重大 Bug 根因与规避红线。接手前请务必通读本文档。

---

## 1. 项目定位与核心目标

- **项目目标**：在 **iOS Gboard 2.3.19**（IPA）基础上进行无源码逆向增强，在**100% 保留原生 Mozc 引擎、九键/全键盘滑行输入性能**的前提下，补齐原生缺失的关键体验（万象超大词库、快捷工具栏、九键快速重输/换行、自适应外观模式、键盘高度调节）。
- **技术载体**：Objective-C 动态库注入（`libgkx.dylib`），在键盘扩展初始化时通过 Objective-C Runtime 进行精准 Hook 与 UI 增强。
- **目标环境**：iOS 12.0 ~ iOS 18+，支持 arm64 架构设备，支持免越狱自签（LCSign、SideStore、TrollStore、AltStore）。

---

## 2. 仓库目录结构索引

```
gboard-gkx/
├── dylib/
│   └── gkx.m                          # 核心动态库源码：包含全部 Hook、外观自适应、工具条、按键改造与面板
├── .github/workflows/
│   └── build-dylib.yml                # CI 云端编译流：macOS-15 runner，clang 编译 arm64，ldid 伪签名
├── tools/
│   ├── inject.py                      # 本地注入与重打包核心：纯 Python 解析 Mach-O，写入 LC_LOAD_DYLIB，改写 App Group
│   ├── dict_converter.py              # 词库转换器：将外部词库清洗并精选为 Mozc 专用的 user_dictionary.db
│   └── inspect_signed.py              # 签名与 Mach-O 结构自检工具
├── dist/                              # 本地构建输出与产物目录
│   ├── gboard-gkx-unsigned.ipa        # 最新重打包未签名 IPA
│   ├── user_dictionary.db             # 精选核心词库 (Top 6万词，约2.18MB)
│   └── libgkx.dylib                   # CI 下载的已编译动态库
└── agent.md                           # 本指南文件
```

---

## 3. 架构与注入底层机制

### 3.1 纯 Python Mach-O 零移动无损注入 (`tools/inject.py`)
- **不依赖第三方二进制工具**：不使用 `optool`、`insert_dylib` 或 `LIEF`，完全用原生 Python `struct` 解析与修改 64 位 Mach-O。
- **零移动空间利用原理**：
  Mach-O 文件头部的 Load Commands 之后到第一个真实 Section 之间通常存在一段 `\0` 字节填充区（Padding）。
  `inject.py` 计算出新增一条 `LC_LOAD_DYLIB @rpath/libgkx.dylib` 所需的对齐字节数（通常约 48~56 字节），直接在 Padding 区域原地写入该命令，并更新 Header 的 `ncmds` 与 `sizeofcmds`。
  **由于没有移动后续任何 Section 数据，文件的所有 Section Offset / File Offset 完全保持原生有效，绝不会破坏二进制结构。**

### 3.2 App Group 原地改写规避机制
- **根因**：Gboard 官方二进制中强行绑定了 8 个 Google 官方 App Group（如 `group.com.google.keyboard`）。第三方自签描述文件（如个人免费证书）无法获批该 Group 权限，系统在扩展沙盒内对这些 Group 返回 `nil` 路径，导致 Gboard 调用 `-[NSFileManager contentsOfDirectoryAtURL:]` 触发 Objective-C 异常直接崩溃闪退。
- **解决**：`inject.py` 原地扫描 Mach-O 数据，将所有的 `group.com.google.xxx` 原地替换为自定义 Group（如 `group.zunbengege.top`），并用 `\0` 截断对齐。

### 3.3 Frameworks 落点与 `@rpath` 路径陷阱
- **致命坑**：Gboard 键盘扩展 `Gboard.appex/Gboard` 的 `LC_RPATH` 声明为 `@executable_path/../../Frameworks`。
  这意味着动态链接器（dyld）寻找 `@rpath/libgkx.dylib` 的基准路径是**主 App 的 Frameworks 目录**（`Payload/Gboard.app/Frameworks/`），而非扩展自身的 Frameworks！
- 若将 `libgkx.dylib` 误放至 `Gboard.appex/Frameworks/`，启动时 dyld 将报 `image not found` 并闪退。因此注入脚本必须解析 `LC_RPATH` 并落点至主 App 的 `Frameworks/`。

---

## 4. iOS 键盘扩展核心机制与 7 大致命陷阱（Must Read!）

### ⚠️ 陷阱 1：`UIRemoteKeyboardWindow` 与 `UIInputSetContainerView` 全屏遮挡黑屏
- **现象**：呼出键盘时，键盘上方的整块手机屏幕（微信、备忘录等宿主 App 区域）变成不透明纯黑色，完全看不清输入框和聊天内容。
- **根因**：在 iOS 键盘扩展进程中，`root.window`（`UIRemoteKeyboardWindow`）与顶层容器 `UIInputSetContainerView` 的尺寸是**全屏**（如 393×852 pt，从状态栏到 Home 条）。
  **严禁对 `win` 或 `UIInputSetContainerView` 设置任何不透明背景颜色（如 `backgroundColor = #1C1C1E`）！**
  一旦设置，原本透明可穿透看到宿主 App 的上层区域会被画上一块巨大的不透明黑布。
- **正解**：`win.backgroundColor = [UIColor clearColor]`，且遍历子视图时对包含 `Container` / `Window` 的视图强制设为透明。键盘背景应由 UIKit 原生毛玻璃背景（Backdrop）或仅对 `vc.view` 内部呈现。

### ⚠️ 陷阱 2：外观模式（跟随系统 / 浅色 / 深色）与 UIKit 私有背景层
- **现象**：白天使用键盘依然是纯黑色，或者键盘按键是黑色而候选栏是白色（阴阳脸）。
- **根因**：
  1. Gboard 内部的 `theme.plist` 仅定义了 `theme_default` 与 `theme_dark`，不提供系统浅色主题的自由选择；
  2. UIKit 私有键盘背景层（`_UIInputViewContent`、`UIInputSetHostView`）完全根据 `traitCollection.userInterfaceStyle` 进行绘制；
  3. 若在代码中硬编码 `root.overrideUserInterfaceStyle = UIUserInterfaceStyleDark`，系统将永远锁定深色。
- **正解**：
  - 偏好键：`GXKAppearanceKey`（存储在 App Group 的 `NSUserDefaults`，值为 `"system"` / `"light"` / `"dark"`）。
  - 映射关系：
    - `"system"` -> `UIUserInterfaceStyleUnspecified`（UIKit 会自动按系统昼夜时间在白天给 Light、夜晚给 Dark）；
    - `"light"` -> `UIUserInterfaceStyleLight`；
    - `"dark"` -> `UIUserInterfaceStyleDark`。
  - 将该 style 同时赋给 `root.overrideUserInterfaceStyle`、`win.overrideUserInterfaceStyle` 以及私有背景层（`Backdrop`、`Content`），UIKit 的键盘底栏（地球键、麦克风栏）与毛玻璃背景将自动完美跟随。
  - Hook `traitCollectionDidChange:`，当系统在白天与夜晚切换时，跟随系统模式能够无缝自动重绘。

### ⚠️ 陷阱 3：iOS 键盘沙盒 Jetsam 内存硬红线（闪退杀手）
- **现象**：在设置里启用了外部词库，或者导入了超大词表后，键盘刚弹出或打几个字就突然崩溃闪退消失。
- **根因**：iOS 系统对键盘扩展（Keyboard Extension）施加了极其残暴的物理内存限制（**Jetsam 阈值通常仅 40~50MB**）。
  Mozc 词库（`user_dictionary.db`）采用 Protobuf 结构。若词表超过 30 万条（文件达 10~13MB），Mozc 在键盘扩展内存沙盒中将其反序列化为内存节点时，瞬时内存占用会激增突破 50MB，被 iOS 内核毫不留情地打上 SIGKILL 强杀，甚至在控制台没有崩溃堆栈！
- **正解**：
  **词库容量必须做减法**！通过 `tools/dict_converter.py` 进行频次过滤，严格精选核心高频词，控制在 **6 万条左右（约 2MB 文件）**。此时扩展常驻内存稳压在 15~20MB，处于绝对安全水位。

### ⚠️ 陷阱 4：严禁用 `setMarkedText` 模拟全选（并排重复文字 Bug）
- **现象**：点击工具条的「全选」后，输入框里的文字变成了“我们[我们]”、“你好[你好]”。
- **根因**：`UITextDocumentProxy` 并未向第三方键盘开放选择已有文字（Selection Range）的系统接口。`setMarkedText:selectedRange:` 是专供输入法未提交拼音预编辑高亮用的。对已提交到文档的文字强行调用它，UIKit 会在原文字旁边追加一段被标记的同名文字。
- **正解**：彻底废弃 `setMarkedText`。将全选功能设计为 **「全选复制」** 与 **「清空」**：
  - 全选复制：拼接 `proxy.documentContextBeforeInput` 与 `proxy.documentContextAfterInput`，一键写入 `[UIPasteboard generalPasteboard]`；
  - 清空：根据当前文字长度批量调用 `deleteBackward`。绝不再生成并排重复文字。

### ⚠️ 陷阱 5：滑行输入失效（严禁全局 Hook 按键触摸）
- **现象**：全键盘或九键滑行输入（Glide Typing）变得卡顿、断触或完全不画线。
- **根因**：曾经有人试图在 `GKBSoftKeyView` 的 `touchesBegan/Moved/Ended` 上做全局拦截。Gboard 的滑行轨迹捕捉依赖极其灵敏的高频触摸流，任何全局 swizzle 或在触摸链上加重度处理都会导致连续坐标丢帧，从而废掉原生滑行引擎。
- **正解**：
  - 工具栏下滑收起手势限制在顶部狭长区域（`pt.y < 46.0`），且设置 `cancelsTouchesInView = NO`；
  - 改造九键按键时，只将独立定制的 `UIButton` 作为子视图仅覆盖那一个目标键（笑脸键），绝不对键盘其他按键做全局触摸 Hook。

### ⚠️ 陷阱 6：工具条高度遮挡拼音预编辑与候选词栏
- **现象**：顶部工具条浮在键盘上方时，正好挡住了拼音预编辑文字（如 `nihao`）或者第一行候选词。
- **根因**：Gboard 的 `KeyboardHeader` 与 `Candidate` 视图原本从 `y = 0` 开始布局。如果在 `(0, 0, width, 32)` 强行塞一个工具条，二者空间发生冲突。
- **正解**：
  1. 在 `gkx_updateViewConstraints` 中向宿主声明键盘高度扩张约束（`constant = base + offset`，默认 offset = +34pt）；
  2. 在 `GXKCleanAndShiftUI` 中，将 Gboard 的 Header、Body 与候选词容器整体向下平移 `offset`，让出顶部专属跑道给快捷工具条，拼音与候选词 100% 完整可见。

### ⚠️ 陷阱 7：九键回车上方按键的动态双模（重输 / 换行）
- **需求**：九键右下角回车键上方原本是一个利用率极低的笑脸表情键。用户强烈希望它在输拼音时能一键重输（清空拼音），在不输拼音时能原生换行。
- **实现**：
  - 状态判断：`GXKIsComposingActive` 通过检查是否有 markedText、拼音候选视图内容以及回车键是否变为「确认」来精准判断是否在拼音输入中；
  - 拼音中：按键呈现微红「重输」，点击触发 Gboard 内部 `abortComposing` 并联动回退；
  - 闲置中：按键呈现自适应底色「换行」，点击向 proxy 插入 `\n`；
  - 定时器：0.25s 极轻量轮询，保证切换平滑即时。

---

## 5. 核心配置键（App Group: `group.zunbengege.top`）

| 偏好键 (Key) | 类型 | 可选值 | 说明 |
|---|---|---|---|
| `GXKAppearance` | String | `"system"` (默认) / `"light"` / `"dark"` | 键盘外观模式：跟随系统、浅色、深色 |
| `GXKKeyboardHeightOffset` | Double | `0.0`, `20.0`, `34.0` (默认), `50.0` | 键盘顶部避让扩展高度（紧凑/标准/偏高/较高） |
| `GXKDictEnabled` | Bool | `YES` (默认) / `NO` | 是否启用万象外部词库 |

---

## 6. 构建、打包与发布标准流程

### 6.1 云端编译（GitHub Actions）
1. 提交 `dylib/gkx.m` 修改并推送到远程仓库：
   ```powershell
   git add dylib/gkx.m
   git commit -m "fix/feat: ..."
   git push origin main
   ```
2. GitHub Actions 的 `build-dylib` workflow 会自动触发运行（基于 `macos-15` runner，耗时约 30~50 秒）。
3. 产物生成为 Artifact `libgkx`，内含已签名的 `libgkx.dylib`。
4. 使用 `gh` CLI 检查与下载构建产物：
   ```powershell
   gh run list --workflow=build-dylib.yml --limit 1
   gh run download <RUN_ID> -n libgkx -D dist/_artifact
   Copy-Item dist/_artifact/libgkx.dylib dist/libgkx.dylib -Force
   ```

### 6.2 本地注入与重新打包
本地必须准备好解密过的主包 IPA（如 `keyboard-2.3.19-eeveedecrypter.ipa`）。执行注入脚本：
```powershell
python tools/inject.py `
  --ipa "<local>\input\keyboard-2.3.19-eeveedecrypter.ipa" `
  --dylib ".\dist\libgkx.dylib" `
  --dict ".\dist\user_dictionary.db" `
  --app-group "group.zunbengege.top" `
  --out ".\dist\gboard-gkx-unsigned.ipa"
```
脚本执行 5 个标准步骤：解包 -> 原地注入 LC_LOAD_DYLIB -> 落点 dylib 与词库至 Frameworks -> 改写 App Group -> 剔除旧签名并重打包。

### 6.3 签名与真机安装
1. 使用 LCSign / SideStore / TrollStore 选择生成的 `dist/gboard-gkx-unsigned.ipa` 进行签名安装。
2. **iOS 键盘扩展进程缓存清除指南**：
   iOS 系统为了输入响应速度，会在后台常驻甚至强力缓存键盘扩展进程（`com.google.inputmethod.gboard`）。覆盖安装新版本后，经常会发现界面依然运行旧版代码。
   **标准刷新动作**：
   1. 打开系统「设置」→「通用」→「键盘」→「键盘」；
   2. 左滑将旧的 **Gboard** 彻底删除；
   3. 点击「添加新键盘」将 **Gboard** 重新添加，并进入点击「允许完全访问」；
   4. 彻底划掉杀死正在测试的宿主 App 后台（如微信、备忘录），重新唤起键盘。

---

## 7. 应急排错自检清单 (Troubleshooting)

| 症状 | 检查点 1 | 检查点 2 | 处置方案 |
|---|---|---|---|
| 键盘上方屏幕全黑 | 检查 `gkx.m` 里是否有视图设置了不透明背景色 | 检查 `win` 或 `UIInputSetContainerView` | 确保所有全屏容器 `backgroundColor = [UIColor clearColor]` |
| 白天键盘依然全黑 | 检查 `GXKAppearance` 偏好值 | 检查是否硬编码了 `darkStyle` | 在设置中切换到「跟随系统」或「浅色」，核对 `DesiredStyle()` |
| 键盘闪退打不开 | 检查是否注入了超过 8 万条的大词库（内存超限） | 检查 App Group 是否改写正确 | 停用外部词库，确保词库体积在 2MB（6万条）以内 |
| 键盘能打字但无工具条 | 检查 `libgkx.dylib` 是否正确落入主 App 的 `Frameworks/` | 检查 `GKBUIInputViewController` 是否命中 | 拆包检查 IPA 的 `Payload/Gboard.app/Frameworks/libgkx.dylib` 是否存在 |
| 微信/备忘录打字卡顿 | 检查是否有全局按键 touch hook | 检查定时器频率是否过高 | 保持 0.25s 轻量轮询，严禁全局 hook `GKBSoftKeyView` |
