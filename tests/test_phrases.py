#!/usr/bin/env python3
"""「常用语」分页与主 App 维护入口的静态契约测试。

本机没有 clang，真机行为靠 GitHub Actions 编译后再验；这里锁住几条硬约束：
分页是叠加层不改原生布局、数据只存 App Group、未固定时点一条即关、固定后连续输入。
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


class PhrasesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_wired_into_lifecycle(self) -> None:
        appear = function_body(self.source, "static void gkx_viewWillAppear(")
        self.assertIn("GXKInstallPhrasesHooks();", appear)
        self.assertIn("GXKInstallMainAppHooks();", appear)
        disappear = function_body(self.source, "static void gkx_viewWillDisappear(")
        self.assertIn("GXKDetachPhrasesPanel();", disappear)

    def test_picker_item_is_appended_once(self) -> None:
        body = function_body(self.source, "static id gxk_availablePickerItems(")
        self.assertIn("GXKPhrasesPickerItem()", body)
        self.assertIn("hasPhrases", body)

    def test_picker_selection_is_intercepted(self) -> None:
        body = function_body(self.source,
                             "static void gxk_miniAppPickerDidSelect(")
        self.assertIn("GXK_PHRASES_IDENTIFIER", body)
        self.assertIn("GXKShowPhrasesPanel", body)
        self.assertIn("gOrigMiniAppPickerDidSelect", body)

    def test_panel_is_overlay_without_layout_constraints(self) -> None:
        body = function_body(self.source, "static void GXKShowPhrasesPanel(")
        self.assertNotIn("NSLayoutConstraint", body)
        self.assertNotIn("addConstraint", body)
        self.assertIn("vc.view.bounds", body)
        self.assertIn("bringSubviewToFront", body)

    def test_phrase_inserts_via_document_proxy(self) -> None:
        body = function_body(self.source, "static void GXKInsertPhraseText(")
        self.assertIn("insertText:", body)
        proxy = function_body(self.source, "static id GXKKeyboardProxy(")
        self.assertIn("textDocumentProxy", proxy)

    def test_unpinned_tap_closes_panel(self) -> None:
        body = function_body(self.source, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
        self.assertIn("GXKPhrasesPinned()", body)
        self.assertIn("dismissPanel", body)

    def test_storage_uses_app_group_suite(self) -> None:
        body = function_body(self.source, "static NSUserDefaults *GXKPhraseDefaults(")
        self.assertIn("initWithSuiteName:GXKGroup", body)
        self.assertIn("standardUserDefaults", body)

    def test_main_app_editor_entry_exists(self) -> None:
        # 导航项挂在真正上屏的 page VC 上：helper 负责建按钮，两处 hook 都走它。
        body = function_body(self.source, "static void GXKAttachPhrasesEntry(")
        self.assertIn("rightBarButtonItem", body)
        self.assertIn("onOpenPhrasesEditor:", body)
        container = function_body(self.source, "static void gxk_settingsViewDidLoad(")
        self.assertIn("GXKAttachPhrasesEntry(", container)
        page = function_body(self.source, "static void gxk_settingsPageViewDidAppear(")
        self.assertIn("GXKAttachPhrasesEntry(", page)
        self.assertIn("gOrigSettingsPageViewDidAppear", page)
        push = function_body(self.source, "- (void)onOpenPhrasesEditor:")
        self.assertIn("GXKPresentPhrasesEditor(", push)
        helper = function_body(self.source, "static void GXKPresentPhrasesEditor(")
        self.assertIn("GXKPhrasesEditorController", helper)
        self.assertIn("presentViewController:", helper)
        # 键盘内兜底入口：面板自己带「编辑」，不依赖主 App 设置页。
        edit = function_body(self.source, "- (void)onEdit:")
        self.assertIn("GXKPresentPhrasesEditor(", edit)
        init = function_body(self.source, "- (instancetype)initWithFrame:(CGRect)frame")
        self.assertIn("onEdit:", init)
        self.assertIn("GXK_PHRASES_EDIT_TAG", init)
        install = function_body(self.source, "static void GXKInstallMainAppHooks(")
        self.assertIn("AppDelegate", install)
        self.assertIn("GKBSettingsViewController", install)
        self.assertIn("GKBSettingsPageViewController", install)

    def test_main_app_hooks_install_from_constructor(self) -> None:
        # 主 App 进程没有键盘控制器，viewWillAppear 那套接线永远不触发。
        body = function_body(self.source, "static void gkx_init(void)")
        self.assertIn("GXKInstallMainAppHooks();", body)

    def test_editor_supports_add_and_delete(self) -> None:
        self.assertIn("commitEditingStyle:", self.source)
        self.assertIn("onAdd:", self.source)
        self.assertIn("GXKPhraseSave(", self.source)


if __name__ == "__main__":
    unittest.main()
