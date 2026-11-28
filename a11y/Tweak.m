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
    if (raw.length > 400) return raw;   // 超长文本（整段网页/日志）不动，避免误清空并拖慢 UI
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
static NSString *CellTexts(UIView *v, int depth);

static void EnqueueAnnounce(NSString *msg) {
    if (msg.length == 0) return;
    // 去掉原来的 1 秒闸门：连点时后一条会被压住，听起来就是“没提示”
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, msg);
}

// 点完列表行旁白会紧接着念单元格名，立刻播报会被它压掉，延后一点再念
static void AnnounceSoon(NSString *msg) {
    if (msg.length == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, msg);
    });
}

static void DrainQueue(void) {}

static NSString *gLastDial = nil;
static UITextField *gDialField = nil;
static NSString *gUserTyped = nil;   // 用户自己敲进去的数字，用来识别 App 的自动补全
static BOOL gAllowFullFill = NO;     // 用户主动选号（点候选）时放行一次完整号码

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
    AnnounceSoon([NSString stringWithFormat:@"日志已全部清空，还剩 %lu 个文件", (unsigned long)self.files.count]);
}

- (void)makeSnapshot {
    NSString *p = WriteDumpNow(KeyWindowNow());
    [self reloadFiles];
    AnnounceSoon(p.length ? @"界面快照已生成" : @"快照生成失败");
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
        gAllowFullFill = YES;
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
static BOOL InDialerArea(UIView *v) {
    UIView *cur = v;
    for (int i = 0; i < 10 && cur; i++, cur = cur.superview) {
        NSString *cn = NSStringFromClass([cur class]);
        if ([cn rangeOfString:@"PHHandsetDialer"].location != NSNotFound) return YES;
        if ([cn rangeOfString:@"ZSKeyPadView"].location != NSNotFound) return YES;
    }
    return NO;
}

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

static IMP gOrigTVSetText = NULL;
static IMP gOrigTVSetAttrText = NULL;

static void CleanTextForward(id self, SEL cmd, NSString *text, IMP orig) {
    NSString *t = text;
    if ([t isKindOfClass:[NSString class]]) {
        TrackDial(self, t);
        if ([self isKindOfClass:[UILabel class]] || [self isKindOfClass:[UITextView class]]) {
            NSString *f = FilterEnglish(t);
            if (f && ![f isEqualToString:t]) {
                A11yLog(@"英文清理：%@ -> %@", t, f);
                t = f;
            }
        }
    }
    ((void (*)(id, SEL, NSString *))orig)(self, cmd, t);
}

static void HookSetText(id self, SEL cmd, NSString *text) {
    CleanTextForward(self, cmd, text, gOrigSetText);
}

static void HookTVSetText(id self, SEL cmd, NSString *text) {
    CleanTextForward(self, cmd, text, gOrigTVSetText);
}

static void CleanAttrForward(id self, SEL cmd, NSAttributedString *text, IMP orig) {
    NSAttributedString *t = text;
    if ([t isKindOfClass:[NSAttributedString class]] &&
        ([self isKindOfClass:[UILabel class]] || [self isKindOfClass:[UITextView class]])) {
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
    ((void (*)(id, SEL, NSAttributedString *))orig)(self, cmd, t);
}

static void HookSetAttrText(id self, SEL cmd, NSAttributedString *text) {
    CleanAttrForward(self, cmd, text, gOrigSetAttrText);
}

static void HookTVSetAttrText(id self, SEL cmd, NSAttributedString *text) {
    CleanAttrForward(self, cmd, text, gOrigTVSetAttrText);
}

// App 在第一次按键后会往号码前面自动塞一个 0（输 1 变成 01），用户从没敲过这个 0。
// 只要当前已输入不是以 0 开头，就把新文本首位多出来的 0 去掉，再判断它是不是「用户敲的那一位」。
static NSString *StripAutoZero(NSString *newD, NSString *curD) {
    if (newD.length < 2 || ![newD hasPrefix:@"0"] || [curD hasPrefix:@"0"]) return newD;
    NSString *rest = [newD substringFromIndex:1];
    if ([rest isEqualToString:curD]) return rest;                                   // 只是重复写了 0
    if (rest.length == curD.length + 1 && [rest hasPrefix:curD]) return rest;       // 敲了新的一位
    if (rest.length + 1 == curD.length && [curD hasPrefix:rest]) return rest;       // 删了一位
    if (curD.length == 0 && rest.length == 1) return rest;                          // 第一下按键
    return newD;
}

static void HookTFSetText(id self, SEL cmd, NSString *text) {
    if (![text isKindOfClass:[NSString class]] ||
        ![self isKindOfClass:[UITextField class]] ||
        !InDialerArea((UIView *)self)) {
        ((void (*)(id, SEL, NSString *))gOrigTFSetText)(self, cmd, text);
        return;
    }
    UITextField *f = (UITextField *)self;
    NSString *rawD = DigitsOnly(text);
    NSString *curD = gUserTyped ? gUserTyped : @"";
    NSString *newD = StripAutoZero(rawD, curD);

    // 用户主动点候选选号，放行一次完整号码
    if (gAllowFullFill) {
        gAllowFullFill = NO;
        gUserTyped = newD;
        gLastDial = newD;
        gDialField = f;
        ((void (*)(id, SEL, NSString *))gOrigTFSetText)(self, cmd, newD);
        RefreshBarFor(newD);
        return;
    }

    BOOL ok = NO;
    NSString *why = @"";
    if ([newD isEqualToString:curD]) {
        ok = YES;                                 // 同一内容（格式化/非格式化两份）重复写入
    } else if (curD.length == 0) {
        ok = (newD.length == 1);                  // 第一下按键：只接受一位
        if (!ok) why = @"首键多位";
    } else if (newD.length == curD.length + 1 && [newD hasPrefix:curD]) {
        ok = YES;                                 // 用户敲了一位
    } else if (newD.length + 1 == curD.length && newD.length > 0 && [curD hasPrefix:newD]) {
        ok = YES;                                 // 用户删了一位
    } else if (newD.length == 0) {
        ok = YES;                                 // 清空
    } else if (newD.length == 1) {
        ok = YES;                                 // 重新起号：App 把旧号整体换成一位
    } else {
        why = @"跳变填充";
    }

    if (!ok) {
        // App 想往框里塞完整号码/历史号码：直接回滚成用户敲的内容
        if (![f.text isEqualToString:curD]) {
            ((void (*)(id, SEL, NSString *))gOrigTFSetText)(self, cmd, curD);
        }
        A11yLog(@"拦截自动填充：%@ -> 保持 %@（field=%@ 父=%@ %@ 原始长度%lu 新长度%lu 旧长度%lu）", text, curD,
                NSStringFromClass([f class]), NSStringFromClass([f.superview class]), why,
                (unsigned long)([text isKindOfClass:[NSString class]] ? [(NSString *)text length] : 0),
                (unsigned long)newD.length, (unsigned long)curD.length);
        gLastDial = curD;
        gDialField = f;
        RefreshBarFor(curD);
        return;
    }

    gUserTyped = newD;
    gLastDial = newD;
    gDialField = f;
    A11yLog(@"拨号文本：%@", newD);
    if (![rawD isEqualToString:newD]) {
        A11yLog(@"去掉自动补的前缀：%@ -> %@", text, newD);
    }
    // 一律按干净数字写回，输入框里只留用户敲的号码
    ((void (*)(id, SEL, NSString *))gOrigTFSetText)(self, cmd, newD);
    RefreshBarFor(newD);
}

static void InstallTextHook(Class cls, IMP *slot, IMP hook, const char *selName) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString([NSString stringWithUTF8String:selName]));
    if (!m) return;
    *slot = method_setImplementation(m, hook);
}

