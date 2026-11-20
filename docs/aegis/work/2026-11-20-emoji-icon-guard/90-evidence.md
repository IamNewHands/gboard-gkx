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

## 2026-11-20 切页仍闪一帧（二次修复）

- 现场：装 11df7f9f 包后不再闪退，但九键下反复点「拼音」↔「符号」分页时，换行键上仍闪一下带圆圈的笑脸。
- 根因：首版守卫的判据挂在对象同一性上（`key != gEmojiSoftKeyView`、`icon != gActionNativeIcon`），且入口先看 `!gActionKeyButton`。切页这一拍原生会对旧布局的 `GKBSoftKeyView` 调 `updateView`：此时 `GXKDetachActionKey` 已把按钮置空、原生又重建了 icon，两条判据都放行 → 笑脸写进图层并提交一帧，下一拍轮询才清。
- 修复：新增归属引用 `static __weak UIView *gGuardKey`，绑定建立时赋值（gkx.m:1233），撤键时**先于**还原用的原生 `updateView` 清空（gkx.m:589 附近）。守卫判据改为 `key == gGuardKey` + `restorationIdentifier == GXKEmojiKeyID` + `GXKNineKeyBodyForKey(key, gCurrentVC.view)` + 同 window + `GXKModelHasNativeActions`，图标每次 `GXKNativeIconForKey(key)` 现取，不再与按钮或图标对象同一性比较。
- 撤键顺序的理由：撤键里那次 `updateView` 是「还原」，若归属仍指向该键，守卫会把原生刚写回的图再搬走一次；本地存档为空时键会停在无前景状态。
- 回归：tests 10 个文件逐个跑全 OK（test_action_key 26 项，新增/改写 4 条断言：判据不得引用 `gEmojiSoftKeyView`／`gActionNativeIcon`／`!gActionKeyButton`、图标须先于清空现取、detach 内 `gGuardKey = nil` 先于原生 updateView）。
- 未覆盖：仍未真机验收；本机无 iOS clang/SDK。

## 2026-11-20 发布补做（Release 资产落后）

- 现场：本地 `dist/gboard-ntr-1.0-unsigned.ipa` 三次重打、CI 三次出新 dylib，但 `gh release view v1.0` 的资产一直是 35980290 bytes / SHA `11df7f9f…`，正文也写着旧哈希；用户第二次问「为什么又没发布 release」。
- 根因：流程缺步，不是操作失误。README 第 3 步止于「本地注入打包」，agent.md 速查止于「校验产物」，两处都没有「上传 Release」。
- 补做：新增 `tools/publish_release.py`（`gh release upload --clobber` → 置草稿再发布重置 `published_at` → 读回校验 size → 打印固定下载地址与远端 digest）；README 增「4. 发布到 GitHub Release」，agent.md 速查增第 6 步并新增避坑 11。
- 结果：`v1.0` 资产 35980398 bytes，远端 digest `sha256:0c330dc44d51cdc89e5185b720839ece35f63fd9b7722da19c1c61a5012cd0ee`，`published_at=2026-11-20T12:55:56Z`（原 11:04:15Z），正文 SHA-256 已同步。
- 注意：`--clobber` 会把旧资产先删再传，网络中断会留下空资产列表（本次即遇到一次，重跑即恢复）；`publish_release.py` 因此带了读回校验。
