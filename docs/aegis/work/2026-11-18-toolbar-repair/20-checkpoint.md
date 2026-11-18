# 最新续跑状态

- 状态：构建与打包交付已完成；界面验收 needs-device-verification，不宣称真机问题已解决。
- 修复源提交：main / 20b57f6863c1fe953d1deacef15bc5d76514e1b7，已推送 origin=https://github.com/IamNewHands/gboard-gkx.git；本地与远端该 SHA 一致。
- 已完成：稳定回车字体 owner、真实 foreground GKBImageLayer 与祖先 masksToBounds 测量、根坐标约束、弱引用原生障碍及九键/独立26键实时门控；独立复核通过，最终118项回归 OK。
- CI：https://github.com/IamNewHands/gboard-gkx/actions/runs/44266198725，headSha 与修复提交相同，macOS 15 arm64/iOS12+ clang、QuartzCore 链接、ldid 与 artifact 上传均成功，编译日志无 warning/error。
- 产物：dist/gboard-gkx-20b57f6-needs-device-verification-unsigned.ipa，35965458 bytes（34.30 MiB），SHA256 df7f595ea63c12c6187148e8f5ab6d42f95b610d19d7f7ccdee86b15001190dc；校验回执 dist/gboard-gkx-20b57f6-verification.json。
- 输入：D:/GitHub_Clone/Gboard_2.3.19.ipa、dist/user_dictionary.db、该次 CI 的 dist/artifact-20b57f6/libgkx.dylib；group.zunbengege.top。独立只读校验验证 ZIP/arm64/加载命令/RPATH/offsets/755与644/8处共享框架group替换/2045资源字节不变。
- 更正：Chrome/CDP 不应作为 GitHub CLI 的前置条件；用户指定 CLI 后已直接推送和编译。此前失败来自受限 schannel 凭据/网络上下文，不是 CI；当前 danger-full-access 成功。校验器一度错误要求每个 Gboard 可执行文件含完整 group 字符串；原包真实 owner 为共享框架，已纠正并加强允许变更之外的字节对比，产物无重打包。
- 真机下一步：LCSign 自签安装此包，检查初始/输入中/清空后三态字体与G对齐、工具栏点击及9↔26切换；测量不完整或可见G不足8pt时仍会安全不显示。诊断默认关闭，长按复制0.8秒开始/停止内存采样；验收通过后移除诊断接线。
- 工作区保护：预存 CON 与 probe-zwb2izzd/ 无关，不 stage、不删除；新提取目录 dist/pack-20b57f6 保留。没有 PR/Release、强推或新增分支。