@interface A11yDel : NSObject
+ (instancetype)shared;
- (void)tap:(id)g;
- (void)longPress:(UILongPressGestureRecognizer *)g;
@end

@implementation A11yDel

+ (instancetype)shared {
    static A11yDel *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[A11yDel alloc] init]; });
    return s;
}

- (void)tap:(id)g {
    static NSTimeInterval lastDel = 0;
    NSTimeInterval nowTs = [NSDate timeIntervalSinceReferenceDate];
    if (nowTs - lastDel < 0.35) return;   // 单击手势与按钮事件可能同时到达，去抖保证一次只删一位
    lastDel = nowTs;
    UITextField *f = gDialField;
    NSString *cur = f.text.length ? f.text : gLastDial;
    cur = cur ?: @"";
    if (cur.length == 0) {
        EnqueueAnnounce(@"号码已空");
        return;
    }
    NSString *after = [cur substringToIndex:cur.length - 1];
    if (f) {
        // 绕过 setText 的补全拦截，直接写回，保证一次点击只减一位
        if (gOrigTFSetText)
            ((void (*)(id, SEL, NSString *))gOrigTFSetText)((id)f, @selector(setText:), after);
        [f sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    gLastDial = after;
    gUserTyped = DigitsOnly(after);
    NSString *msg = after.length ? [NSString stringWithFormat:@"删除一位，还剩 %@", after] : @"号码已清空";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, msg);
    });
    A11yLog(@"删除一位，剩 %@", after);
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

    // 手指点击只允许走一条路径：在原生删除按钮上盖一层透明按钮，原生收不到 touch，
    // 从根本上消除「点一次删两位」。
    UIButton *cover = [UIButton buttonWithType:UIButtonTypeCustom];
    cover.frame = v.bounds;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = [UIColor clearColor];
    cover.accessibilityLabel = @"删除";
    cover.accessibilityTraits = UIAccessibilityTraitButton;
    cover.isAccessibilityElement = YES;
    [cover addTarget:[A11yDel shared] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    // 原生电话按下的瞬间就删一位；这里补一条按下即删，抬手那一份会被去抖吃掉
    [cover addTarget:[A11yDel shared] action:@selector(tap:) forControlEvents:UIControlEventTouchDown];
    UITapGestureRecognizer *ct = [[UITapGestureRecognizer alloc] initWithTarget:[A11yDel shared] action:@selector(tap:)];
    [cover addGestureRecognizer:ct];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[A11yDel shared] action:@selector(longPress:)];
    lp.minimumPressDuration = 0.7;
    lp.cancelsTouchesInView = YES;
    [cover addGestureRecognizer:lp];

    v.isAccessibilityElement = NO;
    [v addSubview:cover];
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
    static NSString *lastKey = nil;
    NSString *nowKey = gDelControl ? NSStringFromClass([gDelControl class]) : @"none";
    if (!lastKey || ![lastKey isEqualToString:nowKey]) {
        lastKey = nowKey;
        if (gDelControl) {
            A11yLog(@"删除键已挂接：%@ frame=%@ 方式=%@", NSStringFromClass([gDelControl class]),
                    NSStringFromCGRect([gDelControl convertRect:gDelControl.bounds toView:nil]),
                    byGeom ? @"几何兜底" : @"标签");
        } else {
            A11yLog(@"删除键未命中，拨号盘判定=%d", LooksLikeDialPad(win));
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

static BOOL InsideTableCell(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 6 && p; i++, p = p.superview)
        if ([p isKindOfClass:[UITableViewCell class]]) return YES;
    return NO;
}

// 旁白聚焦的往往不是 cell 本身，而是行里某个子视图；所以号码要从自己、下层、上层一起找
static NSString *DigitsNear(UIView *v) {
    NSString *d = LongestDigits([v accessibilityLabel], 7);
    if (!d) d = LongestDigits([v accessibilityValue], 7);
    if (!d) d = LongestDigits(CellTexts(v, 0), 7);
    UIView *p = v.superview;
    for (int i = 0; i < 4 && !d && p; i++, p = p.superview)
        d = LongestDigits(CellTexts(p, 0), 7);
    return d;
}

static NSArray *HookCustomActions(id self, SEL cmd) {
    NSArray *base = ((NSArray *(*)(id, SEL))gOrigCustomActions)(self, cmd);
    if (![self isKindOfClass:[UIView class]]) return base;
    UIView *v = (UIView *)self;

    for (UIAccessibilityCustomAction *a in base) {
        if ([a isKindOfClass:[A11yAction class]]) return base;
        if ([a isKindOfClass:[A11yFileAction class]]) return base;
    }

    NSString *vcName = NearestVCName(v);
    BOOL inBlackVC = (vcName && [vcName isEqualToString:@"A11yBlackVC"]);
    if (!inBlackVC) {
        if (!InsideTableCell(v)) return base;
        // 只给旁白真正会聚焦的元素挂，避免整行每个子视图都多出一条
        BOOL focusable = v.isAccessibilityElement ||
                         ([v accessibilityLabel].length > 0) ||
                         (([v accessibilityTraits] & UIAccessibilityTraitButton) != 0);
        if (!focusable) return base;
    }

    NSString *digits = DigitsNear(v);
    if (!digits) return base;

    LoadBlacklist();
    NSMutableArray *arr = base ? [base mutableCopy] : [NSMutableArray array];
    A11yAction *act = nil;
    if (inBlackVC || (gBlacklist && [gBlacklist containsObject:digits])) {
        act = [[A11yAction alloc] initWithName:@"移出黑名单"
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
        if (cands.count == 0) {
            RemoveBar();
            gBarKey = q;
            A11yLog(@"候选为空 输入=%@", q);
            return;
        }
        gBarKey = q;

        // App 有自己的视图层级和重排逻辑，挂在 rootViewController.view 上会被它的视图盖住/被重排带走；
        // 直接挂到 window 本身，window 的子视图永远在所有控制器视图之上。
        UIWindow *win = gDialField.window ? gDialField.window : KeyWindowNow();
        if (!win) return;
        UIView *host = win;

        CGFloat h = 44;
        CGFloat y = host.bounds.size.height - 320;
        if (gDialField) {
            UIView *box = gDialField.superview;
            CGRect rb = box ? [box convertRect:box.bounds toView:host] : CGRectZero;
            CGRect r = [gDialField convertRect:gDialField.bounds toView:host];
            if (rb.size.height > 0 && rb.size.height < 400 && CGRectGetMaxY(rb) > CGRectGetMaxY(r))
                y = CGRectGetMaxY(rb) + 2;   // 排在原生「会员 235 号…」那一行的下面
            else if (r.size.height > 0 && r.size.width > 0)
                y = CGRectGetMaxY(r) + 2;
        }
        CGRect barFrame = CGRectMake(8, y, host.bounds.size.width - 16, h);

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
            [host addSubview:gBar];
        }
        if (gBar.superview != host) {
            [gBar removeFromSuperview];
            [host addSubview:gBar];
        }
        [host bringSubviewToFront:gBar];
        A11yLog(@"候选条落位 host=%@ frame=%@", NSStringFromClass([host class]), NSStringFromCGRect(barFrame));

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

extern void *dlsym(void *handle, const char *symbol);
#define kRTLDDefault ((void *)-2L)

// 运行时取 VoiceOver 当前焦点元素；符号不可用时返回 nil，走表格行兜底
static id FocusedElementNow(void) {
    static id (*fn)(unsigned int) = NULL;
    static int tried = 0;
    if (!tried) { tried = 1; fn = (id (*)(unsigned int))dlsym(kRTLDDefault, "UIAccessibilityFocusedUIElement"); }
    return fn ? fn(1000) : nil;
}

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
    id focused = FocusedElementNow();
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
static UIButton *gBlkBtn = nil;

static UITabBar *FindTabBar(UIView *root, int depth) {
    if (!root || depth > 12) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return (UITabBar *)root;
    for (UIView *s in root.subviews) {
        UITabBar *t = FindTabBar(s, depth + 1);
        if (t) return t;
    }
    return nil;
}

static BOOL HasRecentCallsHint(UIView *root, int depth) {
    if (!root || depth > 14) return NO;
    if ([root isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)root).text;
        if (t.length) {
            if ([t rangeOfString:@"今天"].location != NSNotFound ||
                [t rangeOfString:@"昨天"].location != NSNotFound ||
                [t rangeOfString:@"星期"].location != NSNotFound) return YES;
        }
    }
    for (UIView *s in root.subviews) if (HasRecentCallsHint(s, depth + 1)) return YES;
    return NO;
}

// 只在「最近通话」页挂按钮：拨号盘/通讯录/收藏/语音留言一律不挂
static BOOL LooksLikeSettings(UIView *root, int depth) {
    if (!root || depth > 12) return NO;
    NSString *cn = NSStringFromClass([root class]);
    if ([cn hasPrefix:@"PS"] || [cn rangeOfString:@"Switch"].location != NSNotFound) return YES;
    for (UIView *s in root.subviews) if (LooksLikeSettings(s, depth + 1)) return YES;
    return NO;
}

static BOOL IsRecentCallsPage(UIView *root) {
    if (HasClassFrag(root, @"DialerNumberPad", 0)) return NO;
    if (HasClassFrag(root, @"ZSKeyPadView", 0)) return NO;
    if (LooksLikeSettings(root, 0)) return NO;
    UITabBar *tb = FindTabBar(root, 0);
    if (tb && tb.selectedItem) {
        NSString *t = tb.selectedItem.title;
        if (!t.length) t = tb.selectedItem.accessibilityLabel;
        if (t.length) return [t rangeOfString:@"最近"].location != NSNotFound;
    }
    // 找不到底部标签栏时不再“一律允许”，否则按钮会跑到拨号盘上
    return NO;
}

static void RemoveBlkBtn(void) {
    if (gBlkBtn) {
        [gBlkBtn removeFromSuperview];
        gBlkBtn = nil;
    }
}

static void AttachBlacklistButton(void) {
    UIWindow *win = KeyWindowNow();
    if (!win) return;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]])
        top = ((UINavigationController *)top).topViewController;
    UIView *root = top.view;
    if (!root) return;

    if (!IsRecentCallsPage(root)) {
        RemoveBlkBtn();
        return;
    }
    UITableView *tv = FindFirstTable(root, 0);
    if (!tv) { RemoveBlkBtn(); return; }
    NSInteger rows = 0;
    for (UITableViewCell *c in [tv visibleCells]) {
        if (LongestDigits(RawA11yLabel(c), 7)) rows++;
    }
    if (rows < 1) { RemoveBlkBtn(); return; }
    if (gBlkBtn && gBlkBtn.superview == root) return;

    RemoveBlkBtn();
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
    gBlkBtn = b;
    A11yLog(@"最近通话页放上加入黑名单按钮（行数=%ld）", (long)rows);
}

