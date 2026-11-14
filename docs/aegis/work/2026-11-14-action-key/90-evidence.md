# 证据与范围

## 已观察的当前源码机制

基线 HEAD 864f1e0d3968a38a419252febb2fcd3bbbc14fd8，dylib/gkx.m 原始520行：

- 253–281：只匹配含9Key与SoftKeyboard的可见容器。123/符号所属类仍需原始资源证据。
- 303–345：读取 key_pos_9keys_emoji/return 后，精确命中失败仍执行右列最高y坐标兜底；return缺失时 returnKeyY=99999.0，无法保证不选回车。
- 352–372：目标按UIView指针切换；没有证明复用视图仍是emoji。
- 244–251、400–405：无条件显示全部旧子视图，隐藏当前全部子视图；原生背景和原有隐藏状态丢失。
- 386–388、407–430：独立字体、圆角与深浅色不透明背景；不复用原生键帽。
- 209–239：点击未重验证布局或键身份；NSString换行转义需要字节测量。

这些是静态机制观察/近因候选，不是已复现的真机根因。上一轮5c088fe增加精确ID但未退役坐标猜键，不能证明“彻底杜绝”。

## 原生证据输入

原始 <local>/Gboard_2.3.19.ipa：35889409字节；SHA256 c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731。

- 原包资源：九键、123、符号根类均为 `GKB9KeysSoftKeyboardView`；表情/回车分别是 `key_pos_9keys_emoji` / `key_pos_9keys_return`，属于不同的 `GKBSoftKeyView` 对象。26键/26符号根为 `GKBZhQwertySoftKeyboardView`。因此否定“123/符号没有9Key类”的初始假设，不能据此声称外层 allSoftKeys 一定失效。
- 原包继承：`GKB9KeysSoftKeyboardView` → `GKBZhQwertySoftKeyboardView` → `GKBSoftKeyboardView`；九键判断必须优先。26键内部的 fixed-layout 子节点不能被当成独立竞争布局体。
- 原生键帽：`GKBImageViewWithBackground` 是 UIView，具有独立 image / highlightedImage 前景及 backgroundLayer。仅清除前景不会主动写背景层；不能隐藏这个节点。字体模板是 Roboto-Regular 16pt，实际主题前景色读取 native property，不固定明暗主题配色。
- 原生清空：`dist/inspect-layout-20261114-007-code.txt:371-396` 证明 `clearLabelAndIcons` 创建仅复制 layout 的新非空 GKBSoftKeyDef；本次不调用该方法。非空模型不等于当前原生动作/内容完整。模型属性见 `dist/inspect-layout-20261114-006-model.txt:32-42`；原生 updateView 在 `007-code.txt:1153-1166` 读取 actionsArray.count。
- 原生 updateView 会重画 normal image、应用 viewAttributes 并 setHidden:NO；highlightedImage 同等恢复证据不足。保存两张前景 UIImage 仅限相同 emoji/model/icon 的恢复，不能回写旧图到新复用模型。

上述是离线资源/元数据/限定指令窗口观察，不是运行时布局、触摸或主题效果证明。REA CLI已安装6.5.0，MCP未注册；只使用已有离线接口/标准Python，不安装或修复配置。不将普通Python分析命名为REA Evidence。

## 字节核对（已执行）

命令：bundled Python 执行 dist/probe-action-source-20261114.py，退出0。dylib/gkx.m SHA256 e6a0c4affa153f218144d07d951a16af17fb4442a8e458f80af342b8e7a4ba0e；换行字面量实际十六进制5c6e（单个反斜线+n），正确。构建脚本26–38行每行仅一个续行反斜线；inject.py AST中空字节字面量为00。工具预览的双反斜线是展示转义，不是业务缺陷，不修改这些正确代码。

## 最终离线检查（2026-11-14）

命令（仓库根目录；使用bundled Python）：

```bash
~/.dsh/dsh-runtimes/dsh-next-primary-runtime/dependencies/python/python.exe dist/verify-action-closeout-20261114.py
```

