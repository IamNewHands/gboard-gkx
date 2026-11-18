# 修复检查点

## 当前状态（2026-11-14，已推送、CI 编译并出未签名测试包；真机复验待做）

- 任务基线：main，HEAD `864f1e0d3968a38a419252febb2fcd3bbbc14fd8`；开始时跟踪文件干净。源码、测试及动作键文档的 mixed 提交 `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669` 已普通推送到 `IamNewHands/gboard-gkx/main`；标准Git的实时 `ls-remote` 回读证实远端SHA相同，没有强推。
- 已实施：直接可见 `restorationIdentifier` + 九键优先祖先分类；唯一可见外层布局体，不完整/竞争布局拒绝替换。退役坐标猜键、外层 `allSoftKeys` 依赖、全子视图隐藏/恢复和独立键帽配色；只清除已证原生前景，不改键帽背景层。
- 独立审查发现的3个源码反例均已修正并复核关闭：9↔26竞争布局；原生解绑刷新后控制器/root/目标重选及字体空owner；非空但无actions模型。更新与点击共享只读actions判定，新绑定必须有当前前景，保存图不能授权新模型。未识别新的具体源码回归。
- 最终检查：20项源码约束 + 6项固定SHA256原包NIB断言，26项通过、0跳过，退出0；`git diff --check` 通过。另执行断言证明词库部署、组字检测、重输、App Group、构建与注入文件未改。
- [gkx.m](<<repo>/dylib/gkx.m>) 520→575行，SHA256 `42af496fc61a4fbb4dac1525c91c1b14e10951592b39674abd402743aa695006`；最长static函数94→80行。新增状态限当前绑定模型、两张前景图和重入控制；无新框架、历史布局缓存或猜键兜底，复杂度收敛 within-budget。

## 完成边界与下一步

本地实施、离线检查和真实macOS编译已完成；用户可见需求验收仍是 needs-verification。编译成功、源码断言和原包静态资源不等于真实键盘布局、视觉或触摸效果。

已授权并完成：普通推送提交 `8fd0dfd0b1a04ab912a2c60a7407a9b9f7acf669` 到 `IamNewHands/gboard-gkx/main`、查看现有build-dylib及下载匹配libgkx。此前执行器/认证失败是历史记录；用户自行改为完全权限并明确要求重试后，标准Git只读远端检查、精确SHA普通推送及再次远端回读均退出0。没有修改认证配置、强推或更换提交。

