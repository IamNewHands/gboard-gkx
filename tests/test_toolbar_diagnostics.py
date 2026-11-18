#!/usr/bin/env python3
"""Static diagnostic contracts; these do not execute UIKit or prove on-device behavior."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def function_body(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if not depth:
                return source[start:index + 1]
    raise AssertionError(f"unbalanced braces for {signature}")


class ToolbarDiagnosticContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main = (ROOT / "dylib/gkx.m").read_text(encoding="utf-8")
        cls.diag = (ROOT / "dylib/toolbar_diagnostics.h").read_text(encoding="utf-8")
        cls.code = re.sub(r"//[^\n]*", "", cls.diag)

    def body(self, name):
        return function_body(self.diag, name)

    def test_helper_is_included_after_style_before_toolbar_creation(self):
        include = self.main.index('#import "toolbar_diagnostics.h"')
        self.assertLess(self.main.index("static UIColor *GXKToolbarTextStyle"), include)
        self.assertLess(include, self.main.index("static UIStackView *GXKMakeToolbar"))

    def test_actual_style_selection_records_weak_source_without_new_scan(self):
        self.assertIn("static __weak UILabel *gToolbarStyleSource;", self.main)
        style = function_body(self.main, "static UIColor *GXKToolbarTextStyle")
        self.assertIn("if (outFont) { *outFont = nil; gToolbarStyleSource = nil; }", style)
        self.assertRegex(style, r"\*outFont = label\.font;\s*gToolbarStyleSource = label;")
        self.assertNotIn("GXKToolbarTextStyle(", self.code)

    def test_band_observer_precedes_clamp_without_changing_band_math(self):
        band = function_body(self.main, "static BOOL GXKToolbarBand(UIView")
        self.assertLess(band.index("GXKToolbarDiagnosticBandObserved"), band.index("if (top < 0.0)"))
        for expression in ("barHeight < 28.0", "barHeight > height", "right - left >= 200.0"):
            self.assertIn(expression, band)
        self.assertIn("gToolbarDiagnosticBandRow", self.diag)
        self.assertIn("usedValid=", self.diag)

    def test_used_geometry_requires_current_tree_binding_not_freshness(self):
        snapshot = self.body("static NSString *GXKToolbarDiagnosticSnapshot")
        for binding in ("root && row && logo", "logo.superview == row",
                        "row == root || [row isDescendantOfView:root]",
                        "row == gToolbarDiagnosticBandRow", "logo == gToolbarDiagnosticBandLogo"):
            self.assertIn(binding, snapshot)
        self.assertIn("NOT geometry freshness", self.diag)
        self.assertIn("Start/stop snapshots are immediate", self.diag)

    def test_only_copy_has_opt_in_gesture_and_began_is_single_action(self):
        make = function_body(self.main, "static UIStackView *GXKMakeToolbar")
        self.assertIn("if (i == 1)", make)
        self.assertIn("diagnostic.minimumPressDuration = 0.8;", make)
        self.assertIn("diagnostic.cancelsTouchesInView = YES;", make)
        handler = function_body(self.main, "- (void)onToolbarDiagnostic:(UILongPressGestureRecognizer *)gesture {")
        self.assertIn("gesture.state != UIGestureRecognizerStateBegan", handler)
        self.assertIn("vc != gCurrentVC", handler)
        self.assertIn("containsObject:button", handler)
        self.assertIn("GXKToolbarDiagnosticToggle", handler)

    def test_all_refresh_results_request_diagnostics(self):
        update = function_body(self.main, "static void GXKUpdateToolbar(UIViewController *vc) {")
        for reason in ("composing-hidden", "fast-unchanged", "scan-failed", "reuse-resampled", "new-resampled"):
            self.assertIn('@"' + reason + '"', update)

    def test_disabled_capture_returns_before_expensive_reads(self):
        request = self.body("static void GXKToolbarDiagnosticRequest")
        self.assertLess(request.index("!gToolbarDiagnosticActive"), request.index("GXKToolbarDiagnosticCapture"))
        capture = self.body("static void GXKToolbarDiagnosticCapture")
        self.assertLess(capture.index("!gToolbarDiagnosticActive"), capture.index("GXKToolbarDiagnosticSnapshot"))
        self.assertNotIn("NSTimer", self.code)
        self.assertNotIn("GXKComposingFullScan", self.code)

    def test_delayed_reads_are_coalesced_and_generation_guarded(self):
        request = self.body("static void GXKToolbarDiagnosticRequest")
        self.assertIn("if (gToolbarDiagnosticQueued) return;", request)
        self.assertIn("gToolbarDiagnosticPendingReasons |=", request)
        self.assertIn("gToolbarDiagnosticLastAt + GXK_DIAGNOSTIC_INTERVAL", request)
        self.assertIn("generation != gToolbarDiagnosticGeneration", request)
        self.assertIn("__weak UIViewController *weakVC", request)
        self.assertIn("dispatch_get_main_queue()", request)

    def test_samples_and_glyph_scan_have_explicit_bounds_and_coverage(self):
        for define in ("SECONDS 60.0", "INTERVAL 0.10", "MAX_SAMPLES 80", "MAX_CHARS 196608", "MAX_NODES 128"):
            self.assertIn("GXK_DIAGNOSTIC_" + define, self.diag)
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        self.assertIn("visited < GXK_DIAGNOSTIC_MAX_NODES", glyph)
        self.assertIn("pending.count >= GXK_DIAGNOSTIC_MAX_NODES", glyph)
        self.assertIn("images.count < 8", glyph)
        self.assertIn("truncated=%d", glyph)
        capture = self.body("static void GXKToolbarDiagnosticCapture")
        self.assertIn("isEqualToString:gToolbarDiagnosticLastSnapshot", capture)
        self.assertIn("gToolbarDiagnosticSamples.count > 1", capture)
        self.assertIn("removeObjectAtIndex:1", capture)
        self.assertIn("gToolbarDiagnosticChars + sample.length > GXK_DIAGNOSTIC_MAX_CHARS", capture)
        self.assertIn("gToolbarDiagnosticDropped++", capture)

    def test_report_does_not_read_user_content_or_persist(self):
        for forbidden in ("documentContext", "selectedText", "insertText:", "deleteBackward", ".text", "attributedText",
                          "accessibilityIdentifier", "NSUserDefaults", "NSFileManager", "NSURLSession", "NSLog"):
            self.assertNotIn(forbidden, self.code)
        self.assertEqual(1, self.code.count("[UIPasteboard generalPasteboard].string ="))
        stop = self.body("static void GXKToolbarDiagnosticStop")
        self.assertNotIn("UIPasteboard", stop)
        self.assertIn("gToolbarDiagnosticGeneration++", stop)

    def test_no_layout_or_font_writes_in_helper(self):
        for forbidden in ("layoutIfNeeded", "setNeedsLayout", "setFont:", "addSubview:", "constraintEqual", "presentViewController"):
            self.assertNotIn(forbidden, self.code)
        self.assertNotRegex(self.code, r"\.(?:frame|bounds|font|hidden|alpha|transform)\s*=")

    def test_reports_required_fields_without_claiming_effective_drawing_size(self):
        for field in ("selectedFont=", "sourceCurrentFont=", "sourceChain=", "buttonW=", "labelW=", "naturalFixed=",
                      "minScale=", "rowParent=", "unclampedTop=", "finalTop=", "freshBandDeltaY=", "imageSize="):
            self.assertIn(field, self.diag)
        self.assertIn("NOT actual auto-shrunk drawing size", self.diag)
        self.assertIn("NOT opaque image pixels", self.diag)

    def test_feedback_follows_baseline_and_timeout_never_auto_copies(self):
        toggle = self.body("static void GXKToolbarDiagnosticToggle")
        start = toggle[toggle.index("gToolbarDiagnosticSamples = [NSMutableArray array];"):]
        self.assertLess(start.index('GXKToolbarDiagnosticCapture(vc, @"start-before-feedback"'),
                        start.index('GXKFlashTitle(button, @"诊断")'))
        self.assertIn("gToolbarDiagnosticFeedbackUntil", start)
        timeout = start[start.index("GXK_DIAGNOSTIC_SECONDS * NSEC_PER_SEC"):]
        self.assertIn('@"timeout-60s"', timeout)
        self.assertNotIn("UIPasteboard", timeout)
        gone = function_body(self.main, "static void gkx_viewWillDisappear")
        self.assertLess(gone.index("GXKToolbarDiagnosticStop"), gone.index("gCurrentVC = nil"))

    def test_no_multiline_string_literals_or_unbalanced_delimiters(self):
        # Lexical guard catches accidental literal newlines from code-generation escaping.
        strings = re.findall(r'"(?:\\.|[^"\\])*"', self.code)
        self.assertTrue(strings)
        for literal in strings:
            self.assertNotIn("\n", literal)
        rest = re.sub(r'"(?:\\.|[^"\\])*"', '""', self.code)
        opens = []
        matching = {')': '(', ']': '[', '}': '{'}
        for char in rest:
            if char in "([{":
                opens.append(char)
            elif char in ")]}":
                self.assertTrue(opens, char)
                self.assertEqual(matching[char], opens.pop())
        self.assertFalse(opens)


if __name__ == "__main__":
    unittest.main()
