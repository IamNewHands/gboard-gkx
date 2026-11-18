# 最新续跑状态

- 当前状态：用户已授权推送/编译/出包，修复源ab5fafd54a89a68b9faf1b3ef5f8b0eea21c2826及CI-only提交ccdb888505211f1fff485e363190c8432771976b已推送main。首次macos-15分配失败；仅改macos-15-intel后run44302485661编译/伪签名/上传成功。新未签名IPA已生成且preflight/inject/final通过，独立最终验包exit0/PASS，实物哈希与回执一致，进入文件交付。139项源码/数值回归及23项验包测试通过；UIKit/真机仍needs-verification。旧3574c24包保留，不是本轮交付。

## log4 条带越行修复（本地源码阶段闭合；真机needs-verification）

- 修复开始时TaskStartSnapshot：main / a02c806；仅预存 CON 与 probe-zwb2izzd/ 无关，不修改或暂存。当时仅授权本地修复；后续用户明确要求推送并编译出包，发布阶段从ab5fafd开始，CI-only重试为ccdb888；不把旧文档授权当作新授权。
- Change Necessity / Decision: code-change：log4 的下方真实 G 可见 root=(17,26,22,20)，28pt 自有条带居中后 root=(43,22,359,28)，向上侵入原生上行 4pt；完整原生命中障碍使宽度归零。改字号或放宽 200pt 不解决条带所有权错误。
- PatchShape / CanonicalOwner：现有 GXKToolbarBand 同时负责文字锚点与 hit band，最小修复在 toolbar_layout.h 将 hit band 约束在实测 row 内，向现有 GXKToolbarButton 传递同次实测 G 中心，单独布局自有 title/divider；bound/rebuild/cache 路径共享此测量。ArchitectureReviewRequired: yes（共享视觉与交互几何），采用独立只读设计/最终复核，不新增布局或 fallback owner。TDD Route: off。
- Minimality / OwnerFit：退役“最小28pt点击条带必须与G共用中心且可越行”的内部责任；保留 G 实际可见图中心、原生回车字体、28pt目标、透明五格、原生所有键/候选/图片和独立26键优先。既有大 gkx.m 仅现有按钮布局及局部接线，不新增原生hook；不修改原生几何/alpha/hidden/globaltouch/键盘高度，不删除文件/持久化/外部契约。Anti-Entropy: code-retirement / delete-first，保留合法原生命中 carrier；无不可逆删除。
- 原生正证据：原包 GKBHeaderLogoView 继承 GKBSoftKeyView，有 hitTest:withEvent:；Logo 圆形host分支以外回到父类，父类在 softKeyDef 非nil 时按 bounds 返回self。不能把上部全宽Logo改当纯图像/忽略它；本轮 visibility owner不变。
- 验证计划：log4 4pt越行回放、非零 row bounds/上下沿/过短row/无G/原生障碍/实际文字高不足/字号变化与同band G移动；fresh Python源码契约加几何回放及最终diff独立复核。回放不是UIKit；本机无iOS clang/SDK。当前CI/新IPA已验证结构，iPhone文字/点击/三态/9↔26仍未验证。诊断默认关闭并暂时保留，真机验收后撤。

- 本轮终验：139项/0.067s/OK，diff check exit0；独立源码复核覆盖最终rowContains与unclamped诊断顺序；独立测试增量8项/exit0，覆盖合法非零bounds、candidate越出row与NaN/±Inf。可信度C仅指产品修复尚缺UIKit/真机证据，不否定本地已执行结果。任务内8文件，预存CON保留；未新建分支/worktree，无后台job。
- 续跑：推送/编译/本地出包授权已满足；先读本段、90-evidence.md与agent.md，再核对main HEAD/工作树；最终独立验包已通过；交付dist/gboard-gkx-ccdb888-toolbar-space-repair-unsigned.ipa。用户用LCSign自签验证初始/组字/清空、G文字中心、触摸、9↔26和空剪贴板失败提示恢复。不得重发旧包或由346pt几何宽度推导已显示；不上传原IPA，不创建Release。

