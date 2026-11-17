#!/usr/bin/env python3
"""「常用语」分页与主 App 维护入口的静态契约测试。

本机没有 clang，真机行为靠 GitHub Actions 编译后再验；这里锁住几条硬约束：
分页是叠加层不改原生布局、数据只存 App Group、未固定时点一条即关、固定后连续输入，
主 App 的维护入口是设置主菜单里的一行（不是导航栏按钮）。
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

    def test_settings_row_is_cloned_from_native_template(self) -> None:
        # 设置主菜单是 descriptor 驱动的；复制一条原生行（沿用 type/settingID）再换标题，
        # 避免硬塞未知的 type 枚举值导致崩溃。
        body = function_body(self.source, "static id GXKPhrasesSettingsRow(")
        self.assertIn("initWithType:settingID:title:accessibilityIdentifier:key:", body)
        self.assertIn("GKBSettingsItem", body)
        inject = function_body(self.source, "static void GXKInjectPhrasesRow(")
        self.assertIn("sections", inject)
        self.assertIn("setRows:", inject)
        self.assertIn("GXKSettingsRowIsOurs", inject)
        self.assertIn("GXKPhrasesRowTemplate", inject)

    def test_main_menu_descriptor_hook_injects_row(self) -> None:
        body = function_body(self.source, "static id gxk_settingsMainMenu(")
        self.assertIn("gOrigSettingsMainMenu", body)
        self.assertIn("GXKInjectPhrasesRow(", body)

    def test_row_tap_opens_editor(self) -> None:
        body = function_body(self.source, "static void gxk_settingsPageDidSelect(")
        self.assertIn("GXKIsPhrasesRowSelected", body)
        self.assertIn("GXKPresentPhrasesEditor(", body)
        # 非本行必须回落原生，绝不吞掉其他设置项。
        self.assertIn("gOrigSettingsPageDidSelect", body)
        # 认行的两条路：key 匹配 + 屏幕上那格显示「常用语」。
        picker = function_body(self.source, "static BOOL GXKIsPhrasesRowSelected(")
        self.assertIn("GXKSettingsRowIsOurs", picker)
        self.assertIn("GXKCellShowsPhrasesTitle", picker)
        cell = function_body(self.source, "static BOOL GXKViewShowsPhrasesTitle(")
        self.assertIn('@"常用语"', cell)
        self.assertIn("UILabel", cell)

    def test_editor_is_presented_not_pushed(self) -> None:
        # GOO 自绘导航容器里 push 出来的控制器会白屏，统一走全屏 modal。
        helper = function_body(self.source, "static void GXKPresentPhrasesEditor(")
        self.assertIn("GXKPhrasesEditorController", helper)
        self.assertIn("presentViewController:", helper)
        self.assertNotIn("pushViewController:", helper)
        self.assertIn("dismissable = YES", helper)

    def test_install_hooks_target_settings_classes(self) -> None:
        install = function_body(self.source, "static void GXKInstallMainAppHooks(")
        self.assertIn("mainMenuPageDescriptor", install)
        self.assertIn("collectionView:didSelectItemAtIndexPath:", install)
        self.assertIn("GKBSettingsViewController", install)
        self.assertIn("GKBSettingsPageViewController", install)
        # 导航栏按钮那条路已废弃（真机点开白屏）。
        self.assertNotIn("rightBarButtonItem", install)

    def test_keyboard_panel_keeps_edit_entry(self) -> None:
        edit = function_body(self.source, "- (void)onEdit:")
        self.assertIn("GXKPresentPhrasesEditor(", edit)
        init = function_body(self.source, "- (instancetype)initWithFrame:(CGRect)frame")
        self.assertIn("onEdit:", init)
        self.assertIn("GXK_PHRASES_EDIT_TAG", init)

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
