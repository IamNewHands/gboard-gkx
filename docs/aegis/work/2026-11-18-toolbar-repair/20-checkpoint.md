# 最新续跑状态

- 当前状态：诊断 v2 源提交 cb5c13e 已推送、Actions44279394930 编译成功、unsigned IPA 结构与字节校验 PASS，待用户 LCSign 自签安装并返回报告。上一版20b57f6真机验收失败（整行工具栏消失、只剩G），显示根因仍未证实、不宣称已修复。以下旧修复记录是历史证据；本次v2交付在末节。
- 修复源提交：main / 20b57f6863c1fe953d1deacef15bc5d76514e1b7，已推送 origin=https://github.com/IamNewHands/gboard-gkx.git；本地与远端该 SHA 一致。
- 已完成：稳定回车字体 owner、真实 foreground GKBImageLayer 与祖先 masksToBounds 测量、根坐标约束、弱引用原生障碍及九键/独立26键实时门控；独立复核通过，最终118项回归 OK。
- CI：https://github.com/IamNewHands/gboard-gkx/actions/runs/44266198725，headSha 与修复提交相同，macOS 15 arm64/iOS12+ clang、QuartzCore 链接、ldid 与 artifact 上传均成功，编译日志无 warning/error。
- 产物：dist/gboard-gkx-20b57f6-needs-device-verification-unsigned.ipa，35965458 bytes（34.30 MiB），SHA256 df7f595ea63c12c6187148e8f5ab6d42f95b610d19d7f7ccdee86b15001190dc；校验回执 dist/gboard-gkx-20b57f6-verification.json。
- 输入：D:/GitHub_Clone/Gboard_2.3.19.ipa、dist/user_dictionary.db、该次 CI 的 dist/artifact-20b57f6/libgkx.dylib；group.zunbengege.top。独立只读校验验证 ZIP/arm64/加载命令/RPATH/offsets/755与644/8处共享框架group替换/2045资源字节不变。
- 更正：Chrome/CDP 不应作为 GitHub CLI 的前置条件；用户指定 CLI 后已直接推送和编译。此前失败来自受限 schannel 凭据/网络上下文，不是 CI；当前 danger-full-access 成功。校验器一度错误要求每个 Gboard 可执行文件含完整 group 字符串；原包真实 owner 为共享框架，已纠正并加强允许变更之外的字节对比，产物无重打包。
- 真机下一步：LCSign 自签安装此包，检查初始/输入中/清空后三态字体与G对齐、工具栏点击及9↔26切换；测量不完整或可见G不足8pt时仍会安全不显示。诊断默认关闭，长按复制0.8秒开始/停止内存采样；验收通过后移除诊断接线。
- 工作区保护：预存 CON 与 probe-zwb2izzd/ 无关，不 stage、不删除；新提取目录 dist/pack-20b57f6 保留。没有 PR/Release、强推或新增分支。

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
