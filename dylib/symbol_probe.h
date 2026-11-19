// [DEBUG-symbol] Temporary, opt-in probe for the 9-key symbol page.
// Behavior-neutral: it only records observations and forwards every original call.
// Long press the action key (换行/重输) for 0.8 s to start, again to stop and copy.
#ifndef GXK_SYMBOL_PROBE_H
#define GXK_SYMBOL_PROBE_H

#include <stdarg.h>
#include <stdlib.h>

#define GXK_PROBE_MAX_LINES 400
#define GXK_PROBE_MAX_CHARS 131072
#define GXK_PROBE_RING 120
#define GXK_PROBE_STACK 8
#define GXK_PROBE_MAX_KEYS 64
#define GXK_PROBE_MIN_GAP 0.10

static NSMutableArray<NSString *> *gProbeRing;
static BOOL gProbeActive;
static NSMutableArray<NSString *> *gProbeLines;
static NSUInteger gProbeChars;
static NSUInteger gProbeDropped;
static NSTimeInterval gProbeStartedAt;
static NSString *gProbeLastFingerprint;
static NSMutableDictionary<NSString *, NSValue *> *gProbeOrigs;
static BOOL gProbeHooksInstalled;
static __weak UIButton *gProbeAttachedButton;
static NSTimeInterval gProbeLastFingerprintAt;

