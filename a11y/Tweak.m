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

static BOOL HasLatinLetter(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return YES;
    }
    return NO;
}

// 规则：中英混排只留中文段（「顶部 (Top)」→「顶部」）；纯英文多词整行丢弃（分组标题、页脚说明）；
// 纯英文单词保留（拨号键上的 ABC、DEF 不能被清掉）；纯数字/符号串保留。
static NSString *FilterEnglish(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return raw;
    if (!HasLatinLetter(raw)) return raw;

    if (HasNonASCII(raw)) {
        static NSCharacterSet *seps = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            seps = [NSCharacterSet characterSetWithCharactersInString:@"/|.\n\r()（）"];
        });
        NSArray *parts = [raw componentsSeparatedByCharactersInSet:seps];
        NSMutableArray *keep = [NSMutableArray array];
        for (NSString *p in parts) {
            if (!HasLatinLetter(p)) {
                NSString *t = TrimStr(p);
                if (t.length) [keep addObject:t];
            }
        }
        if (keep.count == 0) return @"";
        return TrimStr([keep componentsJoinedByString:@" "]);
    }

    // 纯英文：两个词以上视为说明/标题整行丢弃
    NSArray *words = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger real = 0;
    for (NSString *w in words) if (TrimStr(w).length) real++;
    return real >= 2 ? @"" : raw;
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

// ==================== 日志 ====================
static NSString *DocDir(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return dirs.count ? dirs[0] : NSTemporaryDirectory();
}

static BOOL gLogEnabled = NO;      // 默认关闭，设置页「日志」里可打开
static NSObject *gLogLock = nil;

static NSString *LogPathNow(void) {
    return [DocDir() stringByAppendingPathComponent:@"a11y.log"];
}

static void LoadLogPref(void) {
    gLogEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"a11y.logEnabled"];
}

static void SaveLogPref(void) {
    [[NSUserDefaults standardUserDefaults] setBool:gLogEnabled forKey:@"a11y.logEnabled"];
}

static void A11yLog(NSString *fmt, ...) {
    if (!gLogEnabled) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (msg.length == 0) return;
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    if (!gLogLock) gLogLock = [[NSObject alloc] init];
    @synchronized (gLogLock) {
        NSString *p = LogPathNow();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *at = [fm attributesOfItemAtPath:p error:NULL];
        if (at && [[at objectForKey:NSFileSize] unsignedLongLongValue] > 262144) {
            [fm removeItemAtPath:[p stringByAppendingString:@".1"] error:NULL];
            [fm moveItemAtPath:p toPath:[p stringByAppendingString:@".1"] error:NULL];
            at = nil;
        }
        if (!at) {
            [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {}
        [fh closeFile];
    }
}

static NSArray *LogFiles(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *all = [fm contentsOfDirectoryAtPath:DocDir() error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in all) {
        if (![n hasPrefix:@"a11y"]) continue;
        if (!([n hasSuffix:@".log"] || [n hasSuffix:@".log.1"] || [n hasSuffix:@".txt"])) continue;
        NSString *p = [DocDir() stringByAppendingPathComponent:n];
        NSDictionary *at = [fm attributesOfItemAtPath:p error:NULL];
        NSNumber *size = at ? [at objectForKey:NSFileSize] : @0;
        NSDate *mod = at ? [at objectForKey:NSFileModificationDate] : nil;
        [out addObject:@{@"name": n, @"path": p, @"size": size, @"mod": mod ?: [NSDate date]}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"mod"] compare:a[@"mod"]];
    }];
    return out;
}

@interface A11yAction : UIAccessibilityCustomAction
@property (nonatomic, copy) NSString *digits;
@property (nonatomic, assign) NSInteger kind;
@end

@implementation A11yAction
@end

// 日志页用的自定义动作（带文件路径，避免被黑名单动作 hook 干扰）
@interface A11yFileAction : UIAccessibilityCustomAction
@property (nonatomic, copy) NSString *path;
@end

@implementation A11yFileAction
@end

static NSString *WriteDumpNow(UIWindow *win);

@interface A11yLogVC : UITableViewController
@property (nonatomic, strong) NSMutableArray *files;
@end

@implementation A11yLogVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = @"日志";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(closeSelf)];
    [self reloadFiles];
}

