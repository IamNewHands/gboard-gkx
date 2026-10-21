# gboard-gkx

在 Gboard iOS 2.3.19 基础上做增强（保留原生引擎与滑行输入），通过 dylib 注入实现。

- 构建：GitHub Actions（macOS runner，无需本地 Mac）
- 注入：Windows 本地，纯 Python，无第三方依赖
- 签名：LCSign / SideStore 自签

---

## 目录

```
dylib/gkx.m                     dylib 源码
.github/workflows/build-dylib.yml   CI 构建
tools/inject.py                 注入 + 重打包
dist/                           产物
```

---

## 流程

### 1. CI 出 dylib

推送到 GitHub 后，Actions 里 `build-dylib` 会自动跑，产物是 artifact `libgkx`（内含 `libgkx.dylib`）。
也可以手动 `workflow_dispatch` 触发。

### 2. 本地注入

```powershell
python tools/inject.py `
  --ipa   "<local>\input\keyboard-2.3.19-eeveedecrypter.ipa" `
  --dylib ".\dist\libgkx.dylib" `
  --out   ".\dist\gboard-gkx-unsigned.ipa"
```

脚本会：

1. 解包 IPA
2. 给 `Gboard.appex/Gboard` 原地写入 `LC_LOAD_DYLIB @rpath/libgkx.dylib`
   （覆盖 load commands 之后的填充区，不移动任何字节，所有 section 偏移保持有效）
3. 把 dylib 放进 `Gboard.appex/Frameworks/`
4. 删除 `_CodeSignature` / `SC_Info`
5. 重新打包

### 3. 自签安装

用 LCSign 或 SideStore 签 `dist/gboard-gkx-unsigned.ipa`，装到设备。

装完到 **设置 → 通用 → 键盘 → 键盘 → Gboard → 允许完全访问** 打开。

---

## Phase 0 验收

打开任意输入框切到 Gboard，键盘**左上角出现绿底白字 `GXK OK`** 即注入成功。

失败排查顺序：

1. 键盘里没有标记 → dylib 没被加载。检查 `Gboard.appex/Frameworks/libgkx.dylib` 是否在包里
2. 键盘直接不出现 / 一闪而过 → 扩展启动被拒，多半是签名或描述文件问题
3. 键盘正常但无标记 → hook 没命中，确认 `GKBUIInputViewController` 类名未变

---

## 已知风险

| 风险 | 说明 | 对策 |
|---|---|---|
| 扩展描述文件 | LCSign 老版本不给 `.appex` 嵌 mobileprovision | 签完拆包检查 `Gboard.appex/embedded.mobileprovision` 是否存在 |
| CodeResources 校验 | 注入的 dylib 若未纳入重签的 CodeResources，安装/启动会失败 | LCSign 通常整体重签；失败则改用能递归签嵌套二进制的工具 |
| dylib 未签名 | CI 用 `ldid -S` 签过；重签后可能被覆盖 | 一般无碍，若启动崩溃再单独补签 |

---

## 后续阶段

见 `../work/kb2319/PLAN.md`。
