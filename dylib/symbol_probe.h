// [DEBUG-symbol] Read-only probe for the 9-key symbol page. v3.
//
// v1 crashed the keyboard extension when the long press ran. The cause was the key dump:
// it read native properties (softKeyDef / idToViewDict / actionsArray) through unretained
// casts and asked foreign objects for -description, which can run arbitrary native code.
// v3 removes every such read. What remains is:
//   - a bounded ring buffer that is always recording (200 lines), written from hooks only
//   - three swizzled layout selectors, restricted to GKB*/UIKeyboard*/TIKeyboard* owners,
//     each forwarding to its original IMP and logging class + selector + argument class
//   - a layout fingerprint built only from -restorationIdentifier and class names
//   - long press #1 marks a position (title 诊断), long press #2 copies the ring (title 已复制)
// Nothing in the long-press handler touches keyboard internals, so it cannot crash there.
#ifndef GXK_SYMBOL_PROBE_H
#define GXK_SYMBOL_PROBE_H

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define GXK_PROBE_RING 800
#define GXK_PROBE_MAX_LINE 600
#define GXK_PROBE_MAX_KEYS 40
#define GXK_PROBE_MAX_CELLS 12
#define GXK_PROBE_STACK 5
#define GXK_PROBE_MIN_GAP 0.10

static NSMutableArray<NSString *> *gProbeRing;
static BOOL gProbeMarked;
static NSTimeInterval gProbeStartedAt;
static NSString *gProbeLastFingerprint;
static NSTimeInterval gProbeLastFingerprintAt;
static NSMutableDictionary<NSString *, NSValue *> *gProbeOrigs;
static BOOL gProbeHooksInstalled;
static __weak UIButton *gProbeAttachedButton;

static NSObject *GXKProbeLock(void) {
    static NSObject *token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ token = [[NSObject alloc] init]; });
    return token;
}

static NSTimeInterval GXKProbeNow(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static NSString *GXKProbeClip(NSString *text, NSUInteger limit) {
    if (![text isKindOfClass:[NSString class]]) return @"?";
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"..."];
}

// Only the class name is ever read from a foreign object: -description can execute
// arbitrary native code and is not safe on private keyboard internals.
static NSString *GXKProbeClassName(id object) {
    if (!object) return @"nil";
    Class cls = object_getClass(object);
    if (!cls) return @"nil";
    const char *name = class_getName(cls);
    return name ? [NSString stringWithUTF8String:name] : @"?";
}

static NSString *GXKProbeStack(void) {
    NSArray<NSString *> *frames = [NSThread callStackSymbols];
    if (![frames isKindOfClass:[NSArray class]] || frames.count <= 2) return @"none";
    NSUInteger end = MIN(frames.count, (NSUInteger)(GXK_PROBE_STACK + 2));
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSUInteger i = 2; i < end; i++) {
        NSString *frame = frames[i];
        if ([frame isKindOfClass:[NSString class]]) [kept addObject:GXKProbeClip(frame, 90)];
    }
    return [kept componentsJoinedByString:@" | "];
}

static void GXKProbeLog(NSString *tag, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

static void GXKProbeLog(NSString *tag, NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!body) return;
    if (body.length > GXK_PROBE_MAX_LINE) body = GXKProbeClip(body, GXK_PROBE_MAX_LINE);
    NSString *line = [NSString stringWithFormat:@"t=%.3f [%@] %@\n",
                      GXKProbeNow() - gProbeStartedAt, tag, body];
    // Nothing is recorded until the user marks a probe: an idle keyboard pays no cost.
    if (!gProbeMarked) return;
    @synchronized(GXKProbeLock()) {
        if (!gProbeRing) gProbeRing = [NSMutableArray array];
        [gProbeRing addObject:line];
        while (gProbeRing.count > GXK_PROBE_RING) [gProbeRing removeObjectAtIndex:0];
    }
}

