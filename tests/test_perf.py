#!/usr/bin/env python3
"""性能改动源码契约：轮询必须走廉价路径，全树扫描不得留在定时器里。"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib/gkx.m"


def function_body(source: str, signature: str) -> str:
    """按大括号配对截取函数体，包含嵌套块。"""
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for i in range(brace, len(source)):
        ch = source[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    raise AssertionError(f"unbalanced braces for {signature}")


class PerfContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_timer_body_never_scans_full_tree(self):
        """定时器只在按需窗口内跑，且体内绝不做全树扫描。"""
        pump = function_body(self.source, "static void GXKBumpPolling(NSInteger ticks) {")
        self.assertIn("scheduledTimerWithTimeInterval", pump)
        body = pump[pump.index("scheduledTimerWithTimeInterval"):]
        self.assertNotIn("GXKFindNineKeyEmojiKey", body)
        self.assertNotIn("GXKComposingFullScan", body)
        self.assertIn("GXKUpdateActionKey(vc)", body)
        # 生命周期入口只抬计数，不直接建表；建表只在 GXKBumpPolling 里发生一次。
        appear = function_body(self.source, "static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKBumpPolling(GXK_POLL_BURST)", appear)
        self.assertNotIn("scheduledTimerWithTimeInterval", appear)

    def test_polling_stops_when_idle(self):
        """空闲必须停表：计数归零后 invalidate，隐藏时也停表。"""
        pump = function_body(self.source, "static void GXKBumpPolling(NSInteger ticks) {")
        self.assertIn("gPollTicks <= 0", pump)
        self.assertIn("GXKStopPolling()", pump)
        self.assertIn("gPollTicks--", pump)
        stop = function_body(self.source, "static void GXKStopPolling(void) {")
        self.assertIn("[gStatePollTimer invalidate]", stop)
        self.assertIn("gStatePollTimer = nil", stop)
        self.assertIn("gPollTicks = 0", stop)
        gone = function_body(self.source, "static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKStopPolling()", gone)
        # 旧的无条件常驻表必须消失，否则空闲仍每秒唤醒 5 次。
        self.assertNotIn("if (!gStatePollTimer) {", self.source)

    def test_update_has_cheap_path_before_full_scan(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        cheap = update.index("GXKComposingStateCached")
        full = update.index("GXKFindNineKeyEmojiKey(root)")
        self.assertLess(cheap, full, "cheap path must run before the full tree scan")
        head = update[:full]
        self.assertIn("gActionKeyButton.superview == gActionHost", head)
        self.assertIn("GXKKeyIsVisible(gEmojiSoftKeyView, root)", head)
        self.assertIn("GXKModelHasNativeActions(gActionSoftKeyDef)", head)

    def test_cheap_path_still_fails_closed(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        head = update[:update.index("GXKFindNineKeyEmojiKey(root)")]
        for required in (
            "gEmojiSoftKeyView &&",
            "gActionNativeIcon &&",
            "gActionSoftKeyDef &&",
            "gActionKeyButton &&",
            "gActionHost &&",
        ):
            self.assertIn(required, head)
        self.assertIn("GXKNativeIconForKey(gEmojiSoftKeyView) == gActionNativeIcon", head)
        self.assertIn("softKeyDef == gActionSoftKeyDef", head)

    def test_cheap_path_keeps_native_foreground_stripped(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        head = update[:update.index("GXKFindNineKeyEmojiKey(root)")]
        self.assertIn("cheapIcon.image = nil", head)
        self.assertIn("cheapIcon.highlightedImage = nil", head)
        self.assertIn("gActionNormalImage = cheapIcon.image", head)

    def test_composing_scan_is_event_driven_not_polled(self):
        self.assertIn("static void GXKRefreshComposingState(UIViewController *vc)", self.source)
        self.assertIn("static BOOL GXKComposingStateCached(UIViewController *vc)", self.source)
        refresh = function_body(self.source, "static void GXKRefreshComposingState(UIViewController *vc)")
        self.assertIn("GXKComposingFromProxy(vc)", refresh)
        self.assertIn("GXKComposingFullScan(vc)", refresh)
        cached = function_body(self.source, "static BOOL GXKComposingStateCached(UIViewController *vc)")
        self.assertNotIn("GXKComposingFullScan", cached)
        for hook in (
            "static void gkx_textDidChange(id self, SEL _cmd, id textInput)",
            "static void gkx_viewDidLayoutSubviews(id self, SEL _cmd)",
        ):
            body = function_body(self.source, hook)
            self.assertIn("GXKRefreshComposingState", body, hook)

    def test_dictionary_deploy_is_once_per_process(self):
        deploy = function_body(self.source, "static void GXKEnsureUserDictionaryDeployed(void)")
        first = deploy.index("gDictDeploySettled")
        self.assertLess(first, deploy.index("defaultManager"))
        self.assertIn("if (gDictDeploySettled) return;", deploy)
        self.assertGreaterEqual(deploy.count("gDictDeploySettled = YES"), 2)

    def test_haptics_are_reused_and_released(self):
        impact = function_body(self.source, "static void GXKImpact(UIImpactFeedbackStyle style)")
        self.assertIn("if (!gFbMedium)", impact)
        self.assertIn("if (!gFbLight)", impact)
        self.assertIn("[gFbMedium prepare]", impact)
        self.assertIn("[gFbLight prepare]", impact)
        self.assertEqual(impact.count("initWithStyle:"), 2, "generators must be created at most once each")
        tap = function_body(self.source, "- (void)onActionKeyTapped:(UIButton *)sender")
        self.assertNotIn("initWithStyle:", tap, "tap must not allocate a generator")
        release = function_body(self.source, "static void GXKReleaseHaptics(void)")
        self.assertIn("gFbMedium = nil", release)
        self.assertIn("gFbLight = nil", release)
        gone = function_body(self.source, "static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKReleaseHaptics()", gone)
        self.assertIn("gComposingActive = NO", gone)


if __name__ == "__main__":
    unittest.main(verbosity=2)
