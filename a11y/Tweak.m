// a11y/Tweak.m —— 电话助手无障碍补丁 v2（纯 objc runtime，不依赖 substrate）
#import <UIKit/UIKit.h>
#import <Contacts/Contacts.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static BOOL HasNonASCII(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        if ([s characterAtIndex:i] >= 0x80) return YES;
    }
    return NO;
}

static NSString *TrimStr(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL IsCodeLike(NSString *s) {
    NSString *t = TrimStr(s);
    if (t.length == 0) return NO;
    if ([t hasPrefix:@"#"]) return YES;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"0123456789+*#-:. "];
    return [t rangeOfCharacterFromSet:[ok invertedSet]].location == NSNotFound;
}

static NSString *NearestVCName(UIView *v) {
    UIResponder *r = (UIResponder *)v;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return NSStringFromClass([r class]);
        r = [r nextResponder];
    }
    return nil;
}

static BOOL InSettingsCell(UIView *v) {
    NSArray *keys = @[@"PSSwitch", @"PSCell", @"PSGroup", @"PSControl", @"PSEdit",
                      @"PSSpec", @"PSButton", @"PSList", @"PSTable", @"PSFooter"];
    UIView *cur = v.superview;
    for (int i = 0; i < 8 && cur; i++, cur = cur.superview) {
        NSString *cn = NSStringFromClass([cur class]);
        for (NSString *k in keys) {
            if ([cn rangeOfString:k].location != NSNotFound) return YES;
        }
    }
    return NO;
}

static BOOL InSettingsArea(UIView *v) {
    if (InSettingsCell(v)) return YES;
    NSString *vc = NearestVCName(v);
    if (vc && [vc rangeOfString:@"Set" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static NSString *FilterEnglish(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return raw;
    static NSCharacterSet *seps = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seps = [NSCharacterSet characterSetWithCharactersInString:@"/|.\n\r()"];
    });
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:seps];
    if (parts.count < 2) {
        if (HasNonASCII(raw) || IsCodeLike(raw)) return raw;
        return @"";
    }
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *p in parts) {
        if (HasNonASCII(p) || IsCodeLike(p)) {
            NSString *t = TrimStr(p);
            if (t.length) [keep addObject:t];
        }
    }
    if (keep.count == parts.count) return raw;
    if (keep.count == 0) return @"";
    return TrimStr([keep componentsJoinedByString:@" "]);
}

static NSMutableArray *gQueue = nil;
static BOOL gSpeaking = NO;

static void DrainQueue(void);
static void RefreshBarFor(NSString *typed);
static UIWindow *KeyWindowNow(void);

static void EnqueueAnnounce(NSString *msg) {
    if (msg.length == 0) return;
    if (!gQueue) gQueue = [NSMutableArray array];
    [gQueue addObject:msg];
    DrainQueue();
}

static void DrainQueue(void) {
    if (gSpeaking || gQueue.count == 0) return;
    gSpeaking = YES;
    NSString *m = gQueue[0];
    [gQueue removeObjectAtIndex:0];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, m);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gSpeaking = NO;
        DrainQueue();
    });
}

static NSString *gLastDial = nil;
static UITextField *gDialField = nil;

static BOOL LooksLikeDial(id obj) {
    if (![obj isKindOfClass:[NSString class]]) return NO;
    NSString *s = (NSString *)obj;
    if (s.length == 0 || s.length > 32) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || c == '+' || c == '*' || c == '#' || c == ' ')) return NO;
    }
    return YES;
}

static NSMutableArray *gBlacklist = nil;

static NSString *BlacklistPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.count ? dirs[0] : NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"a11y_blacklist.plist"];
}

static void LoadBlacklist(void) {
    if (gBlacklist) return;
    NSArray *arr = [NSArray arrayWithContentsOfFile:BlacklistPath()];
    gBlacklist = arr ? [arr mutableCopy] : [NSMutableArray array];
}

static void SaveBlacklist(void) {
    if (!gBlacklist) return;
    [gBlacklist writeToFile:BlacklistPath() atomically:YES];
}

static NSString *DigitsOnly(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSMutableString *m = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [m appendFormat:@"%C", c];
    }
    return m;
}

