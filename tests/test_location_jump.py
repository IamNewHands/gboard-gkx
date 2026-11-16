#!/usr/bin/env python3
"""地图分页定位跳转（A 路线）的静态契约测试。

键盘扩展只被放行宿主 App 自己的 URL scheme，prefs: 与 App-Prefs: 会被沙盒拒绝，
所以键盘侧只发 gboard:// 中转，真正的设置跳转由主 App 代跑。这里锁住这条链路。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib" / "gkx.m"


def function_body(source: str, signature: str) -> str:
    """Locate a definition, skipping earlier forward declarations of the same name."""
    search = 0
    while True:
        start = source.index(signature, search)
        brace = source.index("{", start)
        semi = source.find(";", start, brace)
        if semi == -1:
            break  # 找到了函数定义，不是前置声明。
        search = semi + 1
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
    raise AssertionError("unbalanced braces after " + signature)


class LocationJumpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_module_is_wired_into_lifecycle(self) -> None:
        self.assertIn("GXKInstallLocationHooks();", self.source)
        appear = function_body(self.source, "static void gkx_viewWillAppear(")
        self.assertIn("GXKInstallLocationHooks();", appear)
        disappear = function_body(self.source, "static void gkx_viewWillDisappear(")
        self.assertIn("GXKDetachLocationButton();", disappear)

    def test_keyboard_side_only_sends_host_scheme(self) -> None:
        body = function_body(self.source, "static NSArray<NSString *> *GXKLocationURLStrings(void)")
        self.assertIn("gboard://x-gxk-location", body)
        # 键盘扩展里绝不直接开 prefs: —— 沙盒会拒绝，用户只会看到「点了没反应」。
        self.assertNotIn("@\"prefs:root=Privacy", body)
        self.assertNotIn("@\"App-Prefs:root", body)
        self.assertNotIn("searchSettingsURL", body)

    def test_main_app_relay_cascades_to_settings(self) -> None:
        body = function_body(self.source, "static BOOL GXKMainAppOpenLocationSettings(void)")
        self.assertIn("prefs:root=Privacy&path=LOCATION", body)
        self.assertIn("App-Prefs:root=Privacy&path=LOCATION", body)
        # 最后一级必须是本 App 设置页，保证 100% 能打开。
        self.assertIn("UIApplicationOpenSettingsURLString", body)
        self.assertIn("return NO;", body)

    def test_relay_url_is_recognised(self) -> None:
        body = function_body(self.source, "static BOOL GXKIsLocationRelayURL(NSURL *url)")
        self.assertIn("x-gxk-location", body)
        self.assertIn("gboard", body)

    def test_native_handlers_fall_back_when_jump_fails(self) -> None:
        go = function_body(self.source, "static void gxk_locationGoToSettings(")
        self.assertIn("gOrigLocationGoToSettings(self, _cmd, first, second);", go)
        tap = function_body(self.source, "static void gxk_locationPermissionTap(")
        self.assertIn("gOrigLocationPermissionTap(self, _cmd, first, second);", tap)

    def test_overlay_does_not_change_card_layout(self) -> None:
        body = function_body(self.source, "static void GXKAttachLocationJump(UIView *card)")
        self.assertNotIn("NSLayoutConstraint", body)
        self.assertNotIn("addConstraint", body)
        self.assertNotIn("sizeToFit", body)
        self.assertIn("UIViewAutoresizingNone", body)

    def test_override_never_pollutes_parent_class(self) -> None:
        body = function_body(self.source, "static void GXKOverrideOrSkip(")
        self.assertIn("class_addMethod", body)
        self.assertIn("method_setImplementation", body)

    def test_every_attempt_is_logged(self) -> None:
        body = function_body(self.source, "static BOOL GXKMainAppOpenLocationSettings(void)")
        self.assertGreaterEqual(body.count("GXK_LOG("), 2)


if __name__ == "__main__":
    unittest.main()