static NSTimeInterval GXKProbeNow(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static NSString *GXKProbeClip(id value, NSUInteger limit) {
    NSString *text = value ? [value description] : @"nil";
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

static NSString *GXKProbeStack(void) {
    NSArray<NSString *> *frames = [NSThread callStackSymbols];
    if (frames.count <= 2) return @"none";
    NSUInteger end = MIN(frames.count, (NSUInteger)(GXK_PROBE_STACK + 2));
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSUInteger i = 2; i < end; i++) [kept addObject:GXKProbeClip(frames[i], 120)];
    return [kept componentsJoinedByString:@" | "];
}

static void GXKProbeAppend(NSString *line) {
    if (!line.length) return;
    if (!gProbeRing) {
        gProbeRing = [NSMutableArray array];
        gProbeStartedAt = GXKProbeNow();
    }
    [gProbeRing addObject:line];
    while (gProbeRing.count > GXK_PROBE_RING) [gProbeRing removeObjectAtIndex:0];
    if (!gProbeActive || !gProbeLines) return;
    if (gProbeLines.count >= GXK_PROBE_MAX_LINES || gProbeChars + line.length > GXK_PROBE_MAX_CHARS) {
        gProbeDropped++;
        return;
    }
    [gProbeLines addObject:line];
    gProbeChars += line.length;
}

static void GXKProbeEvent(NSString *tag, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

static void GXKProbeEvent(NSString *tag, NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    GXKProbeAppend([NSString stringWithFormat:@"t=%.3f [%@] %@\n",
                    GXKProbeNow() - gProbeStartedAt, tag, body ?: @""]);
}

// Visible 9-key body, identified by class only; never by nib name or coordinates.
static UIView *GXKProbeNineKeyBody(UIView *root) {
    if (!root) return nil;
    Class nineClass = NSClassFromString(@"GKB9KeysSoftKeyboardView");
    if (!nineClass) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 2000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (!view.isHidden && view.alpha >= 0.05 && [view isKindOfClass:nineClass] &&
            !CGRectIsEmpty(view.bounds)) {
            return view;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Layout fingerprint: the sorted set of key identifiers currently mounted.
static NSString *GXKProbeFingerprint(UIView *root) {
    UIView *body = GXKProbeNineKeyBody(root);
    if (!body) return @"no-nine-key-body";
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 2000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        NSString *ident = view.restorationIdentifier;
        if (ident.length && !view.isHidden) [ids addObject:ident];
        [stack addObjectsFromArray:view.subviews];
    }
    [ids sortUsingSelector:@selector(compare:)];
    if (ids.count > GXK_PROBE_MAX_KEYS) ids = [[ids subarrayWithRange:NSMakeRange(0, GXK_PROBE_MAX_KEYS)] mutableCopy];
    return [NSString stringWithFormat:@"%lu:%@", (unsigned long)ids.count, [ids componentsJoinedByString:@","]];
}

static void GXKProbeDumpKeys(NSString *reason) {
    UIViewController *vc = gCurrentVC;
    UIView *root = vc.isViewLoaded ? vc.view : nil;
    if (!root) return;
    UIView *body = GXKProbeNineKeyBody(root);
    GXKProbeEvent(@"keys", @"%@ body=%@ keys=%lu", reason,
                  body ? NSStringFromClass(body.class) : @"none",
                  (unsigned long)(body ? body.subviews.count : 0));
    if (!body) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
    NSUInteger visited = 0, emitted = 0;
    while (stack.count && visited++ < 2000 && emitted < GXK_PROBE_MAX_KEYS) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        NSString *ident = view.restorationIdentifier;
        if (ident.length) {
            emitted++;
            NSMutableArray<NSString *> *bits = [NSMutableArray array];
            [bits addObject:[NSString stringWithFormat:@"id=%@ cls=%@", ident, NSStringFromClass(view.class)]];
            if ([view respondsToSelector:@selector(softKeyDef)]) {
                id model = ((id<GXKNativeSoftKeyContent>)view).softKeyDef;
                [bits addObject:[NSString stringWithFormat:@"model=%@", model ? NSStringFromClass([model class]) : @"nil"]];
                if (GXKModelHasNativeActions(model)) {
                    NSMutableArray<NSString *> *acts = [NSMutableArray array];
                    for (id action in ((id<GXKNativeActionModel>)model).actionsArray) {
                        [acts addObject:NSStringFromClass([action class])];
                    }
                    [bits addObject:[NSString stringWithFormat:@"actions=%@", [acts componentsJoinedByString:@"/"]]];
                }
            }
            if ([view respondsToSelector:@selector(idToViewDict)]) {
                NSDictionary *contents = ((id<GXKNativeSoftKeyContent>)view).idToViewDict;
                if ([contents isKindOfClass:[NSDictionary class]]) {
                    [bits addObject:[NSString stringWithFormat:@"contentKeys=%@",
                                     [[contents.allKeys sortedArrayUsingSelector:@selector(compare:)]
                                      componentsJoinedByString:@"/"]]];
                }
            }
            [bits addObject:[NSString stringWithFormat:@"hidden=%d frame=%@", view.isHidden,
                             NSStringFromCGRect(view.frame)]];
            GXKProbeEvent(@"key", @"%@", [bits componentsJoinedByString:@" "]);
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void GXKProbeNoteLayout(NSString *reason) {
    UIViewController *vc = gCurrentVC;
    if (!vc || !vc.isViewLoaded) return;
    NSTimeInterval now = GXKProbeNow();
    if (now - gProbeLastFingerprintAt < GXK_PROBE_MIN_GAP) return;
    gProbeLastFingerprintAt = now;
    NSString *fingerprint = GXKProbeFingerprint(vc.view);
    if ([fingerprint isEqualToString:gProbeLastFingerprint ?: @""]) return;
    gProbeLastFingerprint = fingerprint;
    GXKProbeEvent(@"layout", @"%@ fp=%@", reason, GXKProbeClip(fingerprint, 400));
    GXKProbeDumpKeys([@"after-" stringByAppendingString:reason]);
}

// A hook may be installed on a superclass while the live instance is a subclass,
// so the original IMP is looked up along the whole superclass chain.
static IMP GXKProbeOrigFor(Class cls, SEL sel) {
    if (!gProbeOrigs) return NULL;
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
        NSString *key = [NSString stringWithFormat:@"%@/%s", NSStringFromClass(cursor), sel_getName(sel)];
        NSValue *value = gProbeOrigs[key];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void GXKProbeRemember(Class cls, SEL sel, IMP imp) {
    if (!gProbeOrigs) gProbeOrigs = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@/%s", NSStringFromClass(cls), sel_getName(sel)];
    gProbeOrigs[key] = [NSValue valueWithPointer:(void *)imp];
}

static id gxk_probe_id_obj(id self, SEL _cmd, id arg) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeEvent(@"switch", @"%@ -%s(%@) stack=%@", NSStringFromClass(object_getClass(self)),
                  sel_getName(_cmd), GXKProbeClip(arg, 80), GXKProbeStack());
    if (!orig) return nil;
    return ((id (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void gxk_probe_void_obj(id self, SEL _cmd, id arg) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeEvent(@"switch", @"%@ -%s(%@) stack=%@", NSStringFromClass(object_getClass(self)),
                  sel_getName(_cmd), GXKProbeClip(arg, 80), GXKProbeStack());
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void gxk_probe_void_long(id self, SEL _cmd, long value) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeEvent(@"switch", @"%@ -%s(%ld) stack=%@", NSStringFromClass(object_getClass(self)),
                  sel_getName(_cmd), value, GXKProbeStack());
    if (orig) ((void (*)(id, SEL, long))orig)(self, _cmd, value);
}

static void gxk_probe_void_bool(id self, SEL _cmd, BOOL value) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeEvent(@"switch", @"%@ -%s(%d) stack=%@", NSStringFromClass(object_getClass(self)),
                  sel_getName(_cmd), (int)value, GXKProbeStack());
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, value);
}

static void gxk_probe_insert_text(id self, SEL _cmd, id text) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    NSString *string = [text isKindOfClass:[NSString class]] ? text : nil;
    if (string.length <= 3) {
        GXKProbeEvent(@"insert", @"%@ -insertText(%@) len=%lu stack=%@",
                      NSStringFromClass(object_getClass(self)), GXKProbeClip(string, 24),
                      (unsigned long)string.length, GXKProbeStack());
    }
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, text);
}

static void gxk_probe_delete_backward(id self, SEL _cmd) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeEvent(@"delete", @"%@ -deleteBackward", NSStringFromClass(object_getClass(self)));
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

// Swizzle only classes whose name marks them as keyboard/layout owners; everything else is left alone.
static void GXKProbeSwizzleSelector(SEL sel, IMP hook, const char *const *filters, size_t filterCount) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        const char *name = class_getName(cls);
        if (!name) continue;
        BOOL matches = NO;
        for (size_t f = 0; f < filterCount && !matches; f++) {
            if (strstr(name, filters[f])) matches = YES;
        }
        if (!matches) continue;
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) continue;
        IMP current = method_getImplementation(method);
        if (current == hook) continue;
        GXKProbeRemember(cls, sel, current);
        if (!class_addMethod(cls, sel, hook, method_getTypeEncoding(method))) {
            method_setImplementation(method, hook);
        }
        GXKProbeEvent(@"hook", @"%@ -%s", [NSString stringWithUTF8String:name], sel_getName(sel));
    }
    free(classes);
}

static void GXKProbeInstallHooks(void) {
    if (gProbeHooksInstalled) return;
    if (!gCurrentVC) return;
    gProbeHooksInstalled = YES;
    static const char *const filters[] = {"Keyboard", "Layout", "Softkey", "Key"};
    GXKProbeSwizzleSelector(@selector(keyboardViewWithLayoutName:), (IMP)gxk_probe_id_obj, filters, 4);
    GXKProbeSwizzleSelector(@selector(updateLayoutAnimated:), (IMP)gxk_probe_void_bool, filters, 4);
    GXKProbeSwizzleSelector(@selector(loadLayoutForType:), (IMP)gxk_probe_void_long, filters, 4);
    GXKProbeSwizzleSelector(@selector(configureWithKeyboardLayout:), (IMP)gxk_probe_void_obj, filters, 4);
    GXKProbeSwizzleSelector(@selector(setSoftkeyLayoutName:), (IMP)gxk_probe_void_obj, filters, 4);
    GXKProbeSwizzleSelector(@selector(scrollToPage:), (IMP)gxk_probe_void_long, filters, 4);
    UIViewController *vc = gCurrentVC;
    if ([vc isKindOfClass:[UIInputViewController class]]) {
        id proxy = ((UIInputViewController *)vc).textDocumentProxy;
        Class proxyClass = proxy ? object_getClass(proxy) : Nil;
        if (proxyClass) {
            Method insert = class_getInstanceMethod(proxyClass, @selector(insertText:));
            if (insert && method_getImplementation(insert) != (IMP)gxk_probe_insert_text) {
                GXKProbeRemember(proxyClass, @selector(insertText:), method_getImplementation(insert));
                if (!class_addMethod(proxyClass, @selector(insertText:), (IMP)gxk_probe_insert_text,
                                     method_getTypeEncoding(insert))) {
                    method_setImplementation(insert, (IMP)gxk_probe_insert_text);
                }
                GXKProbeEvent(@"hook", @"%@ -insertText:", NSStringFromClass(proxyClass));
            }
            Method del = class_getInstanceMethod(proxyClass, @selector(deleteBackward));
            if (del && method_getImplementation(del) != (IMP)gxk_probe_delete_backward) {
                GXKProbeRemember(proxyClass, @selector(deleteBackward), method_getImplementation(del));
                if (!class_addMethod(proxyClass, @selector(deleteBackward), (IMP)gxk_probe_delete_backward,
                                     method_getTypeEncoding(del))) {
                    method_setImplementation(del, (IMP)gxk_probe_delete_backward);
                }
                GXKProbeEvent(@"hook", @"%@ -deleteBackward", NSStringFromClass(proxyClass));
            }
        }
    }
    GXKProbeNoteLayout(@"install");
}

static NSString *GXKProbeReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"GXK symbol probe v1\niOS=%@ lines=%lu dropped=%lu limit=%d/%d\n",
     [UIDevice currentDevice].systemVersion, (unsigned long)(gProbeLines ? gProbeLines.count : 0),
     (unsigned long)gProbeDropped, GXK_PROBE_MAX_LINES, GXK_PROBE_MAX_CHARS];
    [out appendString:@"Read-only: no input is inserted, deleted or re-routed; every hooked call forwards.\n"
                       "t = seconds since probe start. fp = sorted key identifiers of the visible 9-key body.\n"
                       "switch = a native layout-switch entry point was called (class, selector, argument, caller frames).\n"
                       "insert = text document proxy received insertText: (length <= 3 only).\n"
                       "Long press the action key for 0.8 s to start, again to stop and copy.\n"];
    if (gProbeLines) [out appendString:[gProbeLines componentsJoinedByString:@""]];
    return out;
}

