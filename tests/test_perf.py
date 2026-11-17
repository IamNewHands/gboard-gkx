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

    def test_view_kind_cache_avoids_per_node_class_strings(self):
        """类名判定必须按类指针缓存，不能在每个节点上重新拼字符串。"""
        cache = function_body(self.source, "static NSInteger GXKViewKind(UIView *view) {")
        self.assertIn("gViewKindCache", cache)
        self.assertIn("NSValue valueWithPointer", cache)
        self.assertIn("NSStringFromClass", cache)
        # 缓存命中必须提前返回，否则缓存没有意义。
        self.assertLess(cache.index("if (cached) return cached.integerValue;"),
                        cache.index("NSStringFromClass"))
        scan = function_body(self.source, "static BOOL GXKComposingFullScan(UIViewController *vc) {")
        self.assertIn("GXKViewKind(v)", scan)
        self.assertNotIn("NSStringFromClass", scan, "scan must not format class names per node")
        self.assertNotIn("containsString:@\"Composing\"", scan)

    def test_composing_scan_is_throttled_with_trailing_pass(self):
        """全树扫描必须节流，且被跳过的那次要有尾随扫描兜住状态。"""
        self.assertIn("#define GXK_COMPOSING_SCAN_MIN_INTERVAL 0.25", self.source)
        refresh = function_body(self.source, "static void GXKRefreshComposingState(UIViewController *vc)")
        self.assertIn("CFAbsoluteTimeGetCurrent()", refresh)
        self.assertIn("GXK_COMPOSING_SCAN_MIN_INTERVAL", refresh)
        self.assertIn("GXKScheduleComposingScan()", refresh)
        # 代理已明确有 mark 时仍然走 O(1) 路径，不受节流影响。
        self.assertLess(refresh.index("GXKComposingFromProxy(vc)"),
                        refresh.index("CFAbsoluteTimeGetCurrent()"))
        trailing = function_body(self.source, "static void GXKScheduleComposingScan(void) {")
        self.assertIn("dispatch_after", trailing)
        self.assertIn("gComposingScanScheduled", trailing)
        self.assertIn("GXKComposingFullScan(vc)", trailing)
        # 状态没翻转时不得触发界面刷新。
        self.assertIn("if (composing == gComposingActive) return;", trailing)

    def test_plain_typing_uses_short_settle_window(self):
        """普通打字只补两帧；只有组字状态翻转才拉起完整补帧窗口。"""
        self.assertIn("#define GXK_POLL_BURST 5", self.source)
        self.assertIn("#define GXK_POLL_SETTLE 2", self.source)
        typed = function_body(self.source, "static void gkx_textDidChange(id self, SEL _cmd, id textInput)")
        self.assertIn("BOOL wasComposing = gComposingActive;", typed)
        self.assertIn("GXKBumpPolling((wasComposing != gComposingActive) ? GXK_POLL_BURST : GXK_POLL_SETTLE);", typed)

    def test_toolbar_decorations_scanned_once_per_band(self):
        """同一 band 只扫一次装饰，没东西可藏时不再每拍重走 800 节点。"""
        self.assertIn("static BOOL gToolbarDecorationsScanned;", self.source)
        self.assertIn("static CGRect gToolbarDecorationsBand;", self.source)
        sync = function_body(self.source, "static void GXKSyncToolbarDecorations(BOOL composing) {")
        self.assertIn("gToolbarDecorationsScanned", sync)
        self.assertIn("CGRectEqualToRect(gToolbarDecorationsBand, gToolbarBand)", sync)
        self.assertIn("gToolbarDecorationsBand = gToolbarBand;", sync)
        # 归还装饰时必须清掉扫描备忘，否则下次挂载会漏扫。
        restore = function_body(self.source, "static void GXKRestoreToolbarDecorations(void) {")
        self.assertIn("gToolbarDecorationsScanned = NO;", restore)

    def test_toolbar_reuses_stack_and_constraints(self):
        """同一宿主行复用 stack 与按钮，约束先撤后加，不层层叠加。"""
        self.assertIn("static NSArray<NSLayoutConstraint *> *gToolbarConstraints;", self.source)
        update = function_body(self.source, "static void GXKUpdateToolbar(UIViewController *vc) {")
        self.assertIn("BOOL reuse = (gToolbarStack && gToolbarRow == row", update)
        self.assertIn("UIStackView *stack = reuse ? gToolbarStack : GXKMakeToolbar(row, tint, surface);", update)
        self.assertIn("deactivateConstraints:gToolbarConstraints", update)
        self.assertIn("activateConstraints:gToolbarConstraints", update)
        # 重建路径必须先撤掉旧约束；两条路径都不得漏掉旧约束。
        # 扫描失败分支更早就会 GXKDetachToolbar()，这里只看复用判定之后那一次。
        self.assertLess(update.index("BOOL reuse ="),
                        update.index("GXKDetachToolbar();", update.index("BOOL reuse =")))
        detach = function_body(self.source, "static void GXKDetachToolbar(void) {")
        self.assertIn("deactivateConstraints:gToolbarConstraints", detach)
        self.assertIn("gToolbarConstraints = nil;", detach)


if __name__ == "__main__":
    unittest.main(verbosity=2)