- (void)closeSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reloadFiles {
    self.files = [LogFiles() mutableCopy];
    [self.tableView reloadData];
}

- (NSString *)sizeText:(NSNumber *)n {
    double b = n ? n.doubleValue : 0;
    if (b < 1024) return [NSString stringWithFormat:@"%.0f 字节", b];
    if (b < 1048576) return [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", b / 1048576.0];
}

- (void)switchChanged:(UISwitch *)sw {
    gLogEnabled = sw.on;
    SaveLogPref();
    EnqueueAnnounce(sw.on ? @"已开启，日志开始记录" : @"已关闭，日志停止记录");
    if (sw.on) A11yLog(@"日志开关：开启");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"开关";
    if (s == 1) return @"日志文件";
    return @"操作";
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return (NSInteger)self.files.count;
    return 3;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"logcell";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    cell.accessoryView = nil;
    cell.accessibilityCustomActions = nil;
    cell.accessibilityHint = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.accessibilityLabel = nil;

    if (ip.section == 0) {
        cell.textLabel.text = @"记录日志";
        cell.detailTextLabel.text = @"关闭时不写日志，不影响使用";
        cell.accessibilityLabel = @"记录日志";
        cell.accessibilityTraits = UIAccessibilityTraitNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = gLogEnabled;
        sw.accessibilityLabel = @"记录日志";
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (ip.section == 1) {
        NSDictionary *f = self.files[(NSUInteger)ip.row];
        NSString *size = [self sizeText:f[@"size"]];
        cell.textLabel.text = f[@"name"];
        cell.detailTextLabel.text = size;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", f[@"name"], size];
        cell.accessibilityHint = @"双击分享";
        A11yFileAction *a = [[A11yFileAction alloc] initWithName:@"删除日志"
                                                          target:self
                                                        selector:@selector(deleteFileAction:)];
        a.path = f[@"path"];
        cell.accessibilityCustomActions = @[a];
        return cell;
    }

    if (ip.row == 0) {
        cell.textLabel.text = @"发送全部日志";
        cell.accessibilityLabel = @"发送全部日志";
    } else if (ip.row == 1) {
        cell.textLabel.text = @"清空全部日志";
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.accessibilityLabel = @"清空全部日志";
    } else {
        cell.textLabel.text = @"生成界面快照";
        cell.detailTextLabel.text = @"记录当前界面控件结构，排查用";
        cell.accessibilityLabel = @"生成界面快照";
    }
    return cell;
}

- (void)fileURLs:(NSArray *)files completion:(void (^)(NSArray *))done {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSDictionary *f in files) {
        NSString *p = f[@"path"];
        if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [urls addObject:[NSURL fileURLWithPath:p]];
        }
    }
    done(urls);
}

- (void)shareFiles:(NSArray *)files cell:(UITableViewCell *)cell {
    if (files.count == 0) {
        EnqueueAnnounce(@"没有可发送的日志");
        return;
    }
    [self fileURLs:files completion:^(NSArray *urls) {
        if (urls.count == 0) { EnqueueAnnounce(@"没有可发送的日志"); return; }
        UIActivityViewController *avc =
            [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
        avc.popoverPresentationController.sourceView = cell ?: self.view;
        avc.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
        [self presentViewController:avc animated:YES completion:nil];
        A11yLog(@"发送日志 %lu 个", (unsigned long)urls.count);
    }];
}

- (void)deleteFileAction:(A11yFileAction *)a {
    NSString *path = a.path;
    if (path.length == 0) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [self reloadFiles];
    EnqueueAnnounce([NSString stringWithFormat:@"已删除日志 %@", [path lastPathComponent]]);
}

- (void)deleteFileAt:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.files.count) return;
    NSDictionary *f = self.files[(NSUInteger)ip.row];
    [[NSFileManager defaultManager] removeItemAtPath:f[@"path"] error:NULL];
    [self.files removeObjectAtIndex:(NSUInteger)ip.row];
    [self.tableView deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
    EnqueueAnnounce([NSString stringWithFormat:@"已删除日志 %@", f[@"name"]]);
}

- (void)clearAll {
    for (NSDictionary *f in self.files) {
        [[NSFileManager defaultManager] removeItemAtPath:f[@"path"] error:NULL];
    }
    [self reloadFiles];
    EnqueueAnnounce(@"日志已全部清空");
}

