# 证据

## 2026-11-20 源码阶段

- 目标症状：九键拼音页／符号页切换时，换行键上先出现原生笑脸（带圆圈），随后才被替换成「换行／重输／收起」文字。
- 根因依据（既有证据）：`docs/aegis/work/2026-11-18-toolbar-repair/90-evidence.md:57` 记录 `GKBImageViewWithBackground` 的 `layerClass` 为 `GKBImageLayer`、`setImage:` 转发 `self.layer`；`docs/aegis/work/2026-11-14-action-key/90-evidence.md:22` 记录该视图自有独立 image/highlightedImage 前景。因此原生每次 `updateView` 都会把笑脸重新写进前景图层，而 `GXKUpdateActionKey` 的清除发生在轮询／布局的下一拍。
- 修复：`static id gxk_key_updateView(id self, SEL _cmd)` 先调用 `gOrigKeyUpdateView`，再对已绑定的那一个表情键清 `image`／`highlightedImage`，清前把两张图存进 `gActionNormalImage`／`gActionHighlightedImage` 供 `GXKDetachActionKey` 还原。
- 刻意不做：不隐藏视图、不改 alpha、不碰 backgroundLayer／backgroundColor／cornerRadius；不清未绑定的键（`GXKUpdateActionKey` 的 `hasForeground` 要求新绑定必须有当前原生前景，先清会让新布局绑不上）。
- 方法签名限制：原包内没有 `GKBSoftKeyView` 头文件转储，Mach-O 方法名表能检索到 `updateView` 字面量但取不到类型编码串，故按 `id` 接管并原样回传；这是可查证据下的最保守选择。
- 执行：`python -B -m unittest <每个 tests/test_*.py>`，10 个文件全 OK（134 项）；新增契约测试覆盖透传返回值、只处理绑定键、存档先于清除、不碰外观字段、幂等安装与两处安装点顺序。
- 未覆盖：本机无 iOS clang/SDK，未编译；未注入、未真机；闪烁是否消失、切页与 9↔26 切换是否回归均需真机验收。