static UIView *GXKProbeNineKeyBody(UIView *root) {
    if (![root isKindOfClass:[UIView class]]) return nil;
    Class nineClass = NSClassFromString(@"GKB9KeysSoftKeyboardView");
    if (!nineClass) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 3000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:nineClass] && !view.isHidden && view.alpha >= 0.05 &&
            !CGRectIsEmpty(view.bounds)) {
            return view;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Fingerprint and key inventory read only -restorationIdentifier and class names.
static NSString *GXKProbeKeyLine(UIView *view) {
    NSString *ident = view.restorationIdentifier;
    if (![ident isKindOfClass:[NSString class]] || !ident.length) return nil;
    return [NSString stringWithFormat:@"%@:%@", ident, GXKProbeClassName(view)];
}

static void GXKProbeDumpSymbols(NSString *reason, UIView *root);
static void GXKProbeDumpCollections(NSString *reason, UIView *root);
static void GXKProbeAttachSymbolTap(UIView *root);
static UIView *GXKProbeSymbolHost(UIView *root);
static BOOL gProbeWasOnSymbols;
static NSString *gProbeLastWindow;
static NSTimeInterval gProbeLastLayoutAt;

static void GXKProbeNoteLayout(NSString *reason) {
    if (!gProbeMarked) return;
    UIViewController *vc = gCurrentVC;
    if (!vc || !vc.isViewLoaded) return;
    NSTimeInterval now = GXKProbeNow();
    if (now - gProbeLastFingerprintAt < GXK_PROBE_MIN_GAP) return;
    gProbeLastFingerprintAt = now;
    UIView *body = GXKProbeNineKeyBody(vc.view);
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (body) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
        NSUInteger visited = 0;
        while (stack.count && visited++ < 3000 && keys.count < GXK_PROBE_MAX_KEYS) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            NSString *line = view.isHidden ? nil : GXKProbeKeyLine(view);
            if (line) [keys addObject:line];
            [stack addObjectsFromArray:view.subviews];
        }
    }
    // Page flips are checked BEFORE the fingerprint gate: in v7 that gate returned
    // early on every exit, so only the very first "-> symbols" was ever recorded.
    UIView *symbolHost = GXKProbeSymbolHost(vc.view);
    BOOL onSymbols = symbolHost != nil;
    if (onSymbols != gProbeWasOnSymbols) {
        gProbeWasOnSymbols = onSymbols;
        GXKProbeLog(@"page", @"%@ -> %@ stack=%@", onSymbols ? @"symbols" : @"keys",
                    reason, GXKProbeStack());
    }
    NSString *fingerprint = body ? [keys componentsJoinedByString:@","] : @"no-nine-key-body";
    if ([fingerprint isEqualToString:gProbeLastFingerprint ?: @""]) {
        if (onSymbols) GXKProbeAttachSymbolTap(vc.view);
        return;
    }
    // v9: how long the previous layout stood. The auto-return-to-pinyin happens after
    // an idle beat, so the gap between two layout changes is the timing evidence.
    NSTimeInterval gap = gProbeLastLayoutAt > 0 ? now - gProbeLastLayoutAt : 0;
    gProbeLastLayoutAt = now;
    gProbeLastFingerprint = fingerprint;
    GXKProbeLog(@"layout", @"%@ gap=%.2fs body=%@ keys=%@", reason, gap, GXKProbeClassName(body),
                GXKProbeClip(fingerprint, 300));
    // Logged before the symbol dump: the collection list is what distinguishes
    // "symbol page emptied" from "another collection took the slot".
    GXKProbeDumpCollections(reason, vc.view);
    if (onSymbols) {
        GXKProbeDumpSymbols(reason, vc.view);
        GXKProbeAttachSymbolTap(vc.view);
    }
}

// ---- v4: symbol page inventory (public UIKit only) ----

static UIView *GXKProbeSymbolHost(UIView *root);