static NSString *LongestDigits(NSString *s, NSUInteger minLen) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return nil;
    NSString *best = nil;
    NSUInteger run = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            run++;
        } else {
            if (run >= minLen) {
                NSString *seg = [s substringWithRange:NSMakeRange(i - run, run)];
                if (!best || seg.length > best.length) best = seg;
            }
            run = 0;
        }
    }
    if (run >= minLen) {
        NSString *seg = [s substringWithRange:NSMakeRange(s.length - run, run)];
        if (!best || seg.length > best.length) best = seg;
    }
    return best;
}

@interface A11yAction : UIAccessibilityCustomAction
@property (nonatomic, copy) NSString *digits;
@property (nonatomic, assign) NSInteger kind;
@end

@implementation A11yAction
@end

@interface A11yHelper : NSObject
+ (instancetype)shared;
- (BOOL)handleAction:(UIAccessibilityCustomAction *)action;
- (void)tapCandidate:(UIButton *)sender;
- (void)openBlacklist;
@end

@interface A11yBlackVC : UITableViewController
@end

@implementation A11yBlackVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = @"黑名单";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(closeSelf)];
}

- (void)closeSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    LoadBlacklist();
    return (NSInteger)gBlacklist.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"blk";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    LoadBlacklist();
    NSString *num = gBlacklist[(NSUInteger)indexPath.row];
    cell.textLabel.text = num;
    cell.accessibilityLabel = [NSString stringWithFormat:@"黑名单 %@", num];
    return cell;
}

@end

@implementation A11yHelper

+ (instancetype)shared {
    static A11yHelper *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[A11yHelper alloc] init]; });
    return s;
}

- (BOOL)handleAction:(UIAccessibilityCustomAction *)action {
    if (![action isKindOfClass:[A11yAction class]]) return NO;
    A11yAction *a = (A11yAction *)action;
    NSString *digits = a.digits;
    if (digits.length < 5) return NO;
    LoadBlacklist();
    if (a.kind == 0) {
        if (![gBlacklist containsObject:digits]) [gBlacklist addObject:digits];
        SaveBlacklist();
        EnqueueAnnounce([NSString stringWithFormat:@"已加入黑名单 %@", digits]);
    } else {
        [gBlacklist removeObject:digits];
        SaveBlacklist();
        EnqueueAnnounce([NSString stringWithFormat:@"已移出黑名单 %@", digits]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        });
    }
    return YES;
}

- (void)tapCandidate:(UIButton *)sender {
    static char kNumKey;
    NSString *digits = objc_getAssociatedObject(sender, &kNumKey);
    if (digits.length == 0) return;
    UITextField *f = gDialField;
    if (f) {
        f.text = digits;
        [f sendActionsForControlEvents:UIControlEventEditingChanged];
        gLastDial = digits;
        EnqueueAnnounce([NSString stringWithFormat:@"已填入 %@", digits]);
    } else {
        EnqueueAnnounce(@"候选无法填入号码框");
    }
}

- (void)openBlacklist {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = KeyWindowNow().rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if ([top isKindOfClass:[UINavigationController class]])
            top = ((UINavigationController *)top).topViewController;
        if (!top) return;
        A11yBlackVC *vc = [[A11yBlackVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

@end

static IMP gOrigSetText = NULL;
static IMP gOrigSetAttrText = NULL;
static IMP gOrigTFSetText = NULL;

static void TrackDial(id self, NSString *text) {
    if (!LooksLikeDial(text) || text.length == 0) return;
    gLastDial = text;
    if ([self isKindOfClass:[UITextField class]]) gDialField = (UITextField *)self;
    RefreshBarFor(text);
}

static void HookSetText(id self, SEL cmd, NSString *text) {
    NSString *t = text;
    if ([t isKindOfClass:[NSString class]]) {
        TrackDial(self, t);
        if ([self isKindOfClass:[UIView class]] && InSettingsArea((UIView *)self)) {
            t = FilterEnglish(t);
        }
    }
    ((void (*)(id, SEL, NSString *))gOrigSetText)(self, cmd, t);
}

static void HookSetAttrText(id self, SEL cmd, NSAttributedString *text) {
    NSAttributedString *t = text;
    if ([t isKindOfClass:[NSAttributedString class]] && [self isKindOfClass:[UIView class]]
        && InSettingsArea((UIView *)self)) {
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

static void HookTFSetText(id self, SEL cmd, NSString *text) {
    TrackDial(self, text);
    ((void (*)(id, SEL, NSString *))gOrigTFSetText)(self, cmd, text);
}

static void InstallTextHook(Class cls, IMP *slot, IMP hook, const char *selName) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString([NSString stringWithUTF8String:selName]));
    if (!m) return;
    *slot = method_setImplementation(m, hook);
}

@interface A11yDel : NSObject
+ (instancetype)shared;
- (void)tap:(UITapGestureRecognizer *)g;
- (void)longPress:(UILongPressGestureRecognizer *)g;
@end

@implementation A11yDel

+ (instancetype)shared {
    static A11yDel *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[A11yDel alloc] init]; });
    return s;
}

