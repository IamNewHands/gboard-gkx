#!/usr/bin/env python3
"""注入脚本契约：主 App 与扩展都必须注入，且 rpath 落点各自解析正确。"""
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import inject  # noqa: E402

SOURCE = ROOT / "tools/inject.py"


def function_body(source: str, signature: str) -> str:
    """按缩进截取 Python 函数体（从签名行到下一个顶格行）。"""
    lines = source.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(signature))
    end = len(lines)
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if line.strip() and not line[0].isspace():
            end = i
            break
    return "\n".join(lines[start:end])


class InjectContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_main_app_is_injected_too(self):
        main = function_body(self.source, "def main():")
        self.assertIn("bundle_executable(main_app)", main)
        self.assertIn("add_load_command(app_exe)", main)
        # 主 App 注入失败必须中止，不能产出只拦扩展的半成品包。
        self.assertIn("主 App 加载命令未写入", main)
        # dylib 必须真的落到主 App 的 Frameworks，权限 0755。
        self.assertIn("app_dst = os.path.join(app_fw, DYLIB_NAME)", main)
        self.assertIn("os.chmod(app_dst, 0o755)", main)

    def test_app_rpath_resolves_inside_main_app(self):
        app = str(ROOT / "Payload/Gboard.app")
        with mock.patch.object(inject, "_rpaths", return_value=["@executable_path/Frameworks"]):
            fw, rp = inject.resolve_app_frameworks_dir(app, "/dummy/Gboard")
        self.assertEqual(rp, "@executable_path/Frameworks")
        self.assertEqual(Path(fw), Path(app) / "Frameworks")

    def test_appex_rpath_still_resolves_to_main_app_frameworks(self):
        appex = str(ROOT / "Payload/Gboard.app/PlugIns/Gboard.appex")
        with mock.patch.object(inject, "_rpaths", return_value=["@executable_path/../../Frameworks"]):
            fw, rp = inject.resolve_frameworks_dir(appex, "/dummy/Gboard")
        self.assertEqual(rp, "@executable_path/../../Frameworks")
        self.assertEqual(Path(fw), ROOT / "Payload/Gboard.app/Frameworks")

    def test_unknown_rpath_fails_closed(self):
        with mock.patch.object(inject, "_rpaths", return_value=[]):
            with self.assertRaises(ValueError):
                inject.resolve_app_frameworks_dir("/tmp/Gboard.app", "/dummy/Gboard")

    def test_app_group_flag_is_required(self):
        """漏掉 --app-group 必须立刻报错：真机上漏掉会闪退且键盘锁 26 键。"""
        import contextlib
        import io

        with mock.patch.object(sys, "argv", ["inject.py", "--ipa", "a.ipa", "--dylib", "b.dylib", "--out", "c.ipa"]):
            with contextlib.redirect_stderr(io.StringIO()) as err:
                with self.assertRaises(SystemExit) as ctx:
                    inject.main()
        self.assertNotEqual(ctx.exception.code, 0)
        self.assertIn("--app-group", err.getvalue())

    def test_app_group_rewrite_is_unconditional(self):
        """改写 app group 不能是可跳过的分支。"""
        main = function_body(self.source, "def main():")
        self.assertIn("patch_app_groups(payload, args.app_group)", main)
        self.assertNotIn("if args.app_group:", main)
        # 没命中任何字符串时必须中止，而不是产出看起来正常的包。
        self.assertIn("拒绝产出误导性安装包", main)

    def test_app_group_format_is_validated_before_unpack(self):
        main = function_body(self.source, "def main():")
        guard = main.index('--app-group 必须是 group. 开头的合法标识符')
        self.assertLess(guard, main.index("unpack(args.ipa, workdir)"))

    def test_both_resolvers_land_in_same_physical_dir(self):
        """同一份 dylib 对两个进程都可达：两条 rpath 必须解析到同一目录。"""
        app = str(ROOT / "Payload/Gboard.app")
        appex = str(ROOT / "Payload/Gboard.app/PlugIns/Gboard.appex")
        with mock.patch.object(inject, "_rpaths", return_value=["@executable_path/Frameworks"]):
            app_fw, _ = inject.resolve_app_frameworks_dir(app, "/dummy/Gboard")
        with mock.patch.object(inject, "_rpaths", return_value=["@executable_path/../../Frameworks"]):
            appex_fw, _ = inject.resolve_frameworks_dir(appex, "/dummy/Gboard")
        self.assertEqual(Path(app_fw), Path(appex_fw))


if __name__ == "__main__":
    unittest.main(verbosity=2)
