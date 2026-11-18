# 最新续跑状态

- 状态：needs-verification；代码、独立复核与118项静态回归已完成，本记录随修复提交归档；尚未推送、编译或交付新 IPA。
- 原基线：main / 3c7bb2de8a3db7e00b041090832a9b2059e9c901；origin=https://github.com/IamNewHands/gboard-gkx.git。
- 已完成：稳定回车字体 owner、真实 foreground GKBImageLayer 及祖先 masksToBounds 测量、根坐标约束、弱引用原生障碍/九键/独立26键实时门控、共享只读诊断和118项回归。
- 独立复核：未发现阻止进入 CI/真机验证的确定性问题；未编译，未证实 UI 已修复。
- 外部前置：2026-11-18 16:17 重新检查仍为 exit 1：默认偏好 Chrome 未连接；之前系统打开 Chrome 后仍同错，询问开启远程调试等待超时，无授权回复。用户需在 chrome://inspect/#remote-debugging 勾选 Allow remote debugging for this browser instance。没有尝试用另一浏览器绕过。
- 下一步：重跑 web-access 前置；通过后推送 main，读取该 SHA 的 Actions，下载新 libgkx artifact，使用现有 inject.py 和 group.zunbengege.top 输出唯一命名 needs-device-verification unsigned IPA，校验并交付。
- 打包输入：dist/user_dictionary.db；既有原包需从仓库 assets/tools 配置重新确认；旧 dist/gboard-gkx-3c7bb2d-toolbar-diagnostic-unsigned.ipa 不是本次产物。
- 工作区保护：预存 CON 与 probe-zwb2izzd/ 权限警告无关；不 stage、不删除。仅明确任务路径提交，无强推。
- 漂移判断：continue 本地归档；联网等待用户前置。目标未完成，不把 AgentRouter 400 content-blocked 当作 CI 失败。
