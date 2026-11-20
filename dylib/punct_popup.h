// [FEATURE-punct] 九键空格左侧「，。？」键：长按弹层 + 按住左右滑动选择。
//
// 为什么不走原生弹层：
//   该键绑定的 softkey_9keys_punctuation_candidates 定义里只有 label ",.;:" 与无障碍串，
//   没有 field3 候选表、也没有 popup_selector，原生 GKBPopupHandler 对这个键根本不建视图。
//   要让它弹层就得改打包后的 KeyDefinition 二进制，跨版本不可维护，故自绘。
//
// 为什么是「给这一格加长按手势」而不是覆盖 UIButton：
//   覆盖按钮会吃掉单击，而单击是原生的标点候选行为，自己实现必然走样。
//   手势识别失败（普通点击）时触摸原样下发给键，单击行为零改动；
//   只有长按被识别时才取消这一条触摸链，范围仅限这一格。
//   滑行输入发生在字母键上，这里不碰任何全局触摸回调，红线 2 不受影响。
//
// 性能：定位键只在 gkx_viewDidLayoutSubviews 的合并拍里做一次（每帧至多一次全树扫描），
//       弹层只有 10 个 UILabel，构建一次后复用；拖动只改背景色，不重建视图树。
#ifndef GXK_PUNCT_POPUP_H
#define GXK_PUNCT_POPUP_H

#define GXK_PUNCT_KEY_IDENT    @"key_pos_9keys_4_1"
#define GXK_PUNCT_HOLD_DELAY   0.32   // 长按判定阈值：低于原生 0.5s，手感更跟手
#define GXK_PUNCT_CELL_MAX     44.0   // 单格最大宽度，超出则整排按可用宽度均分
#define GXK_PUNCT_PANEL_HEIGHT 42.0
#define GXK_PUNCT_ASSOC_KEY    "gxk.punct.gesture"

// 视图引用一律 __weak：键盘根视图与键体由原生持有，这里绝不延长它们的生命周期（Jetsam 红线）。
static __weak UIView *gPunctKey;
static __weak UIView *gPunctRoot;
static UIView *gPunctPanel;
static NSArray<UILabel *> *gPunctCells;
static CGFloat gPunctCellWidth;
static NSInteger gPunctIndex;
static NSString *gPunctPreText;
static UILongPressGestureRecognizer *gPunctGesture;

// 候选顺序按中文输入的实际频次排：前几位最常用，滑到即中。
static NSArray<NSString *> *GXKPunctCandidates(void) {
    static NSArray<NSString *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[@"，", @"。", @"？", @"！", @"、", @"；", @"：", @"…", @"“", @"”"];
    });
    return list;
}

// 只认 key_pos_9keys_4_1 且必须挂在可见九键体上；出现两个可见同 id 就放弃，保持原生不猜。
static UIView *GXKPunctFindKey(UIView *root) {
    Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
    Class nineClass = GXKClassCached(@"GKB9KeysSoftKeyboardView", &gCachedNineKeyClass);
    if (!root || !root.window || !keyClass || !nineClass) return nil;
    UIView *candidate = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 1500) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.isHidden || v.alpha < 0.05 || v.window != root.window) continue;
        if ([v isKindOfClass:keyClass] &&
            [v.restorationIdentifier isEqualToString:GXK_PUNCT_KEY_IDENT] &&
            GXKNineKeyBodyForKey(v, root) && GXKKeyIsVisible(v, root)) {
            if (candidate && candidate != v) return nil; // 布局不确定：不动原生
            candidate = v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return stack.count ? nil : candidate;
}

static void GXKPunctHidePanel(void) {
    gPunctIndex = -1;
    gPunctPreText = nil;
    if (gPunctPanel) gPunctPanel.hidden = YES;
}

// 弹层只建一次：10 个 UILabel 常驻，显示/隐藏靠 hidden，避免每次长按都重建视图树。
static void GXKPunctBuildPanelIfNeeded(void) {
    if (gPunctPanel) return;
    NSArray<NSString *> *items = GXKPunctCandidates();
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [UIColor colorWithWhite:0.99 alpha:1.0];
    panel.layer.cornerRadius = 9.0;
    panel.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    panel.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.12].CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.16f;
    panel.layer.shadowRadius = 6.0;
    panel.layer.shadowOffset = CGSizeMake(0, 2);
    panel.clipsToBounds = NO;
    panel.hidden = YES;
    NSMutableArray<UILabel *> *cells = [NSMutableArray arrayWithCapacity:items.count];
    for (NSString *ch in items) {
        UILabel *cell = [[UILabel alloc] initWithFrame:CGRectZero];
        cell.text = ch;
        cell.font = [UIFont systemFontOfSize:20.0];
        cell.textColor = [UIColor darkTextColor];
        cell.textAlignment = NSTextAlignmentCenter;
        cell.layer.cornerRadius = 6.0;
        cell.clipsToBounds = YES;
        [panel addSubview:cell];
        [cells addObject:cell];
    }
    gPunctPanel = panel;
    gPunctCells = cells;
    gPunctIndex = -1;
}

