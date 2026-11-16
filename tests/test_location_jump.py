#!/usr/bin/env python3
"""地图分页定位跳转模块的静态契约测试。

本机没有 clang，真机行为只能靠 GitHub Actions 编译后再验；这里只锁住
「不改布局、不写死单一路径、通道级联、失败回落原生」这几条硬约束。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib" / "gkx.m"


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
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

    def test_opens_location_panel_not_search_settings(self) -> None:
        body = function_body(self.source, "static NSArray<NSString *> *GXKLocationURLStrings(void)")
        self.assertIn("prefs:root=Privacy&path=LOCATION", body)
        # 绝不把 Gboard 自己的搜索设置页当成目标。
        self.assertNotIn("searchSettingsURL", body)

    def test_channels_cascade_before_giving_up(self) -> None:
        body = function_body(self.source, "static BOOL GXKOpenLocationSettings(void)")
        for channel in ("GXKOpenViaExtensionContext", "GXKOpenViaFramework", "GXKOpenViaApplication"):
            self.assertIn(channel, body)
        # 三级都失败才 return NO，让调用方回落原生。
        self.assertIn("return NO;", body)

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
        # 新增失败才 setImplementation，避免直接改到父类实现。
        self.assertIn("method_setImplementation", body)

    def test_every_attempt_is_logged(self) -> None:
        body = function_body(self.source, "static BOOL GXKOpenLocationSettings(void)")
        self.assertGreaterEqual(body.count("GXK_LOG("), 2)


if __name__ == "__main__":
    unittest.main()
