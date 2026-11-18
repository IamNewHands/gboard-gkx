# 稳定原生动作键修复

## 原始意图与验收边界

用户真机反馈：替换的「换行」键会漂移，有时跑到回车位置；123/符号页也要替换表情；26键不替换；换行保持原生外观，不另加高亮。保留已有输入拼音时「重输」功能，不扩展词库或工具条需求。

范围：本地源码修复、可执行的离线回归与准确交付；不授权 GitHub 推送、远程构建/上传、发布、凭据读取、既有数据删除。iOS 编译、真机点击及视觉验收不能用 Windows 模型测试代替。

## TaskStartSnapshot

- 日期：2026-11-14；cwd：<local>；仓库：<local>/gboard-gkx。
- 分支：main；HEAD：864f1e0d3968a38a419252febb2fcd3bbbc14fd8；开始时已跟踪文件干净。
- git status 对旧 tests/gkx-test-* 目录有 Permission denied 警告；不清理或改写这些既有目录。
- 生效基线：README.md、agent.md、dylib/gkx.m、.github/workflows/build-dylib.yml。无项目 AGENTS.md/CONTEXT.md。
- 目标：Gboard 2.3.19，arm64，iOS 12+；原始 IPA：<local>/Gboard_2.3.19.ipa；SHA256 c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731。
- 当前 Windows 无 PATH 中 clang，无法运行 UIKit；不安装工具链。

## 修复治理

- Change Necessity：code-change。已有精确 ID 未命中仍按坐标猜键，且切换后的视图/点击身份未重验证；覆盖层隐藏全部子视图并独立配色。原包已证明九键、123、符号三种布局都属于GKB9KeysSoftKeyboardView；“123/符号缺少9Key类”假设已排除。具体真机漏换触发尚未复现，不能仅据源码断言字典必然失效。
- 风险：medium（私有 UIKit 视图复用、原生状态/视觉/触摸）；TDD Route：off，仍要求离线回归与新鲜证据。
- CanonicalOwner：dylib/gkx.m 中目标键解析与动作覆盖层生命周期。
- PatchShape：替换错误目标/样式责任，不叠加更多坐标兜底；明确原生布局身份与视图关联；重验证点击。
- Ripple：布局切换、候选面板、主题、视图复用、隐藏/显示、输入状态、旧视图恢复。禁止修改根/header/body几何、Mozc、词库部署、全局 touches 链。
- OwnerComplexity：owner-local；仅在共享判定需要可执行回归时提取小型无 UIKit 策略函数，避免新增框架。
- ArchitectureReviewRequired：true，独立核对原生身份/布局证据，实施后进行只读独立复核；不要求分支/worktree。
- 退役责任：坐标猜键、独立不透明键帽、无条件恢复全部隐藏子视图。保留能力：表情 carrier、原生回车、26键、重输、词库、原生样式。

## 本地计划

1. 核对原始 IPA 的布局/按键身份及原生样式接口；确认源码字节，不从字符串名称推执行。
2. 在单一按键 owner 中修复目标解析、状态恢复与原生外观，增加可执行回归。
3. 执行策略/静态契约/源码检查与独立复核，记录 iOS 构建及真机验收缺口。

## 状态载体

本目录唯一状态载体：20-checkpoint.md；证据：90-evidence.md。不生成第二份计划或平行交接记录。
