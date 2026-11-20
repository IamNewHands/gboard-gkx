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
