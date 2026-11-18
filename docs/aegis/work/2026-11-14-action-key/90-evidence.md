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

- [最终验证脚本](<<repo>/dist/verify-action-closeout-20261114.py>) 执行两套维护测试：20项[源码约束](<<repo>/tests/test_action_key.py>) + 6项[原包NIB断言](<<repo>/tests/test_native_resources.py>)，合计26项、0跳过，0.024s，OK，退出0。覆盖精确ID、九键优先、竞争布局拒绝、完整遍历、旧点击、原生外观/恢复、解绑后复选、空模型与新绑定当前前景。源码约束不是UIKit行为测试，固定SHA256原包模板不是新dylib效果证明。
- 对基线HEAD逐个函数体执行相等断言：`GXKEnsureUserDictionaryDeployed`、`GXKIsComposingActive`、`GXKPerformClearComposing` 未改；App Group未改。构建、注入、词库转换文件的基线diff为空。`git diff --check` 退出0。
- [gkx.m](<<repo>/dylib/gkx.m>) 最终575行，SHA256 `42af496fc61a4fbb4dac1525c91c1b14e10951592b39674abd402743aa695006`。真实UIKit/iOS编译、真机布局/触摸/主题、CPU/内存与VoiceOver未执行；用户可见验收 needs-verification，证据等级C（源码/离线）。
- 本地提交时尚未获GitHub推送/构建授权；后来已获指定提交到main的普通推送、查看CI和下载匹配libgkx授权，后续执行证据见下文。仍没有本次新dylib/IPA，旧构建文件不作为本次产物。维护测试可独立按头部命令运行；最终编排脚本是忽略目录内的验证辅助，不新增运行时依赖。

## 独立审查与收敛

只读 reviewer `680bae61-2bcf-458d-bb7e-11ef0d1803e6` 对542行冻结版给出3个 Important、无 Critical：9↔26竞争布局未拒绝；原生解绑刷新后未重新选键且字体owner可能为nil；非空仅layout模型被当成可操作内容。这些是源码反例，不声称已复现设备触发。

已在单一owner修正：记录唯一可见原生外层布局体（已证内层fixed布局不作peer），emoji必须属于它；解绑后重新验证控制器/root并完整复选；共享只读 `actionsArray`/NSArray/count>0 判定用于更新与点击，新绑定额外要求当前UIImage前景，禁用旧保存图授权新模型。补充5项源码约束。

对575行冻结版的限定复核确认3项均 closed-at-source，未识别新具体回归；reviewer独立运行20项源码约束，退出0，并执行限定diff检查，退出0。源码关闭置信B，不提升为运行时/真机验收。actions非空只证明非空动作集合，不证明协议动作语义或原生触摸转发。

## 复杂度与责任退役

- 源文件520→575行（+55）；最长static函数94→80行；两份维护测试193+176行。80行更新函数已检查，保留在唯一动作键owner内，不为行数创建无关框架或重复责任。函数长度统计曾误匹配forward declaration，已在验证辅助中固定为匹配含左花括号的定义并重跑；业务源码未因统计修正改变。
- 保存状态限当前绑定模型、两张原生前景图和重入控制；对应退役坐标猜键、全子视图隐藏/恢复、独立不透明键帽、跨布局移动旧按钮。原生能力保留，无历史模式缓存、主题自绘或新猜测兜底；复杂度闭合 within-budget。词库/组字/重输和打包边界由上述相等断言覆盖。

## 结构工具边界

已运行安装版 `aegis-workspace.py bundle --root <local>/gboard-gkx --work 2026-11-14-action-key`：退出2，`error: artifact file does not exist: <repo>\docs\aegis\work\2026-11-14-action-key\task-intent-draft.json`。随后 `check --root <local>/gboard-gkx`：退出1，要求完整adr/baseline/specs/plans目录和README/INDEX/BASELINE-GOVERNANCE文件。

实际本次只使用3个Markdown的薄工作记录，不是已初始化的完整Aegis工作区；完整glob复核没有新增副作用。不为通过通用结构模板而扩张本任务到无关基线/ADR/计划家族。工具结果明确不通过/不适配，不能标成成功；该检查只检查其模板结构，不是业务源码或真机正确性门禁。