static NSString *GXKProbeRect(CGRect rect, UIView *root) {
    return [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

// The symbol page is one GKBSoftKeyCollectionView identified by restorationIdentifier
// "key_pos_9keys_symbols"; its cells are GKBMinimizedLabelWithBackgroundImage.
// v9: the v8 rule ("any GKBSoftKeyCollectionView") also matched the number/123 page,
// so a page that merely lost the symbol slot looked like a symbol page with 12 cells.
// The slot is now identified ONLY by its restorationIdentifier, or by sitting inside a
// subtree that carries it: a named ancestor means the collection was re-sourced in place.
static UIView *GXKProbeSymbolHost(UIView *root) {
    if (![root isKindOfClass:[UIView class]]) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 3000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        NSString *ident = view.restorationIdentifier;
        BOOL named = [ident isKindOfClass:[NSString class]] &&
                     [ident isEqualToString:@"key_pos_9keys_symbols"];
        if (named && !view.isHidden && !CGRectIsEmpty(view.bounds)) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Every soft-key collection in the tree, named or not: this is what tells the 12-cell
// page apart from a symbol page that was actually emptied or re-sourced.
static void GXKProbeDumpCollections(NSString *reason, UIView *root) {
    Class collectionClass = NSClassFromString(@"GKBSoftKeyCollectionView");
    if (!collectionClass) {
        GXKProbeLog(@"collections", @"%@ class=none", reason);
        return;
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    NSUInteger found = 0;
    while (stack.count && visited++ < 3000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:collectionClass]) {
            found++;
            NSMutableString *line = [NSMutableString stringWithFormat:@"n=%lu ident=%@ frame=%@ h=%d a=%.2f",
                                     (unsigned long)found,
                                     view.restorationIdentifier ?: @"-",
                                     GXKProbeRect([view convertRect:view.bounds toView:root], root),
                                     view.isHidden, view.alpha];
            if ([view isKindOfClass:[UIScrollView class]]) {
                UIScrollView *scroll = (UIScrollView *)view;
                [line appendFormat:@" offset=%.0f,%.0f size=%.0f,%.0f",
                 scroll.contentOffset.x, scroll.contentOffset.y,
                 scroll.contentSize.width, scroll.contentSize.height];
            }
            if ([view isKindOfClass:[UICollectionView class]]) {
                UICollectionView *collection = (UICollectionView *)view;
                NSInteger sections = [collection numberOfSections];
                NSInteger items = 0;
                for (NSInteger s = 0; s < sections; s++) items += [collection numberOfItemsInSection:s];
                [line appendFormat:@" cells=%ld vis=%lu", (long)items,
                 (unsigned long)collection.visibleCells.count];
            }
            GXKProbeLog(@"collections", @"%@ %@", reason, line);
        }
        [stack addObjectsFromArray:view.subviews];
    }
    if (!found) GXKProbeLog(@"collections", @"%@ none", reason);
}

// The glyph and its pair sit on separate layers, so a one-level scan finds nothing.
static void GXKProbeCollectLabels(UIView *view, UIView *root, NSMutableArray<NSString *> *out,
                                  NSUInteger depth) {
    if (!out || depth > 3 || out.count >= 8) return;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)child;
            [out addObject:[NSString stringWithFormat:@"'%@'|%@|h=%d|%@",
                            label.text ?: @"",
                            GXKProbeRect([label convertRect:label.bounds toView:root], root),
                            label.isHidden, label.font.fontName]];
        } else {
            GXKProbeCollectLabels(child, root, out, depth + 1);
        }
    }
}

