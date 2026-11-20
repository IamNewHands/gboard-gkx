# 已实测证据与未覆盖边界

## 2026-11-19 顶条 22pt 行锚点修复（源码/编译/独立验包通过，真机待验）

- 修复源 d0398c00e749f77205e484f988fb7c9901cc586b 已推送 main（parent 8954dfe）。本地 139 项 python -m unittest discover -s tests 全绿（Ran 139 tests / OK），git 工作区仅预存 ?? CON。git push 报 schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)，改用 REST API（POST git/blobs → git/trees base_tree=8954dfe tree → git/commits → PATCH git/refs/heads/main）完成推送；--input 必须走文件，内联 base64 报 FileNotFoundError: [WinError 206]。
- log5.txt 28 样本证据链：全部 lastDecision=scan-failed；t=2.286 起 scanGate=no-measurable-logo（23/28），t=0/2.097/9.885 为 band-unavailable + bandGate=band-width（bandCandidateRoot={{56,26},{0,28}}、spaceBandRoot={{56,26},{346,28}}、rightBound=GKBCandidatesCollectionView root={{56,26},{301,44}}）。顶条 G 的 drawnRoot={{17,24},{22,22}} 但 visibleRoot={{17,24},{22,2}}（祖先 CALayer {{0,0},{402,26}} masks=1），visibleIconSized=0 → imageGate=visible-icon-size。九键候选行 logoCandidate[2] frame {{0,0},{56,44}} 在 t=2.286–2.9 变 {{0,0},{0,44}}，t=9.885 恢复 measured=1 picked={{17,0},{22,20}}。
- 修复语义：ImageRect 的 IconSized 失败后取未裁切 drawn 矩形（gate drawn-icon-size）而非放宽容差；Band 用 carrierIsRow（carrier 宽 ≥ row 宽-8pt）跳过全宽 logo 容器，并把 barHeight 夹到 row 高度、下限 18pt；Scan 变候选循环（Band 失败 removeObjectAtIndex:bestIndex 重试）；SyncToolbarGeometry 把 centerY 夹进 slot。8..64pt、200pt、原生内容判空、九键/独立26键门控全部未放宽。
- CI https://github.com/IamNewHands/gboard-gkx/actions/runs/44442047216 success；artifact 14491073381（libgkx，77614 bytes，archive SHA256 4cb2b3164034f62480b6e31da9d149c47202a15a5ec5380c8c1a9d8554ced250），下载 dylib 232048 bytes、SHA256 030b928dcdc46162c23b9b7b29549166a32c08e577087c28a49df6f4c6585764，arm64 magic 0xfeedfacf。
- 产物 dist/gboard-gkx-d0398c0-toolbar-space-repair-unsigned.ipa 35974329 bytes / SHA256 018ccd07e43c622d8c54d4083599217d020d6b5075c501229c6c63771cbfa4ac；dist/gboard-gkx-d0398c0-toolbar-space-repair-verification.json 为 PASS。dist/verify-toolbar-space-repair.py preflight 与 final 均 exit0；2050 条目、移除 3 个旧 CodeResources、8 group 槽 = group.zunbengege.top、2045 原生资源字节/权限不变、仅 gboard_framework 176 / 主 exe 28 / appex 27 bytes 差异、arm64 段/section/linkedit、RPATH、755-644 通过。dylib strings 含 drawn-icon-size、band-row-too-short、scan-success。
- 未覆盖：iPhone17Pro/iOS27 自签后的 UIKit 真实显示、G 与文字对齐、点击、9↔26 切换、三态与空剪贴板失败提示；Python 契约与几何回放不替代 UIKit。本机无 iOS SDK/clang，只能靠 CI 编译。诊断仍默认关闭并临时保留，真机验收后退役。

## 2026-11-18 log4 条带越行修复（源码/编译/独立验包通过，真机待验）

