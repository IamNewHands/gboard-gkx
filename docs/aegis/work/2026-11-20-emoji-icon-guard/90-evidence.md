# 证据

## 2026-11-20 源码阶段

- 目标症状：九键拼音页／符号页切换时，换行键上先出现原生笑脸（带圆圈），随后才被替换成「换行／重输／收起」文字。
- 根因依据（既有证据）：`docs/aegis/work/2026-11-18-toolbar-repair/90-evidence.md:57` 记录 `GKBImageViewWithBackground` 的 `layerClass` 为 `GKBImageLayer`、`setImage:` 转发 `self.layer`；`docs/aegis/work/2026-11-14-action-key/90-evidence.md:22` 记录该视图自有独立 image/highlightedImage 前景。原生每次 `updateView` 都会把笑脸重新写进前景图层，而 `GXKUpdateActionKey` 的清除发生在轮询／布局的下一拍。
- 修复：`static void gxk_key_updateView(id self, SEL _cmd)` 先调用 `gOrigKeyUpdateView`，再对已绑定的那一个表情键清 `image`／`highlightedImage`，清前把两张图存进 `gActionNormalImage`／`gActionHighlightedImage` 供 `GXKDetachActionKey` 还原。
- 刻意不做：不隐藏视图、不改 alpha、不碰 backgroundLayer／backgroundColor／cornerRadius；不清未绑定的键（`GXKUpdateActionKey` 的 `hasForeground` 要求新绑定必须有当前原生前景，先清会让新布局绑不上）。
- 方法签名（首版误判，真机闪退后已证伪）：首版按 `id` 接管并原样回传返回值，理由是「取不到类型编码串」。真机切键盘即闪退。
- 签名实证：解析 `Payload/Gboard.app/PlugIns/Gboard.appex/Gboard` 的 `__objc_classlist` → `class_ro_t` → `method_list_t`（entsize 24，sel/type 均为指针），得到 `GKBSoftKeyView` 的 `-updateView` 类型编码 `v16@0:8`，即 `void (^)(id, SEL)`；同表 `GKBImageViewWithBackground` 的 `-setImage:` 为 `v24@0:8@16`，说明解析路径正确。全包仅 `GKBSoftKeyView` 声明了 `updateView`。
- 崩溃机制：ARC 下 `id` 返回值的包装函数会对返回寄存器做 `objc_retainAutoreleasedReturnValue`；原方法返回 void 时该寄存器内容不确定，切键盘（首次布局调用 updateView）即崩。
- 回归：`python -B -m unittest <每个 tests/test_*.py>`，10 个文件全 OK，共 134 项；新增契约测试覆盖透传返回值、只处理绑定键、存档先于清除、不碰外观字段、幂等安装与两处安装点顺序。

## 2026-11-20 构建与验包

- CI run 44733139902（提交 c86e7cb）success，macos-15-intel，arm64 / iOS 12+ / QuartzCore / ldid；artifact libgkx.dylib 239184 bytes，SHA256 9caff9c2071eccf12b0c90b331f8387a4ac25762979975814875c46c0e1e2347。
- 出包：`tools/inject.py --ipa ../ipa/Gboard_2.3.19.ipa --dylib <CI dylib> --app-group group.zunbengege.top --dict dist/user_dictionary.db`，输出 `dist/gboard-ntr-1.0-unsigned.ipa` 35980293 bytes，SHA256 09c3976561e5435c1c4ae739842c1cce9e09cad871e824832a97b0702de053a8。
- 独立验包：ZIP CRC OK；条目 2050（原 3633，原包含大量目录条目）；新增 `Frameworks/libgkx.dylib` 与 `Frameworks/user_dictionary.db`；移除 3 个 `_CodeSignature/CodeResources`；变更仅 `gboard_framework`、主 `Gboard`、`Gboard.appex/Gboard`；其余 2045 个原生文件 SHA256 逐字节相同；包内 dylib SHA256 与 CI artifact 一致。
- 加载命令：主 exe ncmds=50 各 1 条 `@rpath/libgkx.dylib`、rpath `@executable_path/Frameworks`；appex ncmds=48、rpath `@executable_path/../../Frameworks`；框架 8 处 app group 已改写为 `group.zunbengege.top`。
- 未覆盖：本机无 iOS clang/SDK，未做本地编译；未在真机上安装。闪烁是否消失、切页与 9↔26 切换、滑行输入是否回归均需用户自签后验收。