static NSString *CellTexts(UIView *v, int depth) {
    if (!v || depth > 6) return @"";
    NSMutableString *s = [NSMutableString string];
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) [s appendFormat:@" %@", t];
    }
    NSString *l = RawA11yLabel(v);
    if (l.length) [s appendFormat:@" %@", l];
    for (UIView *sub in v.subviews) [s appendString:CellTexts(sub, depth + 1)];
    return s;
}

// 旁白转子的「操作」类别读的是 accessibilityCustomActions；
// App 自己给行挂了「更多」这类动作，说明行是聚焦元素，追加一条就能在转子里看到。
static void AttachCellActions(void) {
    UIWindow *win = KeyWindowNow();
    if (!win) return;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]])
        top = ((UINavigationController *)top).topViewController;
    UIView *root = top.view;
    if (!root || !IsRecentCallsPage(root)) return;
    UITableView *tv = FindFirstTable(root, 0);
    if (!tv) return;

    for (UITableViewCell *c in [tv visibleCells]) {
        NSString *d = LongestDigits(RawA11yLabel(c), 7);
        if (!d) d = LongestDigits(CellTexts(c, 0), 7);
        if (!d) continue;
        LoadBlacklist();
        BOOL inList = (gBlacklist && [gBlacklist containsObject:d]);
        NSString *title = inList ? @"移出黑名单" : @"加入黑名单";

        UIView *targets[2] = {c, c.contentView};
        for (int i = 0; i < 2; i++) {
            UIView *t = targets[i];
            if (!t) continue;
            NSArray *old = t.accessibilityCustomActions;
            BOOL has = NO;
            for (UIAccessibilityCustomAction *a in old) {
                if ([a.name rangeOfString:@"黑名单"].location != NSNotFound) { has = YES; break; }
            }
            if (has) continue;
            NSMutableArray *arr = old ? [old mutableCopy] : [NSMutableArray array];
            A11yAction *a = [[A11yAction alloc] initWithName:title
                                                     target:[A11yHelper shared]
                                                   selector:@selector(handleAction:)];
            a.digits = d;
            a.kind = inList ? 1 : 0;
            [arr addObject:a];
            t.accessibilityCustomActions = arr;
        }
        A11yLog(@"通话行挂转子操作 %@（%@）", d, title);
    }
}

 // 设置页兜底清理：有些说明文字是页面构建时就写死的（早于钩子安装），或者走富文本/自定义绘制，
 // 光靠 setText 钩子抓不到。这里每分钟扫一遍设置页可见控件，把残留英文再清一次。