// Every label text and frame on the symbol page, ordered by collection index: this is
// what the double-tap lock has to reason about, and none of it needs a private accessor.
static void GXKProbeDumpSymbols(NSString *reason, UIView *root) {
    UIView *host = GXKProbeSymbolHost(root);
    if (!host) {
        GXKProbeLog(@"symbols", @"%@ host=none", reason);
        return;
    }
    NSMutableString *head = [NSMutableString stringWithFormat:@"%@ host=%@ frame=%@",
                             reason, GXKProbeClassName(host),
                             GXKProbeRect([host convertRect:host.bounds toView:root], root)];
    if ([host isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)host;
        [head appendFormat:@" offset=%.0f,%.0f size=%.0f,%.0f",
         scroll.contentOffset.x, scroll.contentOffset.y,
         scroll.contentSize.width, scroll.contentSize.height];
    }
    if ([host isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collection = (UICollectionView *)host;
        NSInteger sections = [collection numberOfSections];
        NSInteger items = 0;
        for (NSInteger s = 0; s < sections; s++) items += [collection numberOfItemsInSection:s];
        [head appendFormat:@" cells=%ld", (long)items];
    }
    GXKProbeLog(@"symbols", @"%@", head);
    // Cells are emitted by collection index, never by visibleCells order: the index is
    // the only stable key the double-tap lock can hold on to.
    NSMutableArray<NSIndexPath *> *indexes = [NSMutableArray array];
    if ([host isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collection = (UICollectionView *)host;
        for (UICollectionViewCell *cell in collection.visibleCells) {
            NSIndexPath *path = [collection indexPathForCell:cell];
            if (path) [indexes addObject:path];
        }
        [indexes sortUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
            if (a.item == b.item) return NSOrderedSame;
            return a.item < b.item ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    // Only emit cells when the visible window changed: 14 dumps x 24 cells used to
    // flush the ring and evict the page-transition lines.
    NSString *window = [NSString stringWithFormat:@"%ld/%lu",
                        (long)(indexes.count ? indexes.firstObject.item : -1),
                        (unsigned long)indexes.count];
    if ([window isEqualToString:gProbeLastWindow ?: @""]) return;
    gProbeLastWindow = window;
    NSUInteger emitted = 0;
    for (NSIndexPath *path in indexes) {
        if (emitted++ >= GXK_PROBE_MAX_CELLS) break;
        UICollectionViewCell *cell = [((UICollectionView *)host) cellForItemAtIndexPath:path];
        if (!cell) continue;
        NSMutableString *line = [NSMutableString stringWithFormat:@"i=%ld frame=%@",
                                 (long)path.item,
                                 GXKProbeRect([cell convertRect:cell.bounds toView:root], root)];
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        GXKProbeCollectLabels(cell, root, labels, 0);
        [line appendFormat:@" labels=[%@]", [labels componentsJoinedByString:@";"]];
        GXKProbeLog(@"symbols", @"%@", line);
    }
}

// One tap on the symbol page: which cell, which label text, where. This is the
// evidence the double-tap lock needs; it reads no private property.
@interface GXKProbeSymbolTap : NSObject
- (void)onSymbolTap:(UITapGestureRecognizer *)gesture;
@end

@implementation GXKProbeSymbolTap
- (void)onSymbolTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    UIView *host = gesture.view;
    if (![host isKindOfClass:[UIView class]]) return;
    CGPoint point = [gesture locationInView:host];
    NSMutableString *line = [NSMutableString stringWithFormat:@"at=%.0f,%.0f", point.x, point.y];
    if ([host isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collection = (UICollectionView *)host;
        // hitTest: on the collection itself returns nil (it forwards through its own
        // gesture pipeline), so resolve the cell from the point instead.
        NSIndexPath *path = [collection indexPathForItemAtPoint:point];
        [line appendFormat:@" i=%ld", (long)(path ? path.item : -1)];
        UICollectionViewCell *cell = path ? [collection cellForItemAtIndexPath:path] : nil;
        if (cell) {
            NSMutableArray<NSString *> *labels = [NSMutableArray array];
            GXKProbeCollectLabels(cell, collection, labels, 0);
            [line appendFormat:@" labels=[%@]", [labels componentsJoinedByString:@";"]];
            CGPoint inCell = [gesture locationInView:cell];
            [line appendFormat:@" inCell=%.0f,%.0f", inCell.x, inCell.y];
        }
    }
    GXKProbeLog(@"tap", @"%@", line);
}
@end

static GXKProbeSymbolTap *gProbeSymbolTap;
static __weak UIView *gProbeSymbolTapHost;

static void GXKProbeAttachSymbolTap(UIView *root) {
    UIView *host = GXKProbeSymbolHost(root);
    if (!host || host == gProbeSymbolTapHost) return;
    gProbeSymbolTapHost = host;
    if (!gProbeSymbolTap) gProbeSymbolTap = [[GXKProbeSymbolTap alloc] init];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:gProbeSymbolTap action:@selector(onSymbolTap:)];
    tap.cancelsTouchesInView = NO; // never swallow the real key tap.
    tap.delaysTouchesEnded = NO;
    [host addGestureRecognizer:tap];
    GXKProbeLog(@"tap", @"attached to %@", GXKProbeClassName(host));
}

// Layout names are plain strings; printing the class alone wasted a whole probe run.
static NSString *GXKProbeDescribe(id value) {
    if (!value) return @"nil";
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        return text.length <= 60 ? text : [text substringToIndex:60];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in array) {
            if (parts.count >= 6) break;
            [parts addObject:[item isKindOfClass:[NSString class]] ? item : GXKProbeClassName(item)];
        }
        return [NSString stringWithFormat:@"%@[%lu]{%@}", GXKProbeClassName(value),
                (unsigned long)array.count, [parts componentsJoinedByString:@","]];
    }
    return GXKProbeClassName(value);
}

static IMP GXKProbeOrigFor(Class cls, SEL sel) {
    NSMutableDictionary *table = gProbeOrigs;
    if (!table) return NULL;
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
        NSString *key = [NSString stringWithFormat:@"%@/%s", NSStringFromClass(cursor), sel_getName(sel)];
        NSValue *value = table[key];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void GXKProbeRemember(Class cls, SEL sel, IMP imp) {
    @synchronized(GXKProbeLock()) {
        if (!gProbeOrigs) gProbeOrigs = [NSMutableDictionary dictionary];
        NSString *key = [NSString stringWithFormat:@"%@/%s", NSStringFromClass(cls), sel_getName(sel)];
        gProbeOrigs[key] = [NSValue valueWithPointer:(void *)imp];
    }
}

static id gxk_probe_id_obj(id self, SEL _cmd, id arg) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    // The stack capture is only worth paying for while a probe is marked.
    if (gProbeMarked) {
        // v9: keyboardViewWithLayoutName: carries the layout name as its argument;
        // printing only the class threw that away.
        GXKProbeLog(@"switch", @"%@ -%s(%@) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                    GXKProbeDescribe(arg), GXKProbeStack());
    }
    if (!orig) return nil;
    return ((id (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void gxk_probe_void_obj(id self, SEL _cmd, id arg) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    if (gProbeMarked) {
        GXKProbeLog(@"switch", @"%@ -%s(%@) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                    GXKProbeDescribe(arg), GXKProbeStack());
    }
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void gxk_probe_void_bool(id self, SEL _cmd, BOOL value) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    if (gProbeMarked) {
        GXKProbeLog(@"switch", @"%@ -%s(%d) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                    (int)value, GXKProbeStack());
    }
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, value);
}

// Only classes that DECLARE the selector are hooked. Inheriting a method is not
// enough: matching by class-name prefix missed every owner in v3-v5 (switch=0).
static BOOL GXKProbeDeclares(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NO;
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static id gxk_probe_id_void(id self, SEL _cmd) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    id result = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    if (gProbeMarked) {
        GXKProbeLog(@"switch", @"%@ -%s -> %@ stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                    GXKProbeDescribe(result), GXKProbeStack());
    }
    return result;
}

static void gxk_probe_void_bool_obj(id self, SEL _cmd, BOOL value, id arg) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    if (gProbeMarked) {
        GXKProbeLog(@"switch", @"%@ -%s(%d,%@) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                    (int)value, GXKProbeClassName(arg), GXKProbeStack());
    }
    if (orig) ((void (*)(id, SEL, BOOL, id))orig)(self, _cmd, value, arg);
}

static id gxk_probe_id_obj_obj(id self, SEL _cmd, id a, id b) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    if (gProbeMarked) {
        GXKProbeLog(@"switch", @"%@ -%s(%@,%@) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                    GXKProbeClassName(a), GXKProbeClassName(b), GXKProbeStack());
    }
    if (!orig) return nil;
    return ((id (*)(id, SEL, id, id))orig)(self, _cmd, a, b);
}

static void gxk_probe_void_text(id self, SEL _cmd, NSString *text) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    if (gProbeMarked) {
        GXKProbeLog(@"text", @"%@ insert='%@' stack=%@", GXKProbeClassName(self),
                    GXKProbeClip(text ?: @"", 40), GXKProbeStack());
    }
    if (orig) ((void (*)(id, SEL, NSString *))orig)(self, _cmd, text);
}

static void GXKProbeSwizzle(SEL sel, IMP hook) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls || !GXKProbeDeclares(cls, sel)) continue;
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) continue;
        IMP current = method_getImplementation(method);
        if (current == hook) continue;
        GXKProbeRemember(cls, sel, current);
        if (!class_addMethod(cls, sel, hook, method_getTypeEncoding(method))) {
            method_setImplementation(method, hook);
        }
    }
    free(classes);
}

static void GXKProbeInstallHooks(void) {
    if (gProbeHooksInstalled) return;
    gProbeHooksInstalled = YES;
    GXKProbeSwizzle(@selector(keyboardViewWithLayoutName:), (IMP)gxk_probe_id_obj);
    GXKProbeSwizzle(@selector(addKeyboardView:withLayoutName:), (IMP)gxk_probe_id_obj_obj);
    GXKProbeSwizzle(@selector(setSoftkeyLayoutName:), (IMP)gxk_probe_void_obj);
    GXKProbeSwizzle(@selector(setLayoutName:), (IMP)gxk_probe_void_obj);
    GXKProbeSwizzle(@selector(parseLayoutName), (IMP)gxk_probe_id_void);
    GXKProbeSwizzle(@selector(updateLayoutAnimated:), (IMP)gxk_probe_void_bool);
    GXKProbeSwizzle(@selector(updateLayoutAnimated:completion:), (IMP)gxk_probe_void_bool_obj);
    GXKProbeSwizzle(@selector(insertText:), (IMP)gxk_probe_void_text);
    GXKProbeLog(@"hook", @"installed");
}

static NSString *GXKProbeReport(void) {
    NSMutableString *out = [NSMutableString string];
    @synchronized(GXKProbeLock()) {
        [out appendFormat:@"GXK symbol probe v9\niOS=%@ lines=%lu%s\n",
         [UIDevice currentDevice].systemVersion,
         (unsigned long)(gProbeRing ? gProbeRing.count : 0),
         gProbeMarked ? " marked" : ""];
        [out appendString:@"read-only: every hooked call forwards; no key property is read.\n"
                           "layout = visible key identifiers of the 9-key body, in mount order.\n"
                           "symbols host= = the symbol page container (key_pos_9keys_symbols).\n"
                           "symbols i= = one visible cell by collection index: frame, label texts, fonts.\n"
                           "tap = one finger tap on the symbol page: index, label, in-cell point.\n"
                           "page = symbol page entered or left, with the driver's stack.\n"
                           "collections = every soft-key collection in the tree, named or not.\n"
                           "layout gap= = seconds the previous layout stood.\n"
                           "text = insertText: commit, with the caller's stack.\n"];
        if (gProbeRing) [out appendString:[gProbeRing componentsJoinedByString:@""]];
    }
    return out;
}

@interface GXKProbeTarget : NSObject
- (void)onProbeLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation GXKProbeTarget
- (void)onProbeLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *button = [gesture.view isKindOfClass:[UIButton class]] ? (UIButton *)gesture.view : nil;
    // Hooks are installed here, not at launch: until the user asks for a probe the
    // keyboard runs completely unmodified.
    GXKProbeInstallHooks();
    // Mark first, copy second: neither step walks the view tree, so this path stays cheap.
    if (!gProbeMarked) {
        @synchronized(GXKProbeLock()) {
            gProbeRing = [NSMutableArray array];
            gProbeStartedAt = GXKProbeNow();
            gProbeLastFingerprint = nil;
            gProbeLastFingerprintAt = 0;
            gProbeLastWindow = nil;
            gProbeLastLayoutAt = 0;
            gProbeWasOnSymbols = NO;
            gProbeMarked = YES;
        }
        GXKProbeLog(@"mark", @"start");
        if (button) GXKFlashTitle(button, @"诊断");
        return;
    }
    NSString *report = GXKProbeReport();
    @synchronized(GXKProbeLock()) {
        gProbeMarked = NO;
    }
    if (report.length) [UIPasteboard generalPasteboard].string = report;
    if (button) GXKFlashTitle(button, @"已复制");
}
@end

static GXKProbeTarget *gProbeTarget;

static void GXKProbeAttachLongPress(UIButton *button) {
    if (!button || button == gProbeAttachedButton) return;
    gProbeAttachedButton = button;
    if (!gProbeTarget) gProbeTarget = [[GXKProbeTarget alloc] init];
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:gProbeTarget action:@selector(onProbeLongPress:)];
    gesture.minimumPressDuration = 0.8;
    gesture.cancelsTouchesInView = YES;
    [button addGestureRecognizer:gesture];
}

#endif  // GXK_SYMBOL_PROBE_H
