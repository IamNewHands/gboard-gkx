#!/usr/bin/env python3
"""地图分页定位链路的静态契约测试。

键盘扩展只被放行宿主 App 自己的 URL scheme，prefs: 与 App-Prefs: 会被沙盒静默拒绝，
所以键盘侧不做任何接管（还原原生「开启位置信息服务」），只有主 App 在中转被拉起后
弹一个「去系统设置」提示，再由用户点进 UIApplicationOpenSettingsURLString。
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

    def test_keyboard_side_keeps_native_behaviour(self) -> None:
        """键盘侧不改界面：不叠按钮、不接管跳转，只记一个时间戳。"""
        self.assertNotIn("GXKInstallLocationHooks", self.source)
        self.assertNotIn("GXKDetachLocationButton", self.source)
        self.assertNotIn("GXKAttachLocationJump", self.source)
        self.assertNotIn("GXK_LOCATION_BUTTON_TAG", self.source)
        self.assertNotIn("GXKOpenLocationSettings", self.source)
        self.assertNotIn("UIButton", function_body(self.source, "static void GXKInstallLocationStampHooks(void)"))

    def test_keyboard_side_stamps_intent_only(self) -> None:
        stamp = function_body(self.source, "static void GXKMarkLocationIntent(void)")
        self.assertIn("GXKLocationStampKey", stamp)
        self.assertIn("setDouble:", stamp)
        go = function_body(self.source, "static void gxk_locationStampGoToSettings(")
        self.assertIn("GXKMarkLocationIntent();", go)
        # 必须回落原生，绝不吞掉原行为。
        self.assertIn("gOrigLocationGoToSettingsStamp(self, _cmd, first, second);", go)
        appear = function_body(self.source, "static void gkx_viewWillAppear(")
        self.assertIn("GXKInstallLocationStampHooks();", appear)

    def test_relay_url_is_still_recognised(self) -> None:
        body = function_body(self.source, "static BOOL GXKIsLocationRelayURL(NSURL *url)")
        self.assertIn("x-gxk-location", body)
        self.assertIn("gboard", body)

    def test_main_app_only_opens_settings_page(self) -> None:
        body = function_body(self.source, "static BOOL GXKMainAppOpenSettingsPage(void)")
        self.assertIn("UIApplicationOpenSettingsURLString", body)
        # 第三方 App 调 prefs:/App-Prefs: 会被静默拒绝，绝不写进代码。
        self.assertNotIn("prefs:root=Privacy", body)
        self.assertNotIn("App-Prefs:root", body)
        self.assertIn("openURL:url options:", body)
        self.assertGreaterEqual(body.count("GXK_LOG("), 1)

    def test_relay_presents_choice_instead_of_jumping(self) -> None:
        """被中转拉起后先弹选项，不自动跳设置。"""
        body = function_body(self.source, "static void GXKPresentLocationSettingsAlert(void)")
        self.assertIn("UIAlertController", body)
        self.assertIn('@"去系统设置"', body)
        self.assertIn('@"取消"', body)
        self.assertIn("GXKMainAppOpenSettingsPage()", body)
        handler = function_body(self.source, "static BOOL gxk_applicationOpenURL(")
        self.assertIn("GXKPresentLocationSettingsAlert();", handler)
        self.assertNotIn("GXKMainAppOpenSettingsPage();", handler)

    def test_alert_is_presented_once_and_waits_for_window(self) -> None:
        body = function_body(self.source, "static void GXKPresentLocationSettingsAlert(void)")
        self.assertIn("if (shown) return;", body)
        self.assertIn("host.view.window", body)
        self.assertIn("dispatch_after", body)

    def test_top_controller_walks_presentation_chain(self) -> None:
        body = function_body(self.source, "static UIViewController *GXKTopViewController(void)")
        self.assertIn("presentedViewController", body)
        self.assertIn("UINavigationController", body)
        self.assertIn("UITabBarController", body)


if __name__ == "__main__":
    unittest.main()