- 日志：<local>/log4.txt 共43样本，18次有可靠G却band-width、25次no-measurable-logo。lower可见G=(17,26,22,20)、row=(0,26,402,44)；旧28pt居中hit band=(43,22,359,28)与upper完整carrier=(0,0,402,26)相交，width归零。
- 原生只读正证据：原包<local>/Gboard_2.3.19.ipa SHA256 c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731；appex member SHA256711bc3dbeaec7cce6551d48286a7e5322b460e78aaaafa580e2ccd7fafb86566、cryptid0、612classes。GKBHeaderLogoView classVM0x10149e6b8继承GKBSoftKeyView0x10149ed98，SoftKey通过dyld bind继承UIView。Logo hitTest VM[0x1002680c8,0x100268228) bodySHA256cd4b72f6bdab48d553bec0461323487a6a76149e88675604042c146d2d07e166；询问hostView.subviews.firstObject，命中GKBCircleView返回它，否则objc_msgSendSuper2。父SoftKey hitTest[0x10027deb8,0x10027df3c)在!isHidden&&_softKeyDef!=nil&&CGRectContainsPoint(bounds,point)时返回self。Circle hitTest[0x100292710,0x100292794)动画期间可命中expandedAnimationFrame。三完整函数在原包与3574c24包逐字节相同；appex29/framework28个category完整读取未见相关方法声明，不证明动态替换不存在。IDA disconnected，未重连/安装/联网。
- 最小修复：同一Band把自有至少28pt的点击区域留在row/root内并同时避开selected Logo完整carrier；glyph同次成功测量单独发布，按钮title/divider对齐该center，字体不自动缩小，实际titleRect完整包含与font.lineHeight/文本高宽门控。原例几何变为(56,26,346,28)，文字center仍36而不是hitcenter40；346pt只证明几何参数，不保证UIKit显示。
- 实测：基线130项/0.067s/OK；终验139项/0.041s/OK、git diff --check exit0，命令为bundled Python -m unittest discover -s tests && git diff --check。独立源码复核覆盖最终rowContains与诊断順序，无剩余Critical/Important；原数值回放遗漏rowContains的Minor已补合法非零bounds/左右越界/NaN/±Inf拒绝并独立运行8项exit0。诊断unclampedTop在夹限前记录，未改报告字段。
- 未覆盖：UIKit实际CJK/font/titleRect（回放19.2pt只是参数非原生测量）、点击/z-order/softKeyDef、Circle动画expandedAnimationFrame、动态IMP、三态与9↔26；本机无iOS编译器/SDK；本轮CI编译与新IPA已完成，但不能证明UIKit/自签/真机行为。文字高>20pt在原例不能完整容纳时安全不显示；不以缩字/溢出恢复。不称真机已修好，默认关闭的诊断保留至验收。每格69.2pt，currentTitle的「剪贴板空」等长失败提示可能超宽而整条安全隐藏，须真机检查提示与恢复。
- 本轮编译：ab5fafd已推送；run44299818931的macos-15在15m1s后未分配runner，steps=[]，原文The job was not acquired by Runner of type hosted even after multiple attempts，arm64容量提示。官方https://github.com/actions/runner-images#available-images明确macos-15为arm64、macos-15-intel为x64；仅改运行器，ccdb888已推送，dylib/tools/tests相对ab5fafd无diff、139项/0.073s/OK。run44302485661 success，49s；Xcode16.4/iOS SDK18.5、-arch arm64、iOS12+、QuartzCore链接与ldid成功，编译无warning/error。Node20→24及punycode弃用警告不影响该产物。
- 本轮打包：artifact14427380754 libgkx，archive77417bytes/digest047dc32d0b9f39bb07f7c889d3f67edeaf6937b976851bedbfc02dda2d481917；唯一dylib SHA256c04fe0c7982505434a0bba803b53c0a395875216408ccdeb0227f511162e3aa0。复用dist/package-toolbar-space-repair.sh，preflight/inject/final单次exit0；同一ci_identity两阶段实时GET绑定精确SHA/run/artifact/workflow/digest/success；CRC、arm64、offsets、RPATH、755/644、8group槽、2045资源不变通过。最终dist/gboard-gkx-ccdb888-toolbar-space-repair-unsigned.ipa 35974157bytes/34.31MiB，SHA256d5e74a1ef60987614848766c6191b6d395a178f86ba3aa929cce2bce9fe8548a；回执dist/gboard-gkx-ccdb888-toolbar-space-repair-verification.json PASS，独立最终验包exit0/stderr为空；重新执行configure/ci_identity/original_inputs/artifact_bytes/verify_package、计算哈希并核对实物/回执一致。未重打包或调用final写第二份回执；这是独立执行同一已审验包器，不是第二套解析器。
- 独立打包链复核：23项测试/4.561s/exit0，覆盖正常和反例，历史cb5c13e包仅验证测试契约；不把它当本轮产物。原包/旧包留本地，未上传原IPA/发布Release。
- 结构验证：helper bundle exit2 error: artifact file does not exist: <repo>\docs\aegis\work\2026-11-18-toolbar-repair\task-intent-draft.json；check exit1缺docs/aegis/adr、baseline、specs、plans及README.md、INDEX.md、BASELINE-GOVERNANCE.md，为既有轻量Markdown工作区缺口，不扩大任务初始化治理结构，不影响源码测试或提供验收证明。