static void GXKPunctHighlight(NSInteger index) {
    if (index == gPunctIndex) return;
    gPunctIndex = index;
    for (NSUInteger i = 0; i < gPunctCells.count; i++) {
        BOOL on = ((NSInteger)i == index);
        gPunctCells[i].backgroundColor = on ? [UIColor colorWithWhite:0.0 alpha:0.08] : [UIColor clearColor];
        gPunctCells[i].textColor = on ? [UIColor blackColor] : [UIColor darkTextColor];
    }
}

// 定位：整排贴在键正上方，越界就夹回宿主内；上方放不下改贴下方。
static void GXKPunctLayoutPanel(void) {
    if (!gPunctPanel || !gPunctKey || !gPunctRoot) return;
    NSUInteger n = gPunctCells.count;
    if (!n) return;
    CGRect keyRect = [gPunctKey convertRect:gPunctKey.bounds toView:gPunctRoot];
    CGFloat hostW = gPunctRoot.bounds.size.width;
    CGFloat cellW = MIN(GXK_PUNCT_CELL_MAX, floor(hostW / (CGFloat)n));
    if (cellW < 16.0) cellW = 16.0;
    gPunctCellWidth = cellW;
    CGFloat panelW = cellW * (CGFloat)n;
    CGFloat x = CGRectGetMidX(keyRect) - panelW / 2.0;
    x = MAX(0.0, MIN(x, MAX(0.0, hostW - panelW)));
    CGFloat y = CGRectGetMinY(keyRect) - GXK_PUNCT_PANEL_HEIGHT - 8.0;
    if (y < 0.0) y = CGRectGetMaxY(keyRect) + 8.0;
    gPunctPanel.frame = CGRectMake(x, y, panelW, GXK_PUNCT_PANEL_HEIGHT);
    for (NSUInteger i = 0; i < n; i++) {
        gPunctCells[i].frame = CGRectMake(cellW * (CGFloat)i, 0, cellW, GXK_PUNCT_PANEL_HEIGHT);
    }
}

static NSInteger GXKPunctIndexAtPoint(CGPoint point) {
    NSUInteger n = gPunctCells.count;
    if (!n || gPunctCellWidth <= 0.0) return -1;
    NSInteger idx = (NSInteger)floor(point.x / gPunctCellWidth);
    if (idx < 0) idx = 0;
    if (idx > (NSInteger)n - 1) idx = (NSInteger)n - 1;
    return idx;
}

static void GXKPunctCommit(NSInteger index) {
    NSArray<NSString *> *items = GXKPunctCandidates();
    if (index < 0 || index >= (NSInteger)items.count) return;
    NSString *ch = items[(NSUInteger)index];
    UIViewController *vc = gCurrentVC;
    if (!vc || ![vc isKindOfClass:[UIInputViewController class]]) return;
    id<UITextDocumentProxy> proxy = ((UIInputViewController *)vc).textDocumentProxy;
    if (!proxy) return;
    // 长按被识别时原生触摸链已取消，正常情况下宿主文本没变；
    // 但若原生仍然提交了一次标点，这里先撤掉它，避免叠字（只认「恰好追加一个字符」）。
    NSString *now = proxy.documentContextBeforeInput;
    if (![now isKindOfClass:[NSString class]]) now = @"";
    if (gPunctPreText && now.length == gPunctPreText.length + 1 && [now hasPrefix:gPunctPreText]) {
        [proxy deleteBackward];
    }
    [proxy insertText:ch];
    GXKImpact(UIImpactFeedbackStyleLight);
}

@interface GXKPunctGestureTarget : NSObject
- (void)onPunctLongPress:(UILongPressGestureRecognizer *)gr;
@end

