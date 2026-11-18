# 已实测证据与未覆盖边界

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