- [最终验证脚本](<repo>/dist/verify-action-closeout-20261114.py>) 执行两套维护测试：20项[源码约束](<repo>/tests/test_action_key.py>) + 6项[原包NIB断言](<repo>/tests/test_native_resources.py>)，合计26项、0跳过，0.024s，OK，退出0。覆盖精确ID、九键优先、竞争布局拒绝、完整遍历、旧点击、原生外观/恢复、解绑后复选、空模型与新绑定当前前景。源码约束不是UIKit行为测试，固定SHA256原包模板不是新dylib效果证明。
- 对基线HEAD逐个函数体执行相等断言：`GXKEnsureUserDictionaryDeployed`、`GXKIsComposingActive`、`GXKPerformClearComposing` 未改；App Group未改。构建、注入、词库转换文件的基线diff为空。`git diff --check` 退出0。
- [gkx.m](<repo>/dylib/gkx.m>) 最终575行，SHA256 `42af496fc61a4fbb4dac1525c91c1b14e10951592b39674abd402743aa695006`。真实UIKit/iOS编译、真机布局/触摸/主题、CPU/内存与VoiceOver未执行；用户可见验收 needs-verification，证据等级C（源码/离线）。
- GitHub上传/构建/发布未授权、未执行；没有新dylib/IPA，旧构建文件不作为本次产物。维护测试可独立按其头部命令运行；最终编排脚本是忽略目录内的本次验证辅助，不新增运行时依赖。

## 独立审查与收敛

只读 reviewer `680bae61-2bcf-458d-bb7e-11ef0d1803e6` 对542行冻结版给出3个 Important、无 Critical：9↔26竞争布局未拒绝；原生解绑刷新后未重新选键且字体owner可能为nil；非空仅layout模型被当成可操作内容。这些是源码反例，不声称已复现设备触发。

已在单一owner修正：记录唯一可见原生外层布局体（已证内层fixed布局不作peer），emoji必须属于它；解绑后重新验证控制器/root并完整复选；共享只读 `actionsArray`/NSArray/count>0 判定用于更新与点击，新绑定额外要求当前UIImage前景，禁用旧保存图授权新模型。补充5项源码约束。

对575行冻结版的限定复核确认3项均 closed-at-source，未识别新具体回归；reviewer独立运行20项源码约束，退出0，并执行限定diff检查，退出0。源码关闭置信B，不提升为运行时/真机验收。actions非空只证明非空动作集合，不证明协议动作语义或原生触摸转发。

## 复杂度与责任退役

- 源文件520→575行（+55）；最长static函数94→80行；两份维护测试193+176行。80行更新函数已检查，保留在唯一动作键owner内，不为行数创建无关框架或重复责任。函数长度统计曾误匹配forward declaration，已在验证辅助中固定为匹配含左花括号的定义并重跑；业务源码未因统计修正改变。
- 保存状态限当前绑定模型、两张原生前景图和重入控制；对应退役坐标猜键、全子视图隐藏/恢复、独立不透明键帽、跨布局移动旧按钮。原生能力保留，无历史模式缓存、主题自绘或新猜测兜底；复杂度闭合 within-budget。词库/组字/重输和打包边界由上述相等断言覆盖。

## 结构工具边界

已运行安装版 `aegis-workspace.py bundle --root <repo> --work 2026-11-14-action-key`：退出2，`error: artifact file does not exist: <repo>\docs\aegis\work\2026-11-14-action-key\task-intent-draft.json`。随后 `check --root <repo>`：退出1，要求完整adr/baseline/specs/plans目录和README/INDEX/BASELINE-GOVERNANCE文件。

实际本次只使用3个Markdown的薄工作记录，不是已初始化的完整Aegis工作区；完整glob复核没有新增副作用。不为通过通用结构模板而扩张本任务到无关基线/ADR/计划家族。工具结果明确不通过/不适配，不能标成成功；该检查只检查其模板结构，不是业务源码或真机正确性门禁。