- 收口：需求/架构边界aligned，实际产品结果needs-verification/可信度C；旧共中心可越行与自动缩字路径已被替换，无新fallback/nativehook。复杂度：gkx.m现2707行既有压力，本轮仅现有按钮layout的local-fix-without-new-responsibility和24行局部同步接线；Band仍唯一测量owner，visibility owner未改。新增94行几何回放不引入路由/通用框架，未声称整体结构改善；较大源文件的整体拆分不属于本轮。

## 2026-11-18 log3 空位修复交付（源码/编译/独立验包通过，真机待验收）

- 修复源3574c24368a9a48df1ac6994bd463d6c6df258b5已推送main；fresh130项Python源码契约Ran130tests in0.039s/OK、git diff --check exit0，生产源码相对该CI提交无diff。独立源码复核无剩余Critical/Important；Python契约与几何回放不替代UIKit。
- Actions44291336372 success，https://github.com/IamNewHands/gboard-gkx/actions/runs/44291336372；精确head_sha与修复源相同，workflow .github/workflows/build-dylib.yml，macos-15-arm64/iOS12+ clang、QuartzCore、ldid与上传成功。编译无warning/error，上传器Node20→24/punycode/url.parse弃用警告不影响此次产物；未扩大CI变更范围。
- 父审后23项独立验包反例Ran23tests in6.210s/OK，130项源码契约Ran130tests in0.036s/OK；Windows原始ZIP双header的反斜杠与NUL反例验证orig_filename入口拒绝归一化/截断，没有放宽路径规则。preflight/注入/final单次执行全部exit0；两阶段同一ci_identity实时GET绑定精确SHA/run/artifact/name/workflow/success。artifact14420899163为libgkx，75758bytes，archive SHA25665c9331719d5d4ade30e306f74079a7d1ac193f90cbda445e95ef83635ebd45a，唯一dylib SHA2563a58118c5a7511bdce1df2b9babe33c62a42a2e8c18bccf7fb628bf9a5ba1b43，下载ZIP哈希/CRC/字节比对通过。
- 新IPA：dist/gboard-gkx-3574c24-toolbar-space-repair-unsigned.ipa，35972531bytes（34.31MiB），SHA2561dbcc15b992dc7655ddb749fb47e68b2bc141eb202d5510d132cb9747db4afd1；dist/gboard-gkx-3574c24-toolbar-space-repair-verification.json为PASS，父读回执与ops_stat核对一致。固定原包/词库哈希、2050条ZIP/3旧签名文件删除/8固定group槽/两个exe唯一load/RPATH/offset与755/644通过；只有3文件允许差异176/28/27bytes，其余2045原生文件逐字节与权限不变，arm64段/section/linkedit边界有效。
- 未覆盖：LCSign自签后的iPhone17Pro/iOS27 UIKit显示/字体/G对齐/触摸/初始-组字-清空三态/9↔26。日志不证明x56对象当前为空，修复用实时ContentRect而非硬编码x56；完整动画链保守拒绝，无事件新增子树尚无运行时证据。源码/CI/包交付已闭合而非真机恢复已证实；诊断默认关闭，待真机验收后退役，旧输入与产物保留，无PR/Release/原包上传。