## 已授权推送尝试与执行环境（2026-11-14，goal round 1）

- 已获授权：普通推送 `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669` 到 `https://github.com/IamNewHands/gboard-gkx.git` 的main，触发现有build-dylib、检查匹配SHA的CI并下载libgkx。无强推/Release/签名凭据读取授权。后续不重复索取相同授权。
- 默认Git执行 `git -c http.sslBackend=openssl push origin HEAD:refs/heads/main`：退出128，`warning: Ignoring unavailable SSL backend 'openssl'; using 'schannel' instead`、`schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)`；获一次操作权限的确切重试仍退出128，`error: failed to execute prompt script (exit code 1)`、`fatal: could not read Username for 'https://github.com': No such file or directory`。没有成功推送回执。
- 公共仓库分支工具返回 `Error: GitHub resource not found. Check owner/repo spelling and that the repository is public.`；不能据此判定仓库不存在。已安装gh执行分支查询退出1，`Get "https://api.github.com/repos/IamNewHands/gboard-gkx/branches/main": EOF`，没有远端SHA证据。
- 标准Git版本2.53.0.windows.1带OpenSSL3.5.5，非秘密配置显示credential.helper=manager。默认DSH niugit版本2.56.0.windows.4不支持指定OpenSSL。没有读取GCM密码、令牌或配置凭据值。
- 本次忽略目录内[守卫推送脚本](<<repo>/dist/publish-action-key-20261114.sh>) 固定标准Git路径、目标/HEAD检查、禁止交互，执行中退出128：`0 [main] sh (34428) C:\Program Files\Git\usr\bin\sh.exe: *** fatal error - couldn't create signal pipe, Win32 error 5`、`fatal: could not read Username for 'https://github.com': terminal prompts disabled`。工具同时给出 `EXECUTOR_UNAVAILABLE: the sandbox runtime failed before the command ran; this is not a user authorization denial. Restore the runtime or confinement provider; changing the DSH selector is not a repair. Do not bypass confinement.`。遵从retry:never，不重复该推送、不切换执行器绕过。
- 失败后只读本地Git回读退出0：HEAD `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669`，本地refs/remotes/origin/main `864f1e0d3968a38a419252febb2fcd3bbbc14fd8`；当时跟踪文件diff为空。该引用不是实时远端状态；后续仅检查点/本证据记录新增续跑信息，源码未变。

## 浏览器只读恢复尝试与剩余诊断

- web-access依赖检查未连接Chrome；browser_tabs返回无任务页。BrowserSkill start失败：`automatic daemon startup failed: cannot start an independent Windows daemon; the host may prohibit Job Object breakaway`，并明确建议持久受管任务 `bsk daemon start --foreground`；没有创建session，不存在需关闭的任务标签。
- 命令帮助证实foreground受支持。启动受管job `bash-7e9027db38b64719`，命令 `BSK_AUTO_START=0 bsk daemon start --foreground --quiet`；从独立调用执行 `BSK_AUTO_START=0 bsk status --json` 退出2，提示守护进程不存在。
- 已收集job结果：退出101，`initializing rolling file appender failed: InitError { context: "failed to create log file", source: Os { code: 5, kind: PermissionDenied, message: "拒绝访问。" } }`。任务已结束，无后台服务残留。具体日志文件目标未出现在错误中，不能臆断为既有目录权限损坏；不更改BSK_HOME、权限或绕过宿主限制。
- 此处为切换权限前的历史状态：当时仅本地源码/离线检查完成，远端/CI未核实。用户随后自行将本会话切换到完全权限并明确要求重新尝试；这项输入变化后按既有推送授权重试成功，证据见下文。失败的前台浏览器job已收集并结束，后续GitHub工作使用Git/gh，不需要浏览器或修改其配置。

## 完全权限下的已授权重试、编译与产物（2026-11-14）

