# 已实测证据与未覆盖边界

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