static void CleanTextSweep(UIView *v, int depth) {
    if (!v || depth > 14) return;
    BOOL hidden = v.isHidden || v.alpha < 0.01;
    if (!hidden) {
        NSString *t = nil;
        BOOL isLab = [v isKindOfClass:[UILabel class]];
        BOOL isTV = [v isKindOfClass:[UITextView class]];
        if (isLab) t = ((UILabel *)v).text;
        else if (isTV) t = ((UITextView *)v).text;
        if (t.length && t.length <= 400) {
            NSString *f = FilterEnglish(t);
            if (f && ![f isEqualToString:t]) {
                if (isLab) ((UILabel *)v).text = f;
                else ((UITextView *)v).text = f;
                A11yLog(@"英文清理(兜底)：%@ -> %@", t, f);
            }
        }
        if ([v isKindOfClass:[UIButton class]]) {
            NSString *f = FilterEnglish(((UIButton *)v).currentTitle);
            if (f && ![f isEqualToString:((UIButton *)v).currentTitle]) {
                [(UIButton *)v setTitle:f forState:UIControlStateNormal];
            }
        }
        if ([v isKindOfClass:[UISegmentedControl class]]) {
            // 分段控件是自绘的，改子标签没用，得直接改每一段的标题
            UISegmentedControl *seg = (UISegmentedControl *)v;
            for (NSInteger i = 0; i < (NSInteger)seg.numberOfSegments; i++) {
                NSString *t = [seg titleForSegmentAtIndex:i];
                NSString *f = FilterEnglish(t);
                if (f && ![f isEqualToString:t]) {
                    [seg setTitle:f forSegmentAtIndex:i];
                    A11yLog(@"英文清理(分段)：%@ -> %@", t, f);
                }
            }
        }
    }
    for (UIView *s in v.subviews) CleanTextSweep(s, depth + 1);
}