## 2026-11-18 17:53 诊断 v2 交付实测

- 用户在旧包20b57f6上报告整行工具栏消失、只剩G；旧包编译/结构成功不证明显示已修复。当前v2只补可达诊断与反馈可靠性，不改变生产显示门禁。
- 127项Python源码契约（0.036s）和git diff --check exit0；独立复核无Critical/Important。源码证明门禁保持、摘要与延迟反馈绑定到当前owner/root；不替代UIKit。
- 源cb5c13ebd2400e912a64b4c9b322332bba52f4d8已推送；https://github.com/IamNewHands/gboard-gkx/actions/runs/44279394930 success（build28s），arm64/iOS12+编译链接和ldid成功，编译步骤无warning/error。平台注释提示Node20 actions强制Node24、macOS arm64容量提示；未改本次构建范围。
- CI artifact14415678917（libgkx），archive SHA2566987bbbb7fdcc43b1e2e2b3ad7a0438c53a3fba4b78391e3fb9221d6b900d2a1，经API精确SHA/run/artifact/未过期身份、archive哈希、ZIP CRC和dylib字节比对通过。dylib SHA256f85732573758523cc8497ddd2866d46593d7d40caac4a116baf81823336afe39。
- dist/gboard-gkx-cb5c13e-toolbar-diagnostic-v2-unsigned.ipa：35971004bytes，SHA256d30d7a5f6228569eab2f068a57cc4531e29940fbada8e23e1700b6622fb16ad0；dist/gboard-gkx-cb5c13e-toolbar-diagnostic-v2-verification.json为PASS回执。执行dist/package-toolbar-diagnostic-v2.sh含preflight/注入/final全部exit0。
- ZIP2050条，仅新增dylib与词库、移除3旧签名文件；Gboard2.3.19与keyboard-service扩展保持。两个exe各一个@rpath/libgkx.dylib，原段/RPATH不移动；group真实owner为共享框架8处。允许的二进制差异为共享框架176bytes、主exe28bytes、appex27bytes，所有其余2045原生文件逐字节与权限保持。
- 未覆盖：iPhone17Pro/iOS27自签后的UIKit长按/输入/字体/G/三态/9↔26。需要用户长按「换行」0.8秒开始，等2秒输入拼音、清空，再长按停止，返回首行为GXK toolbar diagnostic v2的剪贴板报告。60秒超时不自动写剪贴板。诊断默认关闭、60s/80样本/196608字符，不读输入、无网络或磁盘日志；根因修复并真机验收后退役。源码/构建/包证据可信，设备修复结论仍needs-verification。

## 2026-11-18 16:27 交付前实测