- 新输入：用户表示已开启完整权限并要求重新尝试；当前runtime证实 danger-full-access、禁止审批升级请求。没有自行改变权限策略，也没有请求再次升级。更新的工作区只有两份续跑记录，业务源码/测试未变；20项源码约束+6项原包NIB断言重跑均通过、0跳过，退出0，`git diff --check` 退出0。
- 标准Git在该模式下先只读查询远端，得到基线SHA；随后普通推送精确对象 `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669:refs/heads/main`，退出0。再次实时 `ls-remote origin refs/heads/main` 得到 `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669`，退出0。没有执行守卫脚本的dirty-worktree推送或推送续跑记录，没有强推、Release或PR。
- 匹配的 [build-dylib run 43574354437](<https://github.com/IamNewHands/gboard-gkx/actions/runs/43574354437>) 为push事件，head_sha与上述提交相同，status=completed、conclusion=success；checkout、Build libgkx.dylib、ldid、上传artifact各步骤均success。已读取完整日志：macOS 15.8.2 / Xcode 16.4 (16F6) / iPhoneOS SDK 18.5，编译 arm64、最低iOS 12、ARC/O2/hidden；`otool -L` 安装名为 `@rpath/libgkx.dylib`。编译步骤没有报告警告；Actions依赖有punycode/url.parse弃用提示以及Node20 actions被强制用Node24运行的维护告警，不是编译失败。
- Artifact ID `14105651716`，name=libgkx，expired=false，workflow_run.id=`43574354437`、head_sha匹配；ZIP 15972字节、平台声明SHA256 `155647785809d3a67539ce1daf594e45f5e3ff8d63c1b47815dd8316cc39aa3d`。使用已安装gh下载指定artifact，不输出凭据值，没有配置更改。
- [下载核验辅助](<<repo>/dist/download-verify-libgkx-8fd0dfd.py>) 执行退出0：再次核对run/path/event/SHA及artifact关系、ZIP尺寸/SHA256、唯一成员libgkx.dylib和CRC；只写新专用目录、不覆盖旧产物、不执行目标二进制。核验 [libgkx.zip](<<repo>/dist/libgkx-8fd0dfd/libgkx.zip>) 摘要与平台一致；[libgkx.dylib](<<repo>/dist/libgkx-8fd0dfd/libgkx.dylib>) 78704字节，SHA256 `b5d455e2a0f5d72edd38892316f7d02b3db086194453bd179ea6b133a9adba26`。
- 本地产物Mach-O结构核验：MH_DYLIB、arm64、安装名 `@rpath/libgkx.dylib`、最低iOS `12.0.0`、SDK `18.5.0`，UIKit/Foundation/CoreGraphics/ObjC/System/CoreFoundation依赖；嵌入签名superblob的范围合法（offset 77232、1472字节、3 entries）。仅证明签名容器存在及边界，不验证签名可信或提取证书/entitlement；没有读取用户签名凭据。
- [产物核验回执](<<repo>/dist/libgkx-8fd0dfd/verification.json>) 保存上述谱系与摘要。推送、既有macOS构建检查、匹配dylib下载与核验均已在此记录；未做最终用户签名、未验证真机布局/触摸/主题/VoiceOver。

## 本地未签名测试包（2026-11-14，goal round 3）

- 用户在同一会话继续要求推进（“继续”），据此在本机执行既有注入流程生成测试包；不读取签名凭据、不发布Release、不改认证配置、不覆盖既有IPA文件。
- 输入核对（`sha256sum` 退出0）：原始包 `<local>/Gboard_2.3.19.ipa` = `c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731`；CI产物 `dist/libgkx-8fd0dfd/libgkx.dylib` = `b5d455e2a0f5d72edd38892316f7d02b3db086194453bd179ea6b133a9adba26`；词库 `dist/user_dictionary.db` 1688094字节。
- 执行 `tools/inject.py --ipa … --dylib … --dict … --app-group group.zunbengege.top --out dist/gboard-gkx-8fd0dfd-unsigned.ipa`，退出0：注入 `Payload/Gboard.app/PlugIns/Gboard.appex/Gboard`，`add=added ncmds=48 sizeofcmds=0x17f8 验证=OK`；dylib落点 `Payload/Gboard.app/Frameworks/libgkx.dylib`（rpath `@executable_path/../../Frameworks`）；词库写入Frameworks与appex两处；删除3个旧签名目录；app group改写 `gboard_framework` 8处 + dylib 1处。
- [新包](<<repo>/dist/gboard-gkx-8fd0dfd-unsigned.ipa>) 34.96 MB（36651622→新文件），SHA256 `0876416ed6e6ee425607ddfbbe9d6f03b1dddee0c7a84bf42cc64576544fc1db`。
- [打包核验辅助](<<repo>/dist/verify-ipa-8fd0dfd.py>) 执行退出0，断言全部通过：ZIP CRC完整、2051个成员无重复、无 `_CodeSignature`/`SC_Info` 残留；`libgkx.dylib` 字节SHA与CI产物一致、权限 `0755`；扩展可执行文件 `0755`；`LC_LOAD_DYLIB` 含 `@rpath/libgkx.dylib`；`gboard_framework` 含 `group.zunbengege.top\0` 且不含 `group.com.google.keyboard`/`group.com.google.common` 旧串。
- 该核验证明包结构、注入与App Group改写符合预期，不证明iOS签名可用、dylib加载成功或真机按键行为。用户可见验收仍为 needs-verification。

## 真机反馈：空闲态点「换行」仍进表情页（2026-11-14，goal round 4）

- 用户真机结论（唯一需求）：未开始输入时点「换行」，实际仍进入表情页面，只是外观显示为换行；有输入时「重输」已测正常，不需调整。据此把本轮范围限定为「空闲态点击必须真正插入换行」，不触碰组字检测、词库、几何与原生回车。
- 反汇编取证（复用自研ARM64反汇编器，按LC_FUNCTION_STARTS切边界）：`-[GKBSoftKeyView hitTest:withEvent:]`（vm `0x10027deb8`–`0x10027df3c`，SHA256 `53fbe4f4fc9f7c7f2c3676104ff0f94b11125f4a15b09d03eebbcb62699e43a6`）只有三段：`isHidden` 为真返回 nil、`_softKeyDef` 为 nil 返回 nil、否则 `CGRectContainsPoint(self.bounds, point)` 返回 self 或 nil；**不调用 super、不遍历 subviews**。因此旧实现 `[currentKey addSubview:btn]` 的透明按钮永远不参与命中，触摸落到原生 GKBSoftKeyView 本身并触发原生表情 action。这是「看起来是换行、实际进表情页」的直接机制，也是为什么换行文本 `@"\n"` 本身没有问题的原因。
- 派发链取证（同一二进制全量 `__objc_classlist` 612 类扫描）：`hitTest:withEvent:` 覆盖只存在于 GKBSoftKeyView / GKBHeaderLogoView / GKBCircleView / EMOPopupBubble；GKBKeyboardViewContainerView 与 GKBSoftKeyboardView / GKB9KeysSoftKeyboardView 均无覆盖，键盘子树走默认 UIKit 命中（最深子视图优先）。GKBSoftKeyView 方法表无 touches*，触摸沿响应链上浮到 GKBKeyboardViewContainerView 的 touchesBegan 再经 GKBTapTouchHandler 派发——正常键点击即此路径。
- 修复（CanonicalOwner 仍是 gkx.m 的目标键解析与覆盖层生命周期）：新增 `GXKActionHostForKey`，从 `key.superview` 上浮取第一个非 `GKBSoftKeyView` 的祖先作为宿主；覆盖按钮改为宿主的同级子视图，frame 用 `[currentKey convertRect:currentKey.bounds toView:host]` 每帧换算，`autoresizingMask` 改为 None，置顶改为宿主 `bringSubviewToFront:`；点击与每帧刷新都重新解析宿主，宿主缺失即解绑。不 swizzle touches*/hitTest、不隐藏原生子视图、不猜坐标、不写 softKeyDef、不动全局 touches 链。
- 契约同步：`tests/test_action_key.py` 的 `test_rebinding_creates_fresh_button_after_detaching` 由断言 `gActionKeyButton.superview != currentKey` 改为四条宿主语义断言（`!= host`、`GXKActionHostForKey(currentKey)`、不含 `[currentKey addSubview:btn]`、含 `convertRect:currentKey.bounds toView:host`），保留「按钮不再是 currentKey 子视图」的原意。
- 离线回归：`python tests/test_action_key.py` 20项 OK；`python tests/test_native_resources.py` 6项 OK；合计26项、0跳过、退出0；`git diff --check` 退出0；`gkx.m` 花括号 89/89 平衡、`GXKActionHostForKey` 唯一定义。证据等级仍为C（源码/离线）：UIKit 实际命中与真机按键行为未执行，Windows 无 clang 无法本地编译。
- 未执行：推送、CI 构建、IPA 打包、真机验收；本轮无 GitHub 推送授权，等待用户裁决。

## 推送、CI 与测试包（2026-11-14，goal round 4 续）

- 用户授权变化：明确「推送并出包，后续不要再问我，直接推送出包」。此前 10-intent.md 的「未授权推送」边界被用户新输入取代，本轮据此推送。
- 凭据路径：默认 `git -c http.sslBackend=openssl` 与 schannel 均失败（`Ignoring unavailable SSL backend 'openssl'`、`schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)`、`could not read Username for 'https://github.com'`）。改用 `git -c credential.helper='!gh auth git-credential'`：`ls-remote` 与 `push` 均退出0，未读取、未打印、未修改任何凭据值或配置。
- 推送回读：推送前远端 main `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669`；推送输出 `8fd0dfd..6ec8f92`；推送后实时 `ls-remote` 得 `6ec8f920a8834b1ce5fcd6f76e6ec6af19e5c43a`。普通快进推送，无强推、无 PR、无 Release。
- CI：[run 43593793791](<https://github.com/IamNewHands/gboard-gkx/actions/runs/43593793791>)，push，head_sha `6ec8f920…`，completed/success；步骤 Set up job / checkout / Show toolchain / Build libgkx.dylib / Sign with ldid / upload-artifact 全 success。日志含 `out/libgkx.dylib: Mach-O 64-bit dynamically linked shared library arm64` 与 `otool -L` 的 `@rpath/libgkx.dylib`、UIKit/Foundation/CoreGraphics/libobjc 依赖；编译段无业务 warning。
- 产物核验：`gh api .../artifacts` 得 artifact id `14113018514`、name `libgkx`、digest `sha256:88b01da72893002137a725df8ab05e4b1826d63cc3c1675b5636f55addd718e6`、16171 字节、expired=false；`gh run download` 得 78752 字节 dylib，SHA256 `c4b4e4d5487c35a6a7fe4c5922edc3234e6cf897ce6a5bf759fee05dd8ec9742`，`strings` 含 `_GXKActionHostForKey`、`convertRect:toView:`、`insertText:`、`key_pos_9keys_emoji`，Mach-O filetype=6(MH_DYLIB)、cputype arm64、ncmds=20。
- 打包：`tools/inject.py --ipa <local>/Gboard_2.3.19.ipa --dylib dist/libgkx-6ec8f92/libgkx.dylib --dict dist/user_dictionary.db --app-group group.zunbengege.top --out dist/gboard-gkx-6ec8f92-unsigned.ipa` 退出0；注入 `Payload/Gboard.app/PlugIns/Gboard.appex/Gboard`（add=added ncmds=48 sizeofcmds=0x17f8 验证=OK），rpath `@executable_path/../../Frameworks`，删除3个旧签名目录，app group 改写 gboard_framework 8 处 + dylib 1 处。
- 独立复核（未用打包脚本自述，重新读 ZIP 字节）：CRC `testzip()` 返回 None；2051 成员、0 重复；无 `_CodeSignature`/`SC_Info`；包内 dylib 字节 SHA256 与 CI 产物完全一致、mode 0755；appex 可执行 mode 0755；appex 48 条 load command 中第 47 条为 `LC_LOAD_DYLIB @rpath/libgkx.dylib`、第 43 条为 `LC_RPATH @executable_path/../../Frameworks`；`gboard_framework` 含 `group.zunbengege.top\0` 且不含 `group.com.google.keyboard`/`group.com.google.common`；dylib 内含新 group；`user_dictionary.db` 存在。输入 IPA SHA256 `c0117301…`、词库 1688094 字节，与历史记录一致。
- 仍未验证：iOS 签名可用性、真机 dylib 加载、真实键盘布局/触摸/主题、VoiceOver、CPU/内存。证据等级C，用户可见验收 needs-verification。