## 旧修复交付（以下至log3章节均为历史，不是当前源提交）
- 修复源提交：main / 20b57f6863c1fe953d1deacef15bc5d76514e1b7，已推送 origin=https://github.com/IamNewHands/gboard-gkx.git；本地与远端该 SHA 一致。
- 已完成：稳定回车字体 owner、真实 foreground GKBImageLayer 与祖先 masksToBounds 测量、根坐标约束、弱引用原生障碍及九键/独立26键实时门控；独立复核通过，最终118项回归 OK。
- CI：https://github.com/IamNewHands/gboard-gkx/actions/runs/44266198725，headSha 与修复提交相同，macOS 15 arm64/iOS12+ clang、QuartzCore 链接、ldid 与 artifact 上传均成功，编译日志无 warning/error。
- 产物：dist/gboard-gkx-20b57f6-needs-device-verification-unsigned.ipa，35965458 bytes（34.30 MiB），SHA256 df7f595ea63c12c6187148e8f5ab6d42f95b610d19d7f7ccdee86b15001190dc；校验回执 dist/gboard-gkx-20b57f6-verification.json。
- 输入：D:/GitHub_Clone/Gboard_2.3.19.ipa、dist/user_dictionary.db、该次 CI 的 dist/artifact-20b57f6/libgkx.dylib；group.zunbengege.top。独立只读校验验证 ZIP/arm64/加载命令/RPATH/offsets/755与644/8处共享框架group替换/2045资源字节不变。
- 更正：Chrome/CDP 不应作为 GitHub CLI 的前置条件；用户指定 CLI 后已直接推送和编译。此前失败来自受限 schannel 凭据/网络上下文，不是 CI；当前 danger-full-access 成功。校验器一度错误要求每个 Gboard 可执行文件含完整 group 字符串；原包真实 owner 为共享框架，已纠正并加强允许变更之外的字节对比，产物无重打包。
- 真机下一步：LCSign 自签安装此包，检查初始/输入中/清空后三态字体与G对齐、工具栏点击及9↔26切换；测量不完整或可见G不足8pt时仍会安全不显示。诊断默认关闭，长按复制0.8秒开始/停止内存采样；验收通过后移除诊断接线。
- 工作区保护：预存 CON 与 probe-zwb2izzd/ 无关，不 stage、不删除；新提取目录 dist/pack-20b57f6 保留。没有 PR/Release、强推或新增分支。

## log3 空位修复（2026-11-18 19:14交付；源码/CI/验包完成，真机待验收）

