#!/usr/bin/env python3
"""定位跳转功能已被整体移除的回归契约。

需求（2026-11-17）：跳转系统定位设置这条路不符合预期，全部代码删除，键盘与主 App
都回到原生行为。这里锁住"删干净"，避免后续改动把它又带回来。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib" / "gkx.m"


class LocationRemovedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_no_location_hook_symbols_remain(self) -> None:
        for symbol in (
            "GXKInstallLocationHooks",
            "GXKDetachLocationButton",
            "GXKAttachLocationJump",
            "GXKOpenLocationSettings",
            "GXKInstallLocationStampHooks",
            "GXKMarkLocationIntent",
            "GXKLocationStampKey",
            "GXKPresentLocationSettingsAlert",
            "GXKConsumeLocationIntent",
            "GXKIsLocationRelayURL",
            "GXKMainAppOpenSettingsPage",
            "GXKTopViewController",
            "GXK_LOCATION_BUTTON_TAG",
        ):
            self.assertNotIn(symbol, self.source)

    def test_no_settings_url_or_private_scheme(self) -> None:
        # prefs: 对第三方 App 与键盘扩展一律被系统静默拒绝；UIApplicationOpenSettingsURLString
        # 属于同一个被否决的方案，一并删掉。
        self.assertNotIn("prefs:root=Privacy", self.source)
        self.assertNotIn("App-Prefs:root", self.source)
        self.assertNotIn("UIApplicationOpenSettingsURLString", self.source)
        self.assertNotIn("x-gxk-location", self.source)

    def test_main_app_hooks_only_handle_phrases(self) -> None:
        # 前向声明在前面出现过，取最后一次出现才是定义。
        start = self.source.rindex("static void GXKInstallMainAppHooks(")
        body = self.source[start:start + 900]
        self.assertNotIn("AppDelegate", body)
        self.assertNotIn("applicationDidBecomeActive", body)
        self.assertIn("GKBSettingsViewController", body)


if __name__ == "__main__":
    unittest.main()