- (void)tap:(UITapGestureRecognizer *)g {
    NSString *cur = gLastDial;
    if (cur.length > 0) {
        NSString *after = [cur substringToIndex:cur.length - 1];
        gLastDial = after;
        if (after.length == 0) EnqueueAnnounce(@"号码已清空");
        else EnqueueAnnounce([NSString stringWithFormat:@"已删除，当前 %@", after]);
    } else {
        EnqueueAnnounce(@"删除");
    }
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITextField *f = gDialField;
    if (f) {
        f.text = @"";
        [f sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    gLastDial = @"";
    EnqueueAnnounce(@"号码已全部清空");
}

@end

static char kDelKey1;
static char kDumpDone;

static BOOL IsSingleDigitText(NSString *t) {
    if (t.length != 1) return NO;
    unichar c = [t characterAtIndex:0];
    return c >= '0' && c <= '9';
}

static NSUInteger CountDialKeys(UIView *root, NSUInteger limit, int depth) {
    if (!root || depth > 14 || limit == 0) return 0;
    NSUInteger n = 0;
    if ([root isKindOfClass:[UILabel class]] && IsSingleDigitText(((UILabel *)root).text)) n++;
    if ([root isKindOfClass:[UIButton class]] &&
        IsSingleDigitText([((UIButton *)root) titleForState:UIControlStateNormal])) n++;
    for (UIView *sub in root.subviews) {
        n += CountDialKeys(sub, limit - n, depth + 1);
        if (n >= limit) return n;
    }
    return n;
}

static BOOL LooksLikeDialPad(UIWindow *win) {
    return win && CountDialKeys(win, 8, 0) >= 8;
}

static BOOL LooksLikeDeleteControl(UIView *v) {
    NSString *label = [v accessibilityLabel];
    if (label && [label rangeOfString:@"删除"].location != NSNotFound) return YES;
    NSString *ident = [v accessibilityIdentifier];
    if (ident && ([ident rangeOfString:@"delete" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                  [ident rangeOfString:@"backspace" options:NSCaseInsensitiveSearch].location != NSNotFound))
        return YES;
    if ([v isKindOfClass:[UIControl class]]) {
        for (UIView *sub in v.subviews) {
            if ([sub isKindOfClass:[UILabel class]]) {
                NSString *t = ((UILabel *)sub).text;
                if (t && [t rangeOfString:@"删除"].location != NSNotFound) return YES;
            }
        }
    }
    return NO;
}

// 拨号盘右下角那个「×」按钮：几何兜底
static UIView *FindGeometricDelete(UIView *root, CGRect bounds, int depth, UIView *found) {
    if (!root || depth > 14) return found;
    if (found) return found;
    if ([root isKindOfClass:[UIControl class]]) {
        CGRect f = [root convertRect:root.bounds toView:nil];
        CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
        CGFloat w = f.size.width, h = f.size.height;
        if (w >= 24 && w <= 90 && h >= 24 && h <= 90 &&
            cx > bounds.size.width * 0.66 && cy > bounds.size.height * 0.56 &&
            cy < bounds.size.height * 0.90) {
            return root;
        }
    }
    for (UIView *sub in root.subviews) {
        found = FindGeometricDelete(sub, bounds, depth + 1, found);
        if (found) return found;
    }
    return found;
}

static void ConfigureDeleteControl(UIView *v) {
    if (objc_getAssociatedObject(v, &kDelKey1)) return;
    objc_setAssociatedObject(v, &kDelKey1, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.isAccessibilityElement = YES;
    v.accessibilityLabel = @"删除";
    v.accessibilityTraits = UIAccessibilityTraitButton | UIAccessibilityTraitAllowsDirectInteraction;

    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:[A11yDel shared] action:@selector(tap:)];
    t.cancelsTouchesInView = NO;
    [v addGestureRecognizer:t];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[A11yDel shared] action:@selector(longPress:)];
    lp.minimumPressDuration = 0.7;
    lp.cancelsTouchesInView = NO;
    [v addGestureRecognizer:lp];
}

static UIView *gDelControl = nil;

static void ScanDeleteAt(UIView *root, int depth) {
    if (!root || depth > 14) return;
    if (LooksLikeDeleteControl(root)) {
        gDelControl = root;
        ConfigureDeleteControl(root);
        return;
    }
    for (UIView *sub in root.subviews) ScanDeleteAt(sub, depth + 1);
}

static void ScanDelete(UIWindow *win) {
    if (!win) return;
    gDelControl = nil;
    ScanDeleteAt(win, 0);
    if (!gDelControl && LooksLikeDialPad(win)) {
        UIView *g = FindGeometricDelete(win, win.bounds, 0, nil);
        if (g) {
            gDelControl = g;
            ConfigureDeleteControl(g);
        }
    }
}

static NSString *DescribeTree(UIView *v, int depth, int maxDepth) {
    if (!v || depth > maxDepth) return @"";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < depth; i++) [s appendString:@"  "];
    [s appendFormat:@"%@ frame=%@\n", NSStringFromClass([v class]), NSStringFromCGRect(v.frame)];
    for (UIView *sub in v.subviews) [s appendString:DescribeTree(sub, depth + 1, maxDepth)];
    return s;
}

static void DumpOnce(UIWindow *win) {
    if (objc_getAssociatedObject(win, &kDumpDone)) return;
    objc_setAssociatedObject(win, &kDumpDone, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *tree = DescribeTree(win, 0, 8);
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *p = [[dirs.firstObject ?: NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"a11y_dump.txt"] copy];
        [tree writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

static IMP gOrigCustomActions = NULL;

static NSArray *HookCustomActions(id self, SEL cmd) {
    NSArray *base = ((NSArray *(*)(id, SEL))gOrigCustomActions)(self, cmd);
    if (![self isKindOfClass:[UIView class]]) return base;
    UIView *v = (UIView *)self;
    NSString *label = [v accessibilityLabel];
    if (!label.length) label = [v accessibilityValue];
    NSString *digits = LongestDigits(label, 7);
    if (!digits) return base;

    LoadBlacklist();
    BOOL inBlackVC = NO;
    NSString *vcName = NearestVCName(v);
    if (vcName && [vcName isEqualToString:@"A11yBlackVC"]) inBlackVC = YES;

    NSMutableArray *arr = base ? [base mutableCopy] : [NSMutableArray array];
    for (UIAccessibilityCustomAction *a in arr) {
        if ([a isKindOfClass:[A11yAction class]]) return arr;
    }
    A11yAction *act = nil;
    if (inBlackVC || [gBlacklist containsObject:digits]) {
        act = [[A11yAction alloc] initWithName:@"删除"
                                       target:[A11yHelper shared]
                                     selector:@selector(handleAction:)];
        act.kind = 1;
    } else {
        act = [[A11yAction alloc] initWithName:@"加入黑名单"
                                       target:[A11yHelper shared]
                                     selector:@selector(handleAction:)];
        act.kind = 0;
    }
    act.digits = digits;
    [arr addObject:act];
    return arr;
}

static UIView *gBar = nil;
static UIScrollView *gBarScroll = nil;
static UIStackView *gBarStack = nil;
static NSString *gBarKey = nil;
static NSArray *gContacts = nil;
static BOOL gContactsLoaded = NO;
static BOOL gContactsLoading = NO;

static NSString *PinyinOf(NSString *s) {
    if (!s.length) return @"";
    NSMutableString *m = [s mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformMandarinLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripDiacritics, false);
    return [m lowercaseString];
}

static NSString *T9OfString(NSString *s) {
    if (!s.length) return @"";
    NSMutableString *m = [NSMutableString string];
    const char *keys = "22233344455566677778889999";
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 'a' && c <= 'z') {
            int idx = (int)(c - 'a');
            if (idx >= 0 && idx < 26) [m appendFormat:@"%c", keys[idx]];
        } else if (c >= '0' && c <= '9') {
            [m appendFormat:@"%C", c];
        }
    }
    return m;
}

static BOOL T9Contains(NSString *hay, NSString *needle) {
    if (needle.length == 0 || hay.length < needle.length) return NO;
    for (NSUInteger i = 0; i + needle.length <= hay.length; i++) {
        BOOL ok = YES;
        for (NSUInteger j = 0; j < needle.length; j++) {
            unichar q = [needle characterAtIndex:j];
            unichar h = [hay characterAtIndex:i + j];
            if (q == '1' || q == '0') continue;
            if (q != h) { ok = NO; break; }
        }
        if (ok) return YES;
    }
    return NO;
}

static void LoadContactsIfNeeded(void) {
    if (gContactsLoaded || gContactsLoading) return;
    gContactsLoading = YES;
    CNContactStore *store = [[CNContactStore alloc] init];
    [store requestAccessForEntityType:CNEntityTypeContacts
                     completionHandler:^(BOOL granted, NSError *err) {
        if (!granted) { gContactsLoading = NO; return; }
        NSArray *keys = @[CNContactGivenNameKey, CNContactFamilyNameKey,
                          CNContactPhoneNumbersKey, CNContactOrganizationNameKey];
        NSMutableArray *list = [NSMutableArray array];
        CNContactFetchRequest *req = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
        NSError *e = nil;
        [store enumerateContactsWithFetchRequest:req error:&e
                                       usingBlock:^(CNContact *c, BOOL *stop) {
            NSString *name = [NSString stringWithFormat:@"%@%@", c.familyName ?: @"", c.givenName ?: @""];
            if (name.length == 0) name = c.organizationName ?: @"";
            if (name.length == 0) return;
            NSString *t9name = T9OfString(PinyinOf(name));
            for (CNLabeledValue *lv in c.phoneNumbers) {
                NSString *num = [lv.value stringValue];
                NSString *dg = DigitsOnly(num);
                if (dg.length < 3) continue;
                [list addObject:@{@"name": name, @"num": num ?: dg, @"digits": dg, @"t9": t9name ?: @""}];
            }
        }];
        (void)e;
        gContacts = list;
        gContactsLoaded = YES;
        gContactsLoading = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            gBarKey = nil;
            if (gLastDial) RefreshBarFor(gLastDial);
        });
    }];
}

