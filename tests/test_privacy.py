#!/usr/bin/env python3
"""隐私改动源码契约：只掐 clearcut + Breakpad 上报，不碰翻译/YouTube/天气。"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib/gkx.m"

# 必须被拦截的（类, 选择器, IMP 后缀）；编码来自 dist/inspect-layout-20261114-013-encodings.txt
REQUIRED_BLOCKS = [
    ("CCTClearcutLogger", "log:", "gxk_noop_void_obj"),
    ("CCTClearcutLogger", "logWithExtension:", "gxk_noop_void_obj"),
    ("CCTClearcutLogger", "logCounters:", "gxk_noop_void_obj"),
    ("CCTClearcutUploader", "startAutoUpload", "gxk_noop_void"),
    ("CCTClearcutUploader", "startPeriodicUploadWithTimeInterval:", "gxk_noop_void_u64"),
    ("CCTClearcutUploader", "startPeriodicUploadWithTimeInterval:leeway:", "gxk_noop_void_u64_u64"),
    ("CCTClearcutUploader", "startAutoUploadOnBackground", "gxk_noop_void"),
    ("CCTClearcutUploader", "startAutoUploadOnForegroundWithDelay:", "gxk_noop_void_u64"),
    ("CCTClearcutUploader", "startCollectForDebugPeriodicUpload", "gxk_noop_void"),
    ("GKBClearcutUploader", "uploadClearcutLogs", "gxk_noop_void"),
    ("GKBClearcutUploader", "shouldUploadClearcutLogs", "gxk_noop_bool_no"),
    ("BreakpadController", "start:", "gxk_noop_void_bool"),
    ("BreakpadController", "sendStoredCrashReports", "gxk_noop_void"),
]

# 绝不能动的（动了会崩或卡住内部状态机）
FORBIDDEN_SELECTORS = [
    "crashIfNecessary",
    "crashIfMultipleUploadersInstantiated",
    "crashOnErrors",
    "newEvent",
    "uploadWithCompletionHandler:",
    "initSingleton",
    "GKBClearcutClient",
    "dealloc",
]

# 正常功能域名：隐私上报段里一个都不许出现（禁止按域名拦截）
FORBIDDEN_HOSTS = [
    "play.googleapis.com",
    "translation.googleapis.com",
    "youtube",
    "weather.com",
    "googleapis.com",
]

# 只有真正属于"URL/域名"的串才做全文禁止；"youtube" 是普通单词，
# G 图标分页裁剪需要按 mini app identifier 匹配它，那是另一件事。
FORBIDDEN_URLS_ANYWHERE = [
    "play.googleapis.com",
    "translation.googleapis.com",
    "weather.com",
    "googleapis.com",
]

PRIVACY_SECTION_START = "#pragma mark - 隐私上报拦截"
PRIVACY_SECTION_END = "#pragma mark - dylib 构造入口"


def function_body(source: str, signature: str) -> str:
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


class PrivacyContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.block = function_body(cls.source, "static void GXKDisableTelemetryUpload(void)")

    def test_every_required_upload_path_is_disabled_with_matching_encoding(self):
        for cls, sel, imp in REQUIRED_BLOCKS:
            pattern = (
                r'GXKDisableOne\(@"' + re.escape(cls) + r'",\s*@"' + re.escape(sel) + r'",\s*'
                r'\(IMP\)' + re.escape(imp) + r'\)'
            )
            self.assertRegex(self.block, pattern, f"{cls} {sel} must be blocked with {imp}")

    def test_no_forbidden_selector_is_touched(self):
        for sel in FORBIDDEN_SELECTORS:
            self.assertNotIn(sel, self.block, f"{sel} must never be replaced")

    def test_never_blocks_by_domain_or_url(self):
        stripped = re.sub(r"//[^\n]*", "", self.source)
        start = stripped.index(PRIVACY_SECTION_START)
        end = stripped.index(PRIVACY_SECTION_END)
        privacy = stripped[start:end]
        for host in FORBIDDEN_HOSTS:
            self.assertNotIn(host, privacy, f"must not filter by host: {host}")

    def test_no_url_is_referenced_anywhere(self):
        stripped = re.sub(r"//[^\n]*", "", self.source)
        for url in FORBIDDEN_URLS_ANYWHERE:
            self.assertNotIn(url, stripped, f"must not reference url anywhere: {url}")

    def test_failure_is_safe_when_class_or_method_missing(self):
        helper = function_body(self.source, "static void GXKDisableOne(NSString *className, NSString *selName, IMP imp)")
        self.assertIn("NSClassFromString(className)", helper)
        self.assertIn("class_getInstanceMethod(cls, sel)", helper)
        self.assertIn("if (!cls) return;", helper)
        self.assertIn("if (!m) return;", helper)
        self.assertIn("method_setImplementation(m, imp)", helper)

    def test_noop_imps_match_declared_encodings(self):
        expected = {
            "gxk_noop_void": "static void gxk_noop_void(id self, SEL _cmd) {",
            "gxk_noop_void_obj": "static void gxk_noop_void_obj(id self, SEL _cmd, id obj) {",
            "gxk_noop_void_bool": "static void gxk_noop_void_bool(id self, SEL _cmd, BOOL flag) {",
            "gxk_noop_void_u64": "static void gxk_noop_void_u64(id self, SEL _cmd, unsigned long long v) {",
            "gxk_noop_void_u64_u64": (
                "static void gxk_noop_void_u64_u64(id self, SEL _cmd, unsigned long long a, "
                "unsigned long long b) {"
            ),
            "gxk_noop_bool_no": "static BOOL gxk_noop_bool_no(id self, SEL _cmd) { return NO; }",
        }
        for name, signature in expected.items():
            self.assertIn(signature, self.source, name)

    def test_block_is_installed_from_init_and_is_idempotent(self):
        init = function_body(self.source, "static void gkx_init(void)")
        self.assertIn("GXKApplyTelemetryBlockIfNeeded()", init)
        apply = function_body(self.source, "static void GXKApplyTelemetryBlockIfNeeded(void) {")
        self.assertIn("static BOOL blocked = NO;", apply)
        self.assertIn("if (blocked) return;", apply)
        self.assertIn("blocked = YES;", apply)
        self.assertIn("GXKDisableTelemetryUpload()", apply)

    def test_clearcut_client_events_are_nooped_without_touching_readers(self):
        """GKBClearcutClient 的 log* 全置空，但有返回值的读方法必须保留。"""
        body = function_body(self.source, "static void GXKDisableClearcutClientEvents(void) {")
        # 只按名字前缀 log + 返回类型 v 两个条件筛选，不写死 78 条选择器。
        self.assertIn('strncmp(name, "log", 3) != 0', body)
        self.assertIn("types[0] != 'v'", body)
        self.assertIn("class_copyMethodList(cls, &total)", body)
        self.assertIn("method_setImplementation(methods[i], (IMP)gxk_noop_any)", body)
        self.assertIn("free(methods)", body)
        # 读方法/初始化/生命周期选择器绝不能出现在这个函数体里。
        for sel in ("isEnabled", "isRegexRule:", "featureFlagEventsForDailyLog",
                    "gboardExtensionWithTopLevelFields", "init", "dealloc"):
            self.assertNotIn(sel, body, f"{sel} must keep its implementation")
        # 通用空实现必须接受可变实参，否则 16 参的 logThemeAction... 会错位。
        self.assertIn("static void gxk_noop_any(id self, SEL _cmd, ...) {}", self.source)
        # 必须由幂等入口调用，否则装了也不生效。
        apply = function_body(self.source, "static void GXKApplyTelemetryBlockIfNeeded(void) {")
        self.assertIn("GXKDisableClearcutClientEvents()", apply)

    def test_blocking_does_not_touch_lifecycle_hooks(self):
        init = function_body(self.source, "static void gkx_init(void)")
        privacy_at = init.index("GXKApplyTelemetryBlockIfNeeded()")
        for hook in ("viewDidAppear:", "viewWillAppear:", "textDidChange:"):
            self.assertLess(init.index(hook), privacy_at, f"{hook} must be hooked before privacy block")


if __name__ == "__main__":
    unittest.main(verbosity=2)