- TaskStartSnapshot：main / 57e385e25020e549c1e672399a4feede065386ef；仅预存CON未跟踪。用户授权代码修复、测试/独立审阅、直接push main、Actions编译及unsigned IPA，无PR/Release。
- Change Necessity / Decision: code-change：不能靠改字号或放宽200pt门槛修复“容器外框被当成内容”的责任错误。最小边界为布局/实际内容owner共用可见障碍矩形、临时边界取证与对应契约测试；原生几何/输入/手势不改。
- PatchShape / CanonicalOwner：原band逐兄弟外框边界与NativeSpaceClear实际内容判据分裂；改为共享弱注册表和同一ContentRect，最近右侧实际内容限制band，最终仍重查全部障碍及九键/独立26键。ArchitectureReviewRequired: yes（共享几何/内容接口），采用只读owner审阅及最终独立审阅；无需新架构文档。
- Minimality / OwnerFit：在现有layout/visibility文件抽出注册准备/实际矩形/right边界helper；不新增fallback owner。失效责任为任意兄弟UIView.frame决定占位；合法右侧按键/候选/图片保留实际内容与完整裁切后触摸区域。内部code-retirement，无外部契约/持久化删除；不删除文件或原生对象。缓存必须先评估实时内容矩形再复用，不能靠旧兄弟签名/epoch证明空位。TDD Route: off。
- 已检查风险：上部G的36pt载体外框与实际可见22x2pt不同，障碍测量与G锚点授权分离（锚点仍8..64）；不支持的非空图片用保守裁切后外框，复杂/动画几何不能授权空间。空collection需继续检查其子视图以保留supplementary内容。原包静态NIB不能证明本次x56对象当前为空，修复按实时内容判断，不硬编码类名/x56。
- 验证计划：日志几何回放与非空候选/右图标/跨左边界/祖先裁切/大图片/既有载体无事件内容翻转/9↔26反例；Python源码契约非UIKit，云端clang与原包字节/ZIP/加载/权限独立校验后交付待真机验收。默认关闭的v2诊断保留，增补真实rightBound对象，根因修复并真机验收后再撤。
- 续跑实测（18:57）：129项静态契约已通过，前轮“1失败”为旧工作树记录而非当前结果；前轮space-repair-review因上游模型报错中断，没有审阅结论，本轮重启space-review/package-review。独立审阅定位model opacity/bounds判空可先于祖先animation检查；现同一ClippedViewRect完整检查图层链，到root唯一成功出口，ContentRect即使nil image/text/items也先验证载体链。注册UICollectionReusableView并继续检查子视图，保留自绘supplementary完整区域。新鲜130项/0.038s/OK、git diff --check exit0。
- 覆盖边界：弱注册表对已登记载体每次重读内容；新增/移除子树仍依赖controller文字/布局/生命周期epoch，无事件结构突变未经UIKit验证。保守拒绝动画/复杂图层，可能过渡中暂时隐藏；不承诺自动放行。本轮源码独立复核Important动画项已关闭、无剩余Critical/Important；fresh130项/0.036s/OK。用户本轮明确回复“直接推送，后续不要再询问了，记到记忆里”，已授权直接push main/Actions/unsignedIPA，不包含强推、PR/Release/原包上传。打包校验器来源与固定原包断言缺口由package-review补强中；生产源码先提交编译，验包闭合后交付。

- 终态验证（19:14）：Actions44291336372 success，https://github.com/IamNewHands/gboard-gkx/actions/runs/44291336372；head_sha为3574c24368a9a48df1ac6994bd463d6c6df258b5，workflow .github/workflows/build-dylib.yml，macos-15-arm64/iOS12+ clang/QuartzCore/ldid成功，无编译warning/error；上传器Node弃用警告非编译失败。父审后fresh23项验包反例/6.210s/OK及130项源码契约/0.036s/OK，git diff --check exit0，源码与CI提交无diff。Windows zipfile先归一化反斜杠/截NUL导致旧filename入口漏检，已在同一safe_zip owner读取orig_filename并拒绝归一化/截断；原始双header反例通过，未放宽规则。
- 单次打包：dist/package-toolbar-space-repair.sh的preflight/注入/final全部exit0；两阶段实时GET绑定精确commit/run/artifact/name/workflow/success，archive哈希/ZIP CRC/原名无重名与穿越/唯一dylib字节通过。artifact14420899163（libgkx，75758bytes），archive SHA25665c9331719d5d4ade30e306f74079a7d1ac193f90cbda445e95ef83635ebd45a；dylib SHA2563a58118c5a7511bdce1df2b9babe33c62a42a2e8c18bccf7fb628bf9a5ba1b43。
- 产物：dist/gboard-gkx-3574c24-toolbar-space-repair-unsigned.ipa，35972531bytes（34.31MiB），SHA2561dbcc15b992dc7655ddb749fb47e68b2bc141eb202d5510d132cb9747db4afd1；dist/gboard-gkx-3574c24-toolbar-space-repair-verification.json为PASS回执，父读取回执与ops_stat重新核对哈希/大小一致。2050条ZIP，仅新增确切dylib/词库并移除3旧签名文件；两个exe各唯一@rpath/libgkx.dylib且RPATH/原段/文件offset保持，8个固定group槽替换为group.zunbengege.top；允许3文件差异176/28/27bytes之外2045原生文件字节/权限不变，arm64段/section/linkedit边界验证通过。
- Complexity Closure：exceeded-and-governed；既有大gkx.m仅接线/现有局部行为修正，实际内容和裁切责任共用既有visibility/layout owner，退役任意兄弟外框与旧缓存签名判空路径，无新fallback/重试owner；验包单一provenance/ZIP owner与同目录反例维护，checkpoint/evidence替换临时状态而不新增治理文件。广泛拆分大源文件不属本任务；当前修复无未治理新增责任。
- 交付边界：本轮源码/CI/结构验包与unsigned IPA完成；真机初始/组字/清空三态、字体/G对齐/工具栏触摸/9↔26需LCSign自签后验收。诊断默认关闭且临时保留，真机根因验收后再撤；无事件新增子树/复杂动画没有运行时放行证据。原IPA、词库、dist/pack-3574c24-space-repair、旧产物和预存CON/probe均保留；没有PR/Release/强推/原包上传，不重跑已完成打包。