static NSArray *MatchCandidates(NSString *typed) {
    NSString *q = DigitsOnly(typed);
    if (q.length < 3 || !gContacts) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *c in gContacts) {
        if (out.count >= 30) break;
        if (T9Contains(c[@"digits"], q) || T9Contains(c[@"t9"], q)) [out addObject:c];
    }
    return out;
}

static void RemoveBar(void) {
    if (gBar) {
        [gBar removeFromSuperview];
        gBar = nil; gBarScroll = nil; gBarStack = nil;
    }
}

static UIWindow *KeyWindowNow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static void RefreshBarFor(NSString *typed) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *q = DigitsOnly(typed);
        if (q.length < 3) { RemoveBar(); gBarKey = nil; return; }
        if (gBarKey && [gBarKey isEqualToString:q] && gBar) return;
        NSArray *cands = MatchCandidates(q);
        if (cands.count == 0 && !gBar) return;
        gBarKey = q;

        UIWindow *win = KeyWindowNow();
        if (!win) return;

        if (!gBar) {
            CGFloat h = 48;
            CGFloat y = win.bounds.size.height - 320;
            gBar = [[UIView alloc] initWithFrame:CGRectMake(8, y, win.bounds.size.width - 16, h)];
            gBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
            gBar.layer.cornerRadius = 10;
            gBar.layer.borderWidth = 0.5;
            gBar.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1].CGColor;

            gBarScroll = [[UIScrollView alloc] initWithFrame:gBar.bounds];
            gBarScroll.showsHorizontalScrollIndicator = NO;

            gBarStack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, gBarScroll.bounds.size.width, 44)];
            gBarStack.axis = UILayoutConstraintAxisHorizontal;
            gBarStack.alignment = UIStackViewAlignmentFill;
            gBarStack.spacing = 6;
            [gBarScroll addSubview:gBarStack];
            [gBar addSubview:gBarScroll];
            [win addSubview:gBar];
        }

        for (UIView *v in [gBarStack.arrangedSubviews copy]) {
            [gBarStack removeArrangedSubview:v];
            [v removeFromSuperview];
        }

        CGFloat cursorX = 4;
        for (NSDictionary *c in cands) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            NSString *title = [NSString stringWithFormat:@"%@ %@", c[@"name"], c[@"num"]];
            [b setTitle:title forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:13];
            b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            b.accessibilityLabel = title;
            b.accessibilityTraits = UIAccessibilityTraitButton;
            static char kNumKey;
            objc_setAssociatedObject(b, &kNumKey, c[@"digits"], OBJC_ASSOCIATION_COPY_NONATOMIC);
            [b addTarget:[A11yHelper shared] action:@selector(tapCandidate:) forControlEvents:UIControlEventTouchUpInside];
            CGFloat w = MAX(96, [title sizeWithAttributes:@{NSFontAttributeName:b.titleLabel.font}].width + 22);
            b.frame = CGRectMake(cursorX, 2, w, 44);
            cursorX += w + 6;
            [gBarStack addArrangedSubview:b];
        }
        gBarStack.frame = CGRectMake(0, 0, MAX(cursorX, gBarScroll.bounds.size.width), 44);
        gBarScroll.contentSize = gBarStack.frame.size;
    });
}

