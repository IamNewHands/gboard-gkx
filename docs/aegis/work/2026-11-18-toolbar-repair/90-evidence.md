# 已实测证据与未覆盖边界

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
- 原媒体：D:/GitHub_Clone/.gboard-video-analysis/toolbar-three-states.png；D:/GitHub_Clone/log2.txt；ScreenRecording_11-18-2026 13-46-24_1.mp4。
- 本地源码契约与审查不能替代 CI 或真机验收。新 IPA 尚未产生。
- 最终协调者再次执行118项回归：Ran 118 tests in 0.033s，OK，exit 0；提交前复跑 Ran 118 tests in 0.035s，OK，exit 0，暂存 diff --check exit 0。
- 现有仓库使用轻量 work Markdown，没有完整 helper workspace。helper check exit 1：缺 docs/aegis/adr、baseline、specs、plans 与 README.md、INDEX.md、BASELINE-GOVERNANCE.md；helper bundle 不适用缺 JSON sidecar 的记录。未为通过结构检查而扩大本次修复范围或初始化整套治理。此检查不影响源码测试，也不证明编译/验收。
