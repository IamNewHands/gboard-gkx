# 最新续跑状态

## 笑脸键写入守卫（2026-11-20；源码/回归/CI/出包完成，真机待验收）

- 提交 `c86e7cb` 已推送 main；改动 4 处：`dylib/gkx.m`（新增守卫段 + 两处安装调用）、`tests/test_action_key.py`（新增 1 项契约测试）、`README.md`（新增一条说明）、`docs/aegis/work/2026-11-20-emoji-icon-guard/`。
- 守卫实现要点：`static void (*gOrigKeyUpdateView)(id, SEL);` 先透传原实现；只对 `key == gEmojiSoftKeyView`、`icon == gActionNativeIcon`、`GXKModelHasNativeActions` 成立的那一个键生效；清空前先把图存档进 `gActionNormalImage`／`gActionHighlightedImage`，撤键仍可还原。
- 返回类型处理（**已修正，首版判断错误**）：首版按 `id` 接管并回传返回值，真机切键盘即闪退。事后从 `Payload/Gboard.app/PlugIns/Gboard.appex/Gboard` 的 `__objc_const` 解出方法类型编码为 `v16@0:8`，即返回 void；按 `id` 包装会让 ARC 对从未被赋值的返回寄存器做 retain，故崩溃。现改为 `void` 包装、不读返回寄存器，并在安装时用 `method_getTypeEncoding` 校验首字符为 `v`，签名不符则不挂（宁可闪一帧也不崩键盘）；方法若来自父类则用 `class_addMethod` 新增而不改写父类。
- 安装时机：`gkx_init` 中在 `GXKApplyTelemetryBlockIfNeeded()` 之前挂一次（不影响 privacy 的 index 断言），`gkx_viewWillAppear` 中在 `GXKSymbolInstallHooks()` 之后补挂，幂等旗标 `gxk_icon_guard_hooked`。
- 回归：bundled Python 逐个文件跑 tests，10 个文件全 OK，共 134 项（test_action_key 26 项）；`git diff --check` exit 0。
- CI：run 44733139902 success（macos-15-intel，arm64/iOS12+/QuartzCore/ldid），artifact libgkx 239184 bytes，SHA256 `9caff9c2071eccf12b0c90b331f8387a4ac25762979975814875c46c0e1e2347`。
- 产物：`dist/gboard-ntr-1.0-unsigned.ipa` 35980293 bytes，SHA256 `09c3976561e5435c1c4ae739842c1cce9e09cad871e824832a97b0702de053a8`；输入原包 SHA256 `c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731`。
- 验包：ZIP CRC OK；2050 条目，仅新增 dylib 与词库、移除 3 个旧 CodeResources；2045 个原生文件逐字节未变；允许差异仅共享框架／主 exe／appex 三个二进制；两个可执行文件各 1 条 `@rpath/libgkx.dylib`，rpath 未移动；框架 8 处 app group 改写为 `group.zunbengege.top`。
- 待真机：LCSign 自签安装后验证九键拼音↔符号页切换时换行键不再闪圆圈，以及三态切换、9↔26 切换、滑行输入无回归。

## 切键盘闪退修复（2026-11-20，同批次）

- 现象：装 09c39765 包后切到 Gboard 键盘即闪退。
- 根因：守卫按 `id` 接管 `-[GKBSoftKeyView updateView]`，但该方法类型编码是 `v16@0:8`（void）。ARC 下 `id` 返回值会对返回寄存器做 `objc_retainAutoreleasedReturnValue`，void 方法没有赋值该寄存器，首次布局调用即崩。
- 修复提交 `5b6bd55`：`static void (*gOrigKeyUpdateView)(id, SEL);`、`static void gxk_key_updateView(...)` 不再读返回寄存器；安装前用 `method_getTypeEncoding` 校验首字符为 `v`，不符则不挂；方法若继承自父类用 `class_addMethod` 新增。
- CI：run 44735557750 success；dylib 239232 bytes，SHA256 `df495d715023fc05273fe736cb9d3ffe71cee186607d4f0a04a16a7d67a20e9c`。
- 产物：`dist/gboard-ntr-1.0-unsigned.ipa` 35980290 bytes，SHA256 `11df7f9fa60bee2a0057c590381f0cec164a9bc9c624c7d60196591cb1118ccc`；验包 CRC OK、2050 条目、新增 dylib 与词库（1688094 bytes）、移除 3 个 CodeResources、包内 dylib 与 CI 产物同哈希。
- 教训：从二进制方法表解类型编码，不要凭「取不到编码串」推断签名；包装未知签名方法一律先校验。

## 切页仍闪一帧的二次修复（2026-11-20，同批次）

- 现场：11df7f9f 包不闪退，但九键「拼音」↔「符号」反复切页时换行键仍闪一帧笑脸。
- 根因：首版守卫判据是对象同一性（`key != gEmojiSoftKeyView`、`icon != gActionNativeIcon`）且入口先看 `!gActionKeyButton`。切页那一拍原生对旧布局调 `updateView`，此时按钮已被 detach 摘掉、icon 已被原生重建，两条都放行 → 笑脸提交一帧。
- 修复：新增 `static __weak UIView *gGuardKey` 作归属；绑定建立时赋值，撤键时先清空再调还原用的原生 `updateView`；守卫改判「归属键 + emoji id + 九键 body + 同 window + 有原生 action」，图标每次现取。
- 回归：tests 10 文件全 OK；test_action_key 26 项，新增断言锁定「判据不得引用按钮/图标同一性」「图标先现取再清空」「gGuardKey = nil 先于原生 updateView」。
- 发布（补做）：本次三包（c86e7cb / 5b6bd55 / 61b8d32）都只重打了 `dist/`，Release 资产一直是旧的，用户两次追问「为什么又没发布 release」。已补 `tools/publish_release.py` 并把「第 6 步 发布」写进 README 与 agent.md 速查。最终 Release：tag `v1.0`，资产 `gboard-ntr-1.0-unsigned.ipa` 35980398 bytes，远端 digest `sha256:0c330dc4…cd0ee`，`published_at` 刷新为 2026-11-20T12:55:56Z，正文 SHA-256 已同步。
- 发布自动化（提交 `5980876`）：CI 新增 `publish` job（needs: build，contents: write）。仓库不含 Google 二进制，CI 不从原始包重新 inject，而是下载 Release 上那份成品 IPA，用新增的 `tools/swap_dylib.py` 替换 `Frameworks/libgkx.dylib`（复用 inject.py 的 unpack/repack/权限逻辑），再调 `tools/publish_release.py --refresh-sha` 覆盖上传并改正文哈希。`publish_release.py` 同时加了上传重试（`--clobber` 先删后传，断线会留空资产列表）。新增 `tests/test_release.py` 12 项锁定契约。验证 run 44740644479 全绿（build + publish），Release `published_at` 刷新为 2026-11-20T13:02:08Z，资产 35980398 bytes、digest 不变（本次 dylib 未变）。