[build-dylib run 43574354437](<https://github.com/IamNewHands/gboard-gkx/actions/runs/43574354437>) success，head_sha匹配；Xcode 16.4/iPhoneOS SDK 18.5编译arm64、最低iOS 12，ldid和上传artifact步骤均success。已读完整日志，未见业务编译警告；Actions依赖弃用维护告警记于证据。

已下载并核验 [libgkx.dylib](<<repo>/dist/libgkx-8fd0dfd/libgkx.dylib>)（78704字节，SHA256 `b5d455e2a0f5d72edd38892316f7d02b3db086194453bd179ea6b133a9adba26`）及 [libgkx.zip](<<repo>/dist/libgkx-8fd0dfd/libgkx.zip>)（平台ZIP摘要、CRC和唯一成员均通过）。[回执](<<repo>/dist/libgkx-8fd0dfd/verification.json>)记录commit/run/artifact谱系；Mach-O确认arm64/MH_DYLIB、安装名@rpath/libgkx.dylib、最低iOS12、依赖及签名容器边界。未验证最终用户签名可信或真机行为。

唯一下一步：把新测试包 [gboard-gkx-8fd0dfd-unsigned.ipa](<<repo>/dist/gboard-gkx-8fd0dfd-unsigned.ipa>)（SHA256 `0876416ed6e6ee425607ddfbbe9d6f03b1dddee0c7a84bf42cc64576544fc1db`）用 LCSign 自签安装后做真机验收；不读取签名凭据、不发布Release。真机仍需循环切换九键→123→符号→26键→九键100次，检查emoji位置换行、原生回车、组字重输、切换中旧点击、明暗主题及收起/重开；这是未执行的验收方案。

## 约束与未完成

- 原始IPA本轮仍只读，不执行target，不读取签名或描述文件凭据；测试包已生成，未做最终用户签名。
- 保留原生回车、26键、词库、Mozc和已有「重输」能力；不添加全局触摸Hook，不改根视图/键盘高度、背景层或约束。
- 远端编译与产物下载已核实；真机布局/按键/主题/VoiceOver与性能仍未验证，goal保持active。
- 两份续跑记录目前为本地process-only修改；没有创建第二个提交或把续跑记录推送。守护进程job失败结果已收集并结束；后续Git/gh成功，不再追查与本任务无关的浏览器配置或旧测试目录权限。薄记录结构工具非通过结果见[证据](<<repo>/docs/aegis/work/2026-11-14-action-key/90-evidence.md>)。

## 真机反馈后的第二轮修复（2026-11-14）

- 真机反馈：空闲态点「换行」仍进入表情页；有输入时「重输」正常，不动。
- 根因（反汇编确证）：`-[GKBSoftKeyView hitTest:withEvent:]` 只判自身 bounds、不返回子视图，旧实现把透明按钮加成 key 的子视图，因此永不参与命中，触摸落到原生表情键。
- 修复：按钮改挂到键的宿主祖先（`GXKActionHostForKey`），frame 每帧按 `convertRect:toView:` 换算；点击与刷新均重解析宿主。不 swizzle、不隐藏原生子视图、不猜坐标、不改全局 touches 链。
- 离线回归：20 项源码约束 + 6 项原包 NIB 断言，26 项通过、0 跳过、退出 0；`git diff --check` 干净。
- 本地提交 `dd8ed95`；未推送、未 CI 构建、未打包、未真机复验。下一步待用户裁决是否推送（推送即出包）。

## 推送、编译与测试包（2026-11-14，goal round 4）

- 用户新输入：明确「推送并出包，后续不要再问我，直接推送出包」。据此本轮完成推送、CI 编译与本地打包，不再逐次确认。
- 推送：`git -c credential.helper='!gh auth git-credential' push origin HEAD:refs/heads/main` 退出 0，`8fd0dfd..6ec8f92`；实时 `ls-remote origin refs/heads/main` 回读 `6ec8f920a8834b1ce5fcd6f76e6ec6af19e5c43a`，普通推送、无强推。默认 schannel 凭据不可用（`SEC_E_NO_CREDENTIALS`），改用已登录 gh 的 credential helper，未读取或改动任何凭据值。
- CI：[run 43593793791](<https://github.com/IamNewHands/gboard-gkx/actions/runs/43593793791>) push 事件、head_sha 匹配、conclusion success；checkout / Build / ldid / upload-artifact 全 success。日志确认 Mach-O arm64 dylib、install_name `@rpath/libgkx.dylib`、依赖 UIKit/Foundation/CoreGraphics/objc，编译步骤无业务警告。
- 产物：artifact `libgkx` id `14113018514`，平台 digest `sha256:88b01da7…`；下载后 [libgkx.dylib](<<repo>/dist/libgkx-6ec8f92/libgkx.dylib>) 78752 字节、SHA256 `c4b4e4d5487c35a6a7fe4c5922edc3234e6cf897ce6a5bf759fee05dd8ec9742`，`MH_DYLIB`、arm64、ncmds 20，含 `_GXKActionHostForKey` 与 `convertRect:toView:` 符号，证明新代码确实进入二进制。
- 测试包：[gboard-gkx-6ec8f92-unsigned.ipa](<<repo>/dist/gboard-gkx-6ec8f92-unsigned.ipa>) 36654932 字节、SHA256 `a76f53c774382c79f4c0943be0fea47012c7c9a11089bc3928ffd6a162ba176d`。结构核验全部通过：ZIP CRC 完整、2051 成员无重复、无 `_CodeSignature`/`SC_Info` 残留；dylib 字节与 CI 产物一致且权限 0755；appex 可执行 0755；appex `LC_LOAD_DYLIB` 含 `@rpath/libgkx.dylib` 且 `LC_RPATH @executable_path/../../Frameworks`；`gboard_framework` 与 dylib 均改写为 `group.zunbengege.top`、旧 Google group 串为 0；`user_dictionary.db` 已内置。回执 [verification.json](<<repo>/dist/libgkx-6ec8f92/verification.json>)。
- 未验证：iOS 签名可用性、dylib 真机加载、真实键盘布局/触摸/主题、VoiceOver、性能。用户可见验收仍为 needs-verification。
- 唯一下一步：用 LCSign 自签安装新测试包，先测「未输入时点换行是否真正换行」，再回归「有输入时重输」与九键→123→符号→26键循环切换。
