// a11y/Tweak.m —— 电话助手无障碍与界面降噪补丁（不依赖 substrate，纯 objc runtime）
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - 文本处理

static BOOL HasNonASCII(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        if ([s characterAtIndex:i] >= 0x80) return YES;
    }
    return NO;
}

static NSString *TrimStr(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 混合串（如「隐藏语音信箱 / Hide Voicemail」）只保留含中文的片段；纯英文串整条丢弃。
static NSString *FilterEnglish(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return raw;
    static NSCharacterSet *seps = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seps = [NSCharacterSet characterSetWithCharactersInString:@"/|·"];
    });
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:seps];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *p in parts) {
        if (HasNonASCII(p)) [keep addObject:TrimStr(p)];
    }
    if (keep.count == parts.count) return raw;   // 全中文，原样返回
    return TrimStr([keep componentsJoinedByString:@" "]);
}

#pragma mark - 是否设置页控件

static BOOL InSettingsCell(UIView *v) {
    NSArray *keys = @[@"PSSwitch", @"PSCell", @"PSGroup", @"PSControl",
                      @"PSEdit", @"PSSpec", @"PSButton", @"PSList", @"PSTable"];
    UIView *cur = v.superview;
    for (int i = 0; i < 8 && cur; i++, cur = cur.superview) {
        NSString *cn = NSStringFromClass([cur class]);
        for (NSString *k in keys) {
            if ([cn rangeOfString:k].location != NSNotFound) return YES;
        }
    }
    return NO;
}

#pragma mark - 拨号区变化播报（删除键不朗读的兜底）

static char kPrevDialKey;
static BOOL LooksLikeDial(id obj) {
    if (![obj isKindOfClass:[NSString class]]) return NO;
    NSString *s = (NSString *)obj;
    if (s.length == 0 || s.length > 24) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || c == '+' || c == '*' || c == '#' || c == ' ')) return NO;
    }
    return YES;
}

static void MaybeAnnounceDelete(id self, NSString *newText) {
    NSString *old = objc_getAssociatedObject(self, &kPrevDialKey);
    objc_setAssociatedObject(self, &kPrevDialKey, newText, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!LooksLikeDial(old) || !LooksLikeDial(newText)) return;
    if (newText.length >= old.length) return;
    NSString *msg = (newText.length == 0) ? @"号码已清空"
                  : [NSString stringWithFormat:@"已删除，当前号码 %@", newText];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, msg);
}

#pragma mark - hook 文本设置

static IMP gOrigSetText = NULL;
static void HookSetText(id self, SEL cmd, NSString *text) {
    NSString *t = text;
    if ([t isKindOfClass:[NSString class]]) {
        if (LooksLikeDial(t)) MaybeAnnounceDelete(self, t);
        if ([self isKindOfClass:[UIView class]] && InSettingsCell((UIView *)self)) {
            t = FilterEnglish(t);
        }
    }
    ((void (*)(id, SEL, NSString *))gOrigSetText)(self, cmd, t);
}

static IMP gOrigSetAttrText = NULL;
static void HookSetAttrText(id self, SEL cmd, NSAttributedString *text) {
    NSAttributedString *t = text;
    if ([t isKindOfClass:[NSAttributedString class]] && [self isKindOfClass:[UIView class]]
        && InSettingsCell((UIView *)self)) {
        NSString *s = t.string;
        NSString *f = FilterEnglish(s);
        if (f && ![f isEqualToString:s]) {
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode = NSLineBreakByTruncatingTail;
            t = [[NSAttributedString alloc] initWithString:f
                                                attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:13],
                                                             NSForegroundColorAttributeName:[UIColor grayColor],
                                                             NSParagraphStyleAttributeName:ps}];
        }
    }
    ((void (*)(id, SEL, NSAttributedString *))gOrigSetAttrText)(self, cmd, t);
}

static IMP gOrigTFSetText = NULL;
static void HookTFSetText(id self, SEL cmd, NSString *text) {
    NSString *t = text;
    if (LooksLikeDial(t)) MaybeAnnounceDelete(self, t);
    ((void (*)(id, SEL, NSString *))gOrigTFSetText)(self, cmd, t);
}

static void InstallTextHook(Class cls, IMP *slot, IMP hook, const char *selName) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString([NSString stringWithUTF8String:selName]));
    if (!m) return;
    *slot = method_setImplementation(m, hook);
}

#pragma mark - ZSListView 逐条可聚焦

static BOOL ZSList_isElement(id self, SEL cmd) { (void)self; (void)cmd; return NO; }

static NSArray *ZSList_elements(id self, SEL cmd) {
    (void)cmd;
    UIView *v = (UIView *)self;
    NSMutableArray *arr = [NSMutableArray array];
    for (UIView *sub in v.subviews) {
        NSString *lab = nil;
        for (UIView *s2 in sub.subviews) {
            if ([s2 isKindOfClass:[UILabel class]]) {
                NSString *s = ((UILabel *)s2).text;
                if (s.length) lab = (lab.length ? [lab stringByAppendingFormat:@" %@", s] : s);
            }
        }
        if (!sub.isAccessibilityElement && lab.length) {
            sub.isAccessibilityElement = YES;
            sub.accessibilityLabel = lab;
        }
        if (sub.isAccessibilityElement) [arr addObject:sub];
    }
    return arr;
}

static void PatchListClass(Class c) {
    class_replaceMethod(c, NSSelectorFromString(@"isAccessibilityElement"), (IMP)ZSList_isElement, "c@:");
    class_replaceMethod(c, NSSelectorFromString(@"accessibilityElements"), (IMP)ZSList_elements, "@@:");
}

#pragma mark - 初始化

__attribute__((constructor)) static void A11yInit(void) {
    Class UILabel_ = objc_getClass("UILabel");
    Class UITextField_ = objc_getClass("UITextField");
    InstallTextHook(UILabel_, &gOrigSetText, (IMP)HookSetText, "setText:");
    InstallTextHook(UILabel_, &gOrigSetAttrText, (IMP)HookSetAttrText, "setAttributedText:");
    InstallTextHook(UITextField_, &gOrigTFSetText, (IMP)HookTFSetText, "setText:");

    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        count = objc_getClassList(classes, count);
        for (int i = 0; i < count; i++) {
            const char *nm = class_getName(classes[i]);
            if (nm && strstr(nm, "ZSListView")) PatchListClass(classes[i]);
        }
        free(classes);
    }
}