static void SweepSettingsIfNeeded(void) {
    UIWindow *win = KeyWindowNow();
    if (!win) return;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]])
        top = ((UINavigationController *)top).topViewController;
    UIView *root = top.view;
    if (!root) return;
    if (!LooksLikeSettings(root, 0)) return;
    CleanTextSweep(root, 0);
}

__attribute__((constructor)) static void A11yInit(void) {
    Class UILabel_ = objc_getClass("UILabel");
    Class UITextField_ = objc_getClass("UITextField");
    InstallTextHook(UILabel_, &gOrigSetText, (IMP)HookSetText, "setText:");
    InstallTextHook(UILabel_, &gOrigSetAttrText, (IMP)HookSetAttrText, "setAttributedText:");
    InstallTextHook(UITextField_, &gOrigTFSetText, (IMP)HookTFSetText, "setText:");
    Class UITextView_ = objc_getClass("UITextView");
    InstallTextHook(UITextView_, &gOrigTVSetText, (IMP)HookTVSetText, "setText:");
    InstallTextHook(UITextView_, &gOrigTVSetAttrText, (IMP)HookTVSetAttrText, "setAttributedText:");
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

    // 加载探针：无论日志开关是否打开，都写一个标记文件；但「无障碍补丁已加载」只播报第一次
    NSString *boot = [NSString stringWithFormat:@"CallA11y v11 已加载 %@\n", [NSDate date]];
    [boot writeToFile:[DocDir() stringByAppendingPathComponent:@"a11y_boot.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *announced = [DocDir() stringByAppendingPathComponent:@"a11y_announced.txt"];
    BOOL firstTime = ![[NSFileManager defaultManager] fileExistsAtPath:announced];
    if (firstTime) {
        [@"1" writeToFile:announced atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"无障碍补丁已加载，之后不会再提示");
        });
    }
    A11yLog(@"CallA11y v11 载入，日志开关=%d", gLogEnabled);

    // 常驻巡检：拨号盘和设置页可能随时才出现，不再只盯前 15 秒
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        ScanDelete(KeyWindowNow());
        AttachSettingsEntries();
        AttachFloatingEntries();
        AttachBlacklistButton();
        AttachCellActions();
        SweepSettingsIfNeeded();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}
