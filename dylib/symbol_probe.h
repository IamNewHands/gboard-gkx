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

#define GXK_PROBE_RING 200
#define GXK_PROBE_MAX_LINE 600
#define GXK_PROBE_MAX_KEYS 40
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
    NSString *fingerprint = body ? [keys componentsJoinedByString:@","] : @"no-nine-key-body";
    if ([fingerprint isEqualToString:gProbeLastFingerprint ?: @""]) return;
    gProbeLastFingerprint = fingerprint;
    GXKProbeLog(@"layout", @"%@ body=%@ keys=%@", reason, GXKProbeClassName(body),
                GXKProbeClip(fingerprint, 500));
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
    GXKProbeLog(@"switch", @"%@ -%s(%@) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                GXKProbeClassName(arg), GXKProbeStack());
    if (!orig) return nil;
    return ((id (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void gxk_probe_void_obj(id self, SEL _cmd, id arg) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeLog(@"switch", @"%@ -%s(%@) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                GXKProbeClassName(arg), GXKProbeStack());
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void gxk_probe_void_bool(id self, SEL _cmd, BOOL value) {
    IMP orig = GXKProbeOrigFor(object_getClass(self), _cmd);
    GXKProbeLog(@"switch", @"%@ -%s(%d) stack=%@", GXKProbeClassName(self), sel_getName(_cmd),
                (int)value, GXKProbeStack());
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, value);
}

// A substring match ("Key") would sweep hundreds of unrelated classes; only the
// keyboard's own prefixes are touched.
static BOOL GXKProbeNameAllowed(const char *name) {
    if (!name) return NO;
    return strncmp(name, "GKB", 3) == 0 || strncmp(name, "UIKeyboard", 10) == 0 ||
           strncmp(name, "TIKeyboard", 10) == 0 || strncmp(name, "TUIKeyboard", 11) == 0;
}

static void GXKProbeSwizzle(SEL sel, IMP hook) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls || !GXKProbeNameAllowed(class_getName(cls))) continue;
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
    gProbeSwizzle(@selector(keyboardViewWithLayoutName:), (IMP)gxk_probe_id_obj);
    GXKProbeSwizzle(@selector(setSoftkeyLayoutName:), (IMP)gxk_probe_void_obj);
    GXKProbeSwizzle(@selector(updateLayoutAnimated:), (IMP)gxk_probe_void_bool);
    GXKProbeLog(@"hook", @"installed");
}

static NSString *GXKProbeReport(void) {
    NSMutableString *out = [NSMutableString string];
    @synchronized(GXKProbeLock()) {
        [out appendFormat:@"GXK symbol probe v3\niOS=%@ lines=%lu%s\n",
         [UIDevice currentDevice].systemVersion,
         (unsigned long)(gProbeRing ? gProbeRing.count : 0),
         gProbeMarked ? " marked" : ""];
        [out appendString:@"read-only: every hooked call forwards; no key property is read.\n"
                           "switch = native layout entry point (class, selector, argument class, callers).\n"
                           "layout = visible key identifiers of the 9-key body, in mount order.\n"];
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