- 修复提交20b57f6863c1fe953d1deacef15bc5d76514e1b7已推送 main；Actions44266198725 success，clang arm64/iOS12+/QuartzCore 编译成功，无编译 warning/error。
- 最终118项回归 Ran 118 tests in 0.035s，OK，exit0；git diff --check exit0。
- 新 IPA35965458 bytes，SHA256 df7f595ea63c12c6187148e8f5ab6d42f95b610d19d7f7ccdee86b15001190dc；下载 dylib212688 bytes，SHA2563f3f74385eee334e5078f47da4725fe5c3af8201eb55472724ee8b715e74ef1e。输入原包SHA256c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731，词库SHA25612482d2893a8fe063b38b0a14db12f547b2fb3b90190cd65ab569a0bd7133839。
- 独立验证 exit0：ZIP CRC/无重名无路径穿越；一个确切 CI dylib与一个确切词库；755/644；两个可执行文件各增加一个@rpath/libgkx.dylib，原段和RPATH不变；共享框架8个原group槽精确替换，所有其他Mach-O字节仅允许加载命令区及这些槽改写；2045原生资源逐字节未变。无旧签名目录/mobileprovision；此未签名指可供自签，dylib保留CI的ldid ad-hoc签名。
- 校验器原第105行AssertionError: Requested App Group absent原因是检查owner错误；精确原包证据显示两个Gboard可执行文件没有完整group字面量，8处在gboard_framework.framework/gboard_framework，目标替换后8处、新dylib1处。只修校验器并增强字节断言，IPA不变。
- 交付范围为源码修复、CI编译、结构验证与unsigned IPA；UIKit真机对齐、触摸、布局切换仍未验证，复杂图层可导致工具栏安全不显示。

## 提交前历史证据（下述尚未编译/产出描述仅指当时状态）

- 2026-11-18：协调者执行 bundled Python -B -m unittest discover -s tests：Ran 118 tests in 0.034s，OK，exit 0。
- git diff --check：exit 0。独立 regression-update 同样全量118项通过，只修改三份测试。
- toolbar-review 原包方法复核：GKBImageViewWithBackground 的 layerClass 为 GKBImageLayer，setImage 转发 self.layer；原图 currentLayerForImage 返回 self，tint/template 返回 mask。native updateGravity 按 image.width 与 bounds.width 使用 Center 或 ResizeAspect，不依赖 UIView.contentMode。
- 同一 UIImage/CGImage identity、contentsScale、unit contentsRect/contentsCenter、实际 masksToBounds 与祖先完整性为唯一测量路径；mask/动画/transform/缺失绑定 fail closed。
- 静态九键 NIB：body candidates_upper y4..48，prime_keyboard y48..254。body rootY22 不等于首键 y22；不宣称永久遮挡。
- 原因闭环：任意标签造成 Helvetica16→候选20→来源失效仍保留20；现改回车身份与失效16pt。旧图形中心35为未裁剪36pt载体，不是实际可见G；现测真实显示图片。
- 未覆盖：iOS SDK编译、实际根 hit testing、三态字体/G对齐、9↔26切换、复杂图层导致不显示分支、性能真机指标。诊断关闭时不采样；长按复制0.8秒开始/停止，内存60秒/80样本/192Ki字符，不读输入。
- 原媒体：<local>/.gboard-video-analysis/toolbar-three-states.png；<local>/log2.txt；ScreenRecording_11-18-2026 13-46-24_1.mp4。
- 本地源码契约与审查不能替代 CI 或真机验收。新 IPA 尚未产生。
- 最终协调者再次执行118项回归：Ran 118 tests in 0.033s，OK，exit 0；提交前复跑 Ran 118 tests in 0.035s，OK，exit 0，暂存 diff --check exit 0。
- 现有仓库使用轻量 work Markdown，没有完整 helper workspace。helper check exit 1：缺 docs/aegis/adr、baseline、specs、plans 与 README.md、INDEX.md、BASELINE-GOVERNANCE.md；helper bundle 不适用缺 JSON sidecar 的记录。未为通过结构检查而扩大本次修复范围或初始化整套治理。此检查不影响源码测试，也不证明编译/验收。

## 2026-11-19 顶条行修复真机闭合（54734ad）