@implementation GXKPunctGestureTarget
- (void)onPunctLongPress:(UILongPressGestureRecognizer *)gr {
    UIView *root = gPunctRoot;
    if (!root) { GXKPunctHidePanel(); return; }
    if (gr.state == UIGestureRecognizerStateBegan) {
        GXKPunctBuildPanelIfNeeded();
        if (gPunctPanel.superview != root) [root addSubview:gPunctPanel];
        GXKPunctLayoutPanel();
        gPunctPanel.hidden = NO;
        [root bringSubviewToFront:gPunctPanel];
        UIViewController *vc = gCurrentVC;
        if (vc && [vc isKindOfClass:[UIInputViewController class]]) {
            NSString *pre = ((UIInputViewController *)vc).textDocumentProxy.documentContextBeforeInput;
            gPunctPreText = [pre isKindOfClass:[NSString class]] ? pre : @"";
        } else {
            gPunctPreText = nil;
        }
        GXKPunctHighlight(GXKPunctIndexAtPoint([gr locationInView:gPunctPanel]));
        GXKImpact(UIImpactFeedbackStyleMedium);
        return;
    }
    if (gr.state == UIGestureRecognizerStateChanged) {
        if (gPunctPanel.hidden) return;
        GXKPunctHighlight(GXKPunctIndexAtPoint([gr locationInView:gPunctPanel]));
        return;
    }
    if (gr.state == UIGestureRecognizerStateEnded) {
        NSInteger index = gPunctIndex;
        GXKPunctHidePanel();
        GXKPunctCommit(index);
        return;
    }
    GXKPunctHidePanel(); // Cancelled / Failed：什么也不上屏
}
@end

static GXKPunctGestureTarget *gPunctTarget;

static void GXKPunctDetach(void) {
    GXKPunctHidePanel();
    if (gPunctGesture) {
        [gPunctGesture.view removeGestureRecognizer:gPunctGesture];
        gPunctGesture = nil;
    }
    if (gPunctKey) objc_setAssociatedObject(gPunctKey, GXK_PUNCT_ASSOC_KEY, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gPunctPanel.superview) [gPunctPanel removeFromSuperview];
    gPunctKey = nil;
    gPunctRoot = nil;
}

static void GXKPunctAttach(UIView *key, UIView *root) {
    if (!gPunctTarget) gPunctTarget = [[GXKPunctGestureTarget alloc] init];
    UILongPressGestureRecognizer *gr =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gPunctTarget
                                                      action:@selector(onPunctLongPress:)];
    gr.minimumPressDuration = GXK_PUNCT_HOLD_DELAY;
    gr.allowableMovement = 24.0;
    // 只有长按被识别才取消这一格的触摸链；普通点击时识别失败，触摸原样下发给键。
    gr.cancelsTouchesInView = YES;
    gr.delaysTouchesBegan = NO;
    gr.delaysTouchesEnded = NO;
    [key addGestureRecognizer:gr];
    objc_setAssociatedObject(key, GXK_PUNCT_ASSOC_KEY, gr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gPunctGesture = gr;
    gPunctKey = key;
    gPunctRoot = root;
}

// 布局拍里调用：至多一次全树定位，键没变时只做一次指针比较。
static void GXKPunctPopupUpdate(UIViewController *vc) {
    if (!vc || vc != gCurrentVC || !vc.isViewLoaded) return;
    UIView *root = vc.view;
    // 常数级快路径：上一帧的键仍然在同一次布局里、仍然可见、手势还在，就不扫全树。
    UIView *key = gPunctKey;
    if (key && gPunctRoot == root && key.window == root.window && !key.isHidden && key.alpha > 0.05 &&
        [key.restorationIdentifier isEqualToString:GXK_PUNCT_KEY_IDENT] &&
        [key isDescendantOfView:root] && GXKKeyIsVisible(key, root) &&
        objc_getAssociatedObject(key, GXK_PUNCT_ASSOC_KEY)) {
        if (gPunctPanel && gPunctPanel.superview != root) [root addSubview:gPunctPanel];
        // 弹层正显示时键盘可能因旋转/高度变化重排，跟着键走一次；隐藏时零成本。
        if (gPunctPanel && !gPunctPanel.hidden) {
            GXKPunctLayoutPanel();
            [root bringSubviewToFront:gPunctPanel];
        }
        return;
    }
    UIView *found = GXKPunctFindKey(root);
    if (!found) { GXKPunctDetach(); return; }
    GXKPunctDetach();
    GXKPunctAttach(found, root);
    if (gPunctPanel && gPunctPanel.superview != root) [root addSubview:gPunctPanel];
}

static void GXKPunctPopupTeardown(void) {
    GXKPunctDetach();
}

#endif  // GXK_PUNCT_POPUP_H