## 整行消失回归：诊断 v2（2026-11-18）

- 任务起点：main / eee9a324ac23bcf273e8941072f8384c4bbb274c，源代码与 20b57f6 修复包一致。用户真机现象为整行消失，不能拿旧 log2.txt 或源码反例当作当前根因证明。
- 已证实诊断缺口：原入口仅在工具栏「复制」按钮，工具栏隐藏/解绑后无法采样。临时新增自有「换行／重输」按钮长按 0.8 秒开始/停止，验证当前按钮/宿主/原生模型/九键体，原 tap 保持不变、不在 G/原生键/根视图挂手势。
- 证据：记录最后生产 scan/band/space gate、实际阻挡对象/祖先、带宽和根内候选矩形；独立扫描所有 G 角色（包含隐藏或不可测，最多 6 个，1500 节点）；逐 UIImage 列出图层身份、CGImage/像素、动画/transform、绘制/裁切后矩形。覆盖不足均须看 truncated/listed；历史 gate 不是新测量。
- 保留边界：未放宽任何生产显示谓词；无新高度/原生 alpha-hidden/输入捕获/网络或磁盘日志。诊断默认关闭，60 秒/80 样本/196608 字符上限，显式停止才写剪贴板；真机根因修复并验收后再撤诊断接线。
- 验证：125 项本地 Python 契约全部通过，非 UIKit 执行。曾有 4 项测试失配：tap 提取器命中声明后拿到新增诊断方法，已精确选择实现；两处门控一行 return 变为附诊断标签的块，测试仍检查原谓词与 return NO，不放宽原安全边界。独立复核发现并修正三处诊断问题：每次生产尝试独立重置 gate/band/blocker，未走分支标 not-evaluated 且绑定 owner/root；反馈代次守卫并按当前组字状态恢复两态标题，避免回写旧标题；16 层图层链未到 root 明确标 layerChainTruncated 并汇总 truncated，8 层 view 链标 chainTruncated。反馈清理允许仍绑定但隐藏的工具栏复制按钮恢复固定标题，可见性仅在 action key 分支验证。诊断遍历 visited 上限时计数可能多 1（P3），truncated 判定仍正确，不影响显示生产谓词。续跑独立复核再确认两处反馈串扰：跨按钮开始/停止会废弃旧回调，普通复制错误会把「诊断」当恢复基线。现共用当前 owner/root/绑定校验恢复函数，在切换反馈按钮前恢复上一按钮；普通 Copy 错误用固定「复制」基线，旧错误回调只在该按钮不由诊断占用时恢复，Highlighted 也由诊断恢复为当前标题。新鲜 127 项契约与 git diff --check 全部通过；最终独立复核无 Critical/Important，确认两处串扰已修正、生产显示与输入动作保持原谓词，仅建议诊断包待 CI 编译后交付。仍有 P3 遍历计数多 1，不影响覆盖不足标记；UIKit/真机长按与显示根因未验证。CI/IPA 已完成，见下方交付证据。
- 真机待收：安装 v2 包，长按「换行」开始，输入拼音、清空、再长按「换行」停止并复制报告；提供报告后按实际 gate 修复显示，验收初始/输入中/清空及9↔26。
- 历史发布停点（2026-11-18 17:25，17:48 已解除）：本地 main 已提交 cb5c13ebd2400e912a64b4c9b322332bba52f4d8（Add reachable bounded toolbar diagnostic v2），8 个任务路径已提交，127 项静态契约/独立复核通过。git push origin main 在 workspace-write 返回 schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)，本地提交已完成不可重跑发布脚本；随后两次 danger-full-access 单独 push 审批调用分别在 120000/600000ms 超时，未返回命令结果。已核查无后台 job，GitHub main 仍 eee9a324ac23bcf273e8941072f8384c4bbb274c，无 v2 CI。停止重复审批，待用户确认会话权限/审批可用后只 push 现存提交，再查精确 SHA 的 CI、下载 libgkx、运行 dist/package-toolbar-diagnostic-v2.sh 与 dist/verify-toolbar-diagnostic-v2.py；尚无 v2 IPA，不得交付旧包冒充。此次停点仅修改本 checkpoint，待交付后再补文档提交。自动续跑第 1/2 轮仍未获得可执行推送的提权结果；第 2 轮专门询问审批状态的 ask_user_question 也在 600000ms 后超时，没有用户答案，不能视为批准。远端再次核实仍 eee9a324ac23bcf273e8941072f8384c4bbb274c；不继续重复审批或绕过沙箱。
- 发布恢复（2026-11-18 17:48）：用户明确回复「已批准」，会话现为 danger-full-access；未再次申请权限，单独 git push origin main exit0（eee9a32..cb5c13e）。远端精确 SHA cb5c13ebd2400e912a64b4c9b322332bba52f4d8 已核验；Actions44279394930 对应此 SHA 正在运行，https://github.com/IamNewHands/gboard-gkx/actions/runs/44279394930。新鲜127项回归与git diff --check exit0；该行记录恢复时刻，最终结果如下。