static void AttachBlacklistEntry(void) {
    UIWindow *win = KeyWindowNow();
    UIViewController *top = win.rootViewController;
    if (!top) return;
    while (top.presentedViewController) top = top.presentedViewController;
    if (![top isKindOfClass:[UINavigationController class]]) return;
    UINavigationController *nav = (UINavigationController *)top;
    UIViewController *vc = nav.topViewController;
    NSString *name = NSStringFromClass([vc class]);
    if ([name rangeOfString:@"Set" options:NSCaseInsensitiveSearch].location == NSNotFound) return;
    if ([nav.navigationItem.rightBarButtonItem.accessibilityLabel isEqualToString:@"黑名单"]) return;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"黑名单"
                                                            style:UIBarButtonItemStylePlain
                                                           target:[A11yHelper shared]
                                                           action:@selector(openBlacklist)];
    item.accessibilityLabel = @"黑名单";
    [nav.navigationItem setRightBarButtonItem:item animated:NO];
}

__attribute__((constructor)) static void A11yInit(void) {
    Class UILabel_ = objc_getClass("UILabel");
    Class UITextField_ = objc_getClass("UITextField");
    InstallTextHook(UILabel_, &gOrigSetText, (IMP)HookSetText, "setText:");
    InstallTextHook(UILabel_, &gOrigSetAttrText, (IMP)HookSetAttrText, "setAttributedText:");
    InstallTextHook(UITextField_, &gOrigTFSetText, (IMP)HookTFSetText, "setText:");

    Class UIView_ = objc_getClass("UIView");
    if (UIView_) {
        Method m = class_getInstanceMethod(UIView_, NSSelectorFromString(@"accessibilityCustomActions"));
        if (m) gOrigCustomActions = method_setImplementation(m, (IMP)HookCustomActions);
    }

    LoadBlacklist();
    LoadContactsIfNeeded();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = KeyWindowNow();
        ScanDelete(w);
        DumpOnce(w);
        AttachBlacklistEntry();
    });

    for (int i = 0; i < 10; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.5 + i * 1.5) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ScanDelete(KeyWindowNow());
            AttachBlacklistEntry();
        });
    }
}