- (void)makeSnapshot {
    NSString *p = WriteDumpNow(KeyWindowNow());
    [self reloadFiles];
    EnqueueAnnounce(p.length ? @"界面快照已生成" : @"快照生成失败");
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) return;
    UITableViewCell *cell = [t cellForRowAtIndexPath:ip];
    if (ip.section == 1) {
        if (ip.row < (NSInteger)self.files.count) [self shareFiles:@[self.files[(NSUInteger)ip.row]] cell:cell];
        return;
    }
    if (ip.row == 0) [self shareFiles:self.files cell:cell];
    else if (ip.row == 1) [self clearAll];
    else [self makeSnapshot];
}

- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)s
 forRowAtIndexPath:(NSIndexPath *)ip {
    if (s == UITableViewCellEditingStyleDelete && ip.section == 1) [self deleteFileAt:ip];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)t editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

@end

@interface A11yHelper : NSObject
+ (instancetype)shared;
- (BOOL)handleAction:(UIAccessibilityCustomAction *)action;
- (void)tapCandidate:(UIButton *)sender;
- (void)openBlacklist;
- (void)openLogs;
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
        A11yLog(@"加入黑名单 %@，现有 %lu 条", digits, (unsigned long)gBlacklist.count);
        EnqueueAnnounce([NSString stringWithFormat:@"已加入黑名单 %@", digits]);
    } else {
        [gBlacklist removeObject:digits];
        SaveBlacklist();
        A11yLog(@"移出黑名单 %@，现有 %lu 条", digits, (unsigned long)gBlacklist.count);
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

- (void)presentModal:(UIViewController *)vc {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = KeyWindowNow().rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if ([top isKindOfClass:[UINavigationController class]])
            top = ((UINavigationController *)top).topViewController;
        if (!top) return;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

- (void)openBlacklist {
    [self presentModal:[[A11yBlackVC alloc] init]];
}

- (void)openLogs {
    [self presentModal:[[A11yLogVC alloc] init]];
}

@end

static IMP gOrigSetText = NULL;
static IMP gOrigSetAttrText = NULL;
static IMP gOrigTFSetText = NULL;

// 只认号码输入框本身。原生下方那排「会员 235 号…」是 UILabel，它的文字被当成输入过几次，
// 导致删除时号码取错、候选反复刷新，这里直接不再采信 UILabel。
static void TrackDial(id self, NSString *text) {
    if (![self isKindOfClass:[UITextField class]]) return;
    if (!LooksLikeDial(text) || text.length == 0) {
        gLastDial = @"";
        RefreshBarFor(@"");
        return;
    }
    gLastDial = text;
    gDialField = (UITextField *)self;
    A11yLog(@"拨号文本：%@", text);
    RefreshBarFor(text);
}

static BOOL gFooterReused = NO;   // 保留占位，不做页脚改造

static void HookSetText(id self, SEL cmd, NSString *text) {
    NSString *t = text;
    if ([t isKindOfClass:[NSString class]]) {
        TrackDial(self, t);
        if ([self isKindOfClass:[UILabel class]]) {
            NSString *f = FilterEnglish(t);
            if (f && ![f isEqualToString:t]) {
                A11yLog(@"英文清理：%@ -> %@", t, f);
                t = f;
            }
        }
    }
    ((void (*)(id, SEL, NSString *))gOrigSetText)(self, cmd, t);
}

static void HookSetAttrText(id self, SEL cmd, NSAttributedString *text) {
    NSAttributedString *t = text;
    if ([t isKindOfClass:[NSAttributedString class]] && [self isKindOfClass:[UILabel class]]) {
        NSString *s = t.string;
        NSString *f = FilterEnglish(s);
        if (f && ![f isEqualToString:s]) {
            A11yLog(@"英文清理(富文本)：%@ -> %@", s, f);
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
    UITextField *f = gDialField;
    NSString *cur = f.text.length ? f.text : gLastDial;
    cur = cur ?: @"";
    if (cur.length == 0) {
        EnqueueAnnounce(@"号码已空");
        A11yLog(@"删除键命中，当前已空");
        return;
    }
    NSString *after = [cur substringToIndex:cur.length - 1];
    if (f) {
        f.text = after;
        [f sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    gLastDial = after;
    if (after.length == 0) EnqueueAnnounce(@"号码已清空");
    else EnqueueAnnounce([NSString stringWithFormat:@"已删除，当前 %@", after]);
    A11yLog(@"删除键命中，剩 %@", after);
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

// 拨号键是 TPDialerNumberPad 里自绘的，label.text 往往为空，靠数字 label 计数会永远为 0。
// 改为：类名带 NumberPad / KeyPad，或页面上有 ≥8 个 60~120pt 的方形可交互控件。
static NSUInteger CountSquareControls(UIView *root, NSUInteger limit, int depth) {
    if (!root || depth > 14 || limit == 0) return 0;
    NSUInteger n = 0;
    if ([root isKindOfClass:[UIControl class]]) {
        CGSize s = root.bounds.size;
        if (s.width >= 60 && s.width <= 120 && s.height >= 60 && s.height <= 120) n++;
    }
    for (UIView *sub in root.subviews) {
        n += CountSquareControls(sub, limit - n, depth + 1);
        if (n >= limit) return n;
    }
    return n;
}

static BOOL HasClassFrag(UIView *root, NSString *frag, int depth) {
    if (!root || depth > 14) return NO;
    if ([NSStringFromClass([root class]) rangeOfString:frag options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
    for (UIView *sub in root.subviews) {
        if (HasClassFrag(sub, frag, depth + 1)) return YES;
    }
    return NO;
}

static BOOL LooksLikeDialPad(UIWindow *win) {
    if (!win) return NO;
    if (HasClassFrag(win, @"NumberPad", 0) || HasClassFrag(win, @"KeyPad", 0)) return YES;
    return CountSquareControls(win, 8, 0) >= 8;
}

static BOOL LooksLikeDeleteControl(UIView *v) {
    NSString *cls = NSStringFromClass([v class]);
    if ([cls rangeOfString:@"Delete" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [cls rangeOfString:@"Backspace" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return YES;
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
    t.cancelsTouchesInView = YES;   // 由我们独占处理，避免原生按钮再删一次造成双删
    [v addGestureRecognizer:t];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[A11yDel shared] action:@selector(longPress:)];
    lp.minimumPressDuration = 0.7;
    lp.cancelsTouchesInView = YES;
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
    BOOL byGeom = NO;
    if (!gDelControl && LooksLikeDialPad(win)) {
        UIView *g = FindGeometricDelete(win, win.bounds, 0, nil);
        if (g) {
            gDelControl = g;
            byGeom = YES;
            ConfigureDeleteControl(g);
        }
    }
    if (gDelControl) {
        A11yLog(@"删除键命中：%@ frame=%@ 方式=%@", NSStringFromClass([gDelControl class]),
                NSStringFromCGRect([gDelControl convertRect:gDelControl.bounds toView:nil]),
                byGeom ? @"几何兜底" : @"标签");
    } else {
        A11yLog(@"删除键未命中，拨号盘判定=%d", LooksLikeDialPad(win));
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

static NSString *WriteDumpNow(UIWindow *win) {
    if (!win) return nil;
    NSString *tree = DescribeTree(win, 0, 10);
    NSString *p = [DocDir() stringByAppendingPathComponent:@"a11y_dump.txt"];
    BOOL ok = [tree writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    A11yLog(@"界面快照 %@ 写入%@", NSStringFromCGSize(win.bounds.size), ok ? @"成功" : @"失败");
    return ok ? p : nil;
}

static void DumpOnce(UIWindow *win) {
    if (objc_getAssociatedObject(win, &kDumpDone)) return;
    objc_setAssociatedObject(win, &kDumpDone, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gLogEnabled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WriteDumpNow(win);
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
        if ([a isKindOfClass:[A11yFileAction class]]) return arr;
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
        if (!granted) { gContactsLoading = NO; A11yLog(@"通讯录未授权"); return; }
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
        A11yLog(@"通讯录载入 %lu 个号码", (unsigned long)list.count);
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
        A11yLog(@"候选刷新 输入=%@ 命中=%lu 条 联系人库=%lu", q, (unsigned long)cands.count,
                (unsigned long)gContacts.count);
        if (cands.count == 0 && !gBar) return;
        gBarKey = q;

        UIWindow *win = KeyWindowNow();
        if (!win) return;

        // 候选条贴在号码输入区正下方（和原生那行「会员 235 号…」同一块区域），不再沉到底部
        CGFloat h = 44;
        CGFloat y = win.bounds.size.height - 320;
        if (gDialField) {
            UIView *box = gDialField.superview ? gDialField.superview : gDialField;
            CGRect r = [box convertRect:box.bounds toView:win];
            if (r.size.height > 0 && r.size.height < 400)
                y = CGRectGetMaxY(r) + 4;
        }
        CGRect barFrame = CGRectMake(8, y, win.bounds.size.width - 16, h);

        if (!gBar) {
            gBar = [[UIView alloc] initWithFrame:barFrame];
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
        gBar.frame = barFrame;   // 输入区位置变了就跟着走
    });
}

static char kFloatKey;

static NSUInteger CountSwitches(UIView *root, int depth) {
    if (!root || depth > 16) return 0;
    NSUInteger n = [root isKindOfClass:[UISwitch class]] ? 1 : 0;
    for (UIView *s in root.subviews) n += CountSwitches(s, depth + 1);
    return n;
}

// 设置页兜底入口：导航栏挂不上时，直接在设置页右上角放「日志」「黑名单」两个按钮
static void AttachFloatingEntries(void) {
    UIWindow *win = KeyWindowNow();
    if (!win) return;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]])
        top = ((UINavigationController *)top).topViewController;
    UIView *root = top.view;
    if (!root) return;
    if (CountSwitches(root, 0) < 6) return;
    if (objc_getAssociatedObject(root, &kFloatKey)) return;
    objc_setAssociatedObject(root, &kFloatKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat h = 34, y = 64, x = root.bounds.size.width;
    UIButton *blk = [UIButton buttonWithType:UIButtonTypeSystem];
    blk.frame = CGRectMake(x - 78 - 8, y, 78, h);
    [blk setTitle:@"黑名单" forState:UIControlStateNormal];
    blk.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    blk.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    blk.layer.cornerRadius = 8;
    blk.layer.borderWidth = 0.5;
    blk.layer.borderColor = [UIColor colorWithWhite:0.7 alpha:1].CGColor;
    blk.accessibilityLabel = @"黑名单";
    blk.accessibilityTraits = UIAccessibilityTraitButton;
    [blk addTarget:[A11yHelper shared] action:@selector(openBlacklist) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:blk];

    UIButton *log = [UIButton buttonWithType:UIButtonTypeSystem];
    log.frame = CGRectMake(x - 78 - 8 - 60 - 6, y, 60, h);
    [log setTitle:@"日志" forState:UIControlStateNormal];
    log.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    log.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    log.layer.cornerRadius = 8;
    log.layer.borderWidth = 0.5;
    log.layer.borderColor = [UIColor colorWithWhite:0.7 alpha:1].CGColor;
    log.accessibilityLabel = @"日志";
    log.accessibilityTraits = UIAccessibilityTraitButton;
    [log addTarget:[A11yHelper shared] action:@selector(openLogs) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:log];

    A11yLog(@"设置页放上浮动入口（开关数=%lu）", (unsigned long)CountSwitches(root, 0));
}

static void AttachSettingsEntries(void) {
    UIWindow *win = KeyWindowNow();
    UIViewController *top = win.rootViewController;
    if (!top) return;
    while (top.presentedViewController) top = top.presentedViewController;
    if (![top isKindOfClass:[UINavigationController class]]) return;
    UINavigationController *nav = (UINavigationController *)top;
    UIViewController *vc = nav.topViewController;
    NSString *name = NSStringFromClass([vc class]);
    if ([name rangeOfString:@"Set" options:NSCaseInsensitiveSearch].location == NSNotFound) return;

    UIBarButtonItem *blk = nil, *logs = nil;
    for (UIBarButtonItem *it in nav.navigationItem.rightBarButtonItems) {
        NSString *l = it.accessibilityLabel;
        if ([l isEqualToString:@"黑名单"]) blk = it;
        else if ([l isEqualToString:@"日志"]) logs = it;
    }
    if (blk && logs) return;

    if (!blk) {
        blk = [[UIBarButtonItem alloc] initWithTitle:@"黑名单"
                                               style:UIBarButtonItemStylePlain
                                              target:[A11yHelper shared]
                                              action:@selector(openBlacklist)];
        blk.accessibilityLabel = @"黑名单";
        A11yLog(@"设置页挂上黑名单入口");
    }
    if (!logs) {
        logs = [[UIBarButtonItem alloc] initWithTitle:@"日志"
                                                style:UIBarButtonItemStylePlain
                                               target:[A11yHelper shared]
                                               action:@selector(openLogs)];
        logs.accessibilityLabel = @"日志";
        A11yLog(@"设置页挂上日志入口");
    }
    NSMutableArray *items = [NSMutableArray arrayWithObject:blk];
    [items addObject:logs];
    for (UIBarButtonItem *it in nav.navigationItem.rightBarButtonItems) {
        if (it != blk && it != logs) [items addObject:it];
    }
    [nav.navigationItem setRightBarButtonItems:items animated:NO];
}


// ---- v6：最近通话行加“加入黑名单”按钮 + 呼入/呼出方向播报 ----

extern id UIAccessibilityFocusedUIElement(unsigned int notification);

static UITableView *FindFirstTable(UIView *root, int depth) {
    if (!root || depth > 12) return nil;
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *s in root.subviews) {
        UITableView *t = FindFirstTable(s, depth + 1);
        if (t) return t;
    }
    return nil;
}

static IMP gOrigA11yLabel = NULL;

// 读原始 accessibilityLabel，不经过我们自己的 hook，避免递归
static NSString *RawA11yLabel(UIView *v) {
    if (!v || !gOrigA11yLabel) return nil;
    id r = ((id (*)(id, SEL))gOrigA11yLabel)(v, @selector(accessibilityLabel));
    return [r isKindOfClass:[NSString class]] ? (NSString *)r : nil;
}

static NSString *DirectionOf(UIView *root, int depth) {
    if (!root || depth > 8) return nil;
    NSString *l = RawA11yLabel(root);
    if (l.length) {
        if ([l rangeOfString:@"未接"].location != NSNotFound) return @"未接";
        if ([l rangeOfString:@"呼入"].location != NSNotFound) return @"呼入";
        if ([l rangeOfString:@"呼出"].location != NSNotFound) return @"呼出";
    }
    if ([root isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)root).text;
        if (t.length) {
            if ([t rangeOfString:@"未接"].location != NSNotFound) return @"未接";
            if ([t rangeOfString:@"呼入"].location != NSNotFound) return @"呼入";
            if ([t rangeOfString:@"呼出"].location != NSNotFound) return @"呼出";
        }
    }
    for (UIView *s in root.subviews) {
        NSString *d = DirectionOf(s, depth + 1);
        if (d) return d;
    }
    return nil;
}

static id HookA11yLabel(id self, SEL cmd) {
    id base = ((id (*)(id, SEL))gOrigA11yLabel)(self, cmd);
    if (![self isKindOfClass:[UIView class]]) return base;
    NSString *s = [base isKindOfClass:[NSString class]] ? (NSString *)base : nil;
    if (!s.length) return base;
    if ([s rangeOfString:@"黑名单"].location != NSNotFound) return base;
    NSString *digits = LongestDigits(s, 7);
    if (!digits) return base;
    NSString *dir = DirectionOf((UIView *)self, 0);
    if (!dir) return base;
    if ([s rangeOfString:dir].location != NSNotFound) return base;
    return [NSString stringWithFormat:@"%@ %@", dir, s];
}

static void InstallA11yLabelHook(void) {
    Class UIView_ = objc_getClass("UIView");
    if (!UIView_) return;
    Method m = class_getInstanceMethod(UIView_, @selector(accessibilityLabel));
    if (m) gOrigA11yLabel = method_setImplementation(m, (IMP)HookA11yLabel);
}

static void AddToBlacklistNow(NSString *digits) {
    if (digits.length == 0) return;
    if (!gBlacklist) gBlacklist = [NSMutableArray array];
    if (![gBlacklist containsObject:digits]) [gBlacklist addObject:digits];
    NSString *p = [DocDir() stringByAppendingPathComponent:@"a11y_blacklist.plist"];
    [gBlacklist writeToFile:p atomically:YES];
}

@interface A11yBlkBtn : NSObject
+ (instancetype)shared;
- (void)ask;
@end

@implementation A11yBlkBtn
+ (instancetype)shared { static A11yBlkBtn *o; static dispatch_once_t t; dispatch_once(&t, ^{ o = [A11yBlkBtn new]; }); return o; }

- (void)ask {
    UIViewController *vc = KeyWindowNow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
    if (!vc) return;

    NSString *digits = nil;
    id focused = UIAccessibilityFocusedUIElement(1000);
    if (focused && [focused isKindOfClass:[UIView class]]) digits = LongestDigits(RawA11yLabel((UIView *)focused), 7);
    if (!digits) {
        UITableView *tv = FindFirstTable(vc.view, 0);
        for (UITableViewCell *c in [tv visibleCells]) {
            NSString *d = LongestDigits(RawA11yLabel(c), 7);
            if (d) { digits = d; break; }
        }
    }
    if (!digits) { EnqueueAnnounce(@"没有找到号码，请先把焦点放到某条通话记录上"); return; }

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"加入黑名单"
                                                               message:[NSString stringWithFormat:@"号码 %@", digits]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        AddToBlacklistNow(digits);
        A11yLog(@"手动加入黑名单 %@", digits);
        EnqueueAnnounce([NSString stringWithFormat:@"已加入黑名单 %@", digits]);
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:al animated:YES completion:nil];
}
@end

static char kBlkBtnKey;

static void AttachBlacklistButton(void) {
    UIWindow *win = KeyWindowNow();
    if (!win) return;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]])
        top = ((UINavigationController *)top).topViewController;
    UIView *root = top.view;
    if (!root) return;
    if (objc_getAssociatedObject(root, &kBlkBtnKey)) return;
    UITableView *tv = FindFirstTable(root, 0);
    if (!tv) return;
    NSInteger rows = 0;
    for (UITableViewCell *c in [tv visibleCells]) {
        if (LongestDigits(RawA11yLabel(c), 7)) rows++;
    }
    if (rows < 2) return;
    objc_setAssociatedObject(root, &kBlkBtnKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    CGFloat w = 132, h = 40;
    CGFloat y = root.bounds.size.height - 83 - 56;
    b.frame = CGRectMake(root.bounds.size.width - w - 12, y, w, h);
    [b setTitle:@"加入黑名单" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.94];
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 0.5;
    b.layer.borderColor = [UIColor colorWithWhite:0.7 alpha:1].CGColor;
    b.accessibilityLabel = @"加入黑名单";
    b.accessibilityTraits = UIAccessibilityTraitButton;
    [b addTarget:[A11yBlkBtn shared] action:@selector(ask) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:b];
    A11yLog(@"最近通话页放上加入黑名单按钮（行数=%ld）", (long)rows);
}

__attribute__((constructor)) static void A11yInit(void) {
    Class UILabel_ = objc_getClass("UILabel");
    Class UITextField_ = objc_getClass("UITextField");
    InstallTextHook(UILabel_, &gOrigSetText, (IMP)HookSetText, "setText:");
    InstallTextHook(UILabel_, &gOrigSetAttrText, (IMP)HookSetAttrText, "setAttributedText:");
    InstallTextHook(UITextField_, &gOrigTFSetText, (IMP)HookTFSetText, "setText:");
    InstallA11yLabelHook();

    Class UIView_ = objc_getClass("UIView");
    if (UIView_) {
        Method m = class_getInstanceMethod(UIView_, NSSelectorFromString(@"accessibilityCustomActions"));
        if (m) gOrigCustomActions = method_setImplementation(m, (IMP)HookCustomActions);
    }

    LoadBlacklist();
    LoadLogPref();
    LoadContactsIfNeeded();
    gFooterReused = NO;

    // 加载探针：无论日志开关是否打开，都写一个标记文件并播报一次
    NSString *boot = [NSString stringWithFormat:@"CallA11y v4 已加载 %@\n", [NSDate date]];
    [boot writeToFile:[DocDir() stringByAppendingPathComponent:@"a11y_boot.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"无障碍补丁已加载");
    });
    A11yLog(@"CallA11y v4 载入，日志开关=%d", gLogEnabled);

    // 常驻巡检：拨号盘和设置页可能随时才出现，不再只盯前 15 秒
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        ScanDelete(KeyWindowNow());
        AttachSettingsEntries();
        AttachFloatingEntries();
        AttachBlacklistButton();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}