static void GXKProbeStart(UIButton *button) {
    gProbeLines = [NSMutableArray array];
    gProbeChars = 0;
    gProbeDropped = 0;
    gProbeActive = YES;
    gProbeStartedAt = GXKProbeNow();
    gProbeLastFingerprint = nil;
    GXKProbeEvent(@"start", @"begin");
    if (gProbeRing.count) {
        GXKProbeEvent(@"preroll", @"%lu recent lines", (unsigned long)gProbeRing.count);
        for (NSString *line in gProbeRing) GXKProbeAppend(line);
    }
    GXKProbeDumpKeys(@"start");
    if (button) GXKFlashTitle(button, @"诊断");
}

static void GXKProbeStop(UIButton *button) {
    GXKProbeEvent(@"stop", @"manual");
    NSString *report = GXKProbeReport();
    [UIPasteboard generalPasteboard].string = report;
    gProbeActive = NO;
    gProbeLines = nil;
    gProbeChars = 0;
    if (button) GXKFlashTitle(button, @"已复制");
}

@interface GXKProbeTarget : NSObject
- (void)onProbeLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation GXKProbeTarget
- (void)onProbeLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *button = [gesture.view isKindOfClass:[UIButton class]] ? (UIButton *)gesture.view : nil;
    if (gProbeActive) {
        GXKProbeStop(button);
    } else {
        GXKProbeStart(button);
    }
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