- 真机证据链：用户提供两份日志。第一份（28 samples，d0398c0 包）全部 scanGate=no-measurable-logo，证明 G 测量是唯一阻断；第二份（23 samples，d0398c0 包）band 已算出 {{43,0},{359,22}}、freshGlyph measured=1，唯一阻断变成 spaceGate=title-does-not-fit，且 22pt 行上 UIButton 的 contentRect 只有 10pt 高（contentInsets 上下各 6pt），16pt 标题 19.09pt 放不下 → titleRect=CGRectZero。两份日志把根因从"测量不到 G"推进到"按钮内边距"，不靠推理。
- 闪退归因证据：`git diff d0398c0 47c08a3 -- dylib/gkx.m` 逐 hunk 核对，功能性新增只有 `- (CGRect)contentRectForBounds:` 与 `- (CGRect)titleRectForContentRect:` 两个覆写；两包 dylib 的 load commands、rpath、依赖库、未定义符号集（47c08a3 少 9 个诊断专用符号、无新增）全部正常，排除注入/链接问题。
- 最终改动仅 3 文件：dylib/gkx.m（删两个覆写 + titleEdgeInsets + 纯算术几何判定）、tests/test_perf.py（同步断言 + 新增全 dylib 覆写扫描）、dist/verify-toolbar-space-repair.py（二进制标记改 setTitleEdgeInsets:）。
- 测试：`python -m unittest discover -s tests` → Ran 114 tests in 0.034s，OK，exit 0。新增契约 `test_no_uikit_layout_rect_override_anywhere_in_the_dylib` 用正则扫描 dylib 下全部 .m/.h，禁止 contentRectForBounds／titleRectForContentRect／titleRectForBounds／backgroundRectForBounds／imageRectForContentRect／intrinsicContentSize 的 CGRect/CGSize 覆写。
- CI 与产物：run 44459850140 success（head_sha 54734adc39d5391bfd48d88214c9ae7bc605d7fa，workflow .github/workflows/build-dylib.yml，macos-15-intel arm64/iOS12+，编译无 warning/error）；artifact 14499926011 libgkx，archive SHA256 bc681d68b0890ced4a44759ddac156f293f13bd39d6209516661fbda70b5c68b，未过期，身份经 API 精确绑定。dylib 193856 bytes，SHA256 9527637c93bc1e97813a4f5c96fb3c190cf7c6c2820409ed19dc4432123e509b；strings 检查 diagnostic／logoSurvey／onActionKeyDiagnostic:／contentRectForBounds:／titleRectForContentRect: 全部 0 命中，setTitleEdgeInsets: 2 命中。
- 新 IPA：dist/gboard-gkx-54734ad-toolbar-space-repair-unsigned.ipa，35960162 bytes，SHA256 a86bf2b49fcb6ab17f13a3f6a3eb8ac045752920e7eb8b7c6edb8fa86f8d3e42；preflight exit0 + 注入 exit0 + final exit0/PASS，回执 dist/gboard-gkx-54734ad-toolbar-space-repair-verification.json。2050 条 ZIP、移除 3 个旧签名文件、8 个 group 槽为 group.zunbengege.top、仅 176/28/27 bytes 三处允许差异、其余 2045 原生文件逐字节与权限不变、arm64 段/section/linkedit 边界与 RPATH 通过。
- 真机验收：用户 2026-11-19 反馈"正常了"——键盘不再闪退，工具栏在 22pt 顶条行显示。此前连续三包（3574c24／ccdb888／d0398c0）都是"键盘能用但工具栏不显示"，47c08a3 是"闪退"，54734ad 是首个真机确认可用的包。
- 经验固化：agent.md 新增避坑 9／10（覆写 UIKit 布局回调导致扩展闪退；可见矩形与绘制矩形、全宽容器、单候选放弃三个测量陷阱），并在第 1 节极简原则补上 22pt 行合法宿主与禁止覆写的红线；README.md 与 README.en.md 删除已失效的临时诊断章节，修正"条高至少 28pt"与"行高不足即不显示"为"默认 28pt、行高不足压到行高（下限 18pt）"。
- 未覆盖：本轮不验证字体随主题切换的视觉细节、9↔26 切换后的重复显示、横屏/其他机型；这些不属于本次根因范围，且用户已确认主路径正常。
