# 最新续跑状态

## 笑脸键写入守卫（2026-11-20；源码/回归完成，CI 与真机待办）

- 改动 2 文件：`dylib/gkx.m`（新增 `#pragma mark - 原生笑脸图标写入守卫` 段落 + 两处安装调用）、`tests/test_action_key.py`（新增 1 项契约测试）。
- 守卫实现要点：`static id (*gOrigKeyUpdateView)(id, SEL);` 先透传原实现并原样回传返回值；只对 `key == gEmojiSoftKeyView`、`icon == gActionNativeIcon`、`GXKModelHasNativeActions` 成立的那一个键生效；清空前先把图存档进 `gActionNormalImage`／`gActionHighlightedImage`，撤键仍可还原。
- 返回类型处理：原包内 `updateView` 的 ObjC 方法名表存在（`Payload/Gboard.app/PlugIns/Gboard.appex/Gboard` 里可检索到字面量），但类型编码串无法从 Mach-O 静态取出，故按 `id` 接管并原样回传；原方法若返回 void，调用方本就不读该寄存器。
- 安装时机：`gkx_init` 中在 `GXKApplyTelemetryBlockIfNeeded()` 之前挂一次（不影响 privacy 的 index 断言），`gkx_viewWillAppear` 中在 `GXKSymbolInstallHooks()` 之后补挂，幂等旗标 `gxk_icon_guard_hooked`。
- 验证：bundled Python 逐个文件跑 tests，10 个文件全 OK（test_action_key 26 项，总 134 项）；未编译、未出包。
- 待办：提交推送 → CI 编译 → 注入出包 → 真机验收闪烁是否消失。