## 诊断 v2 交付（2026-11-18 17:53）

- 源码：cb5c13ebd2400e912a64b4c9b322332bba52f4d8，main 已推送；Actions44279394930 success，macOS15 arm64/iOS12+ clang、QuartzCore、ldid 与上传均成功，编译步骤无warning/error。127项Python源码契约exit0，不是UIKit执行。
- 产物：dist/gboard-gkx-cb5c13e-toolbar-diagnostic-v2-unsigned.ipa，35971004 bytes（34.30 MiB），SHA256 d30d7a5f6228569eab2f068a57cc4531e29940fbada8e23e1700b6622fb16ad0；回执dist/gboard-gkx-cb5c13e-toolbar-diagnostic-v2-verification.json。CI artifact14415678917，archive SHA2566987bbbb7fdcc43b1e2e2b3ad7a0438c53a3fba4b78391e3fb9221d6b900d2a1；dylib SHA256f85732573758523cc8497ddd2866d46593d7d40caac4a116baf81823336afe39。
- 校验：preflight+注入+final exit0/PASS；2050条ZIP无重名/路径穿越/CRC错误，仅新增确切dylib与词库、移除3签名文件；两个exe各一个加载命令且原段/RPATH不移动；共享框架8个group槽为group.zunbengege.top。除允许的三个二进制改写（176/28/27bytes）外，2045个原生文件字节和权限不变。保留原包与词库、dist/pack-cb5c13e-diagnostic-v2和预存CON/probe目录。
- 真机步骤：LCSign自签新IPA→九键长按自有「换行」0.8秒见「诊断」→等2秒后输入拼音并清空→再次长按「换行／重输」0.8秒见「已复制」→粘贴报告给Agent。报告首行应为GXK toolbar diagnostic v2；60秒超时只停止采样并保留内存，仍须显式长按才写剪贴板。
- 交付仅闭合诊断可达性/可靠性、编译与包验证；未覆盖iPhone17Pro的UIKit手势/字体/G/触摸/三态/9↔26真实行为，不接受为显示根因修复。P3visited计数可多1但truncated有效。诊断临时保留且默认关闭，不采集输入/上传/写磁盘、不放宽显示门禁；根因修复且真机验收后移除诊断接线/helper/测试。
