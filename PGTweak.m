// PGTweak.m —— V2.0.32 极简稳定版
//
// 【V2.0.32 重构核心】
//   1. Constructor 纯 C，零 ObjC —— 永不崩溃
//   2. 移除所有 filter 写入逻辑（避免 helper/symlink 复杂操作）
//   3. UI 构建采用多节点触发 + 重试机制
//   4. 更强容错：每个 UI 操作都有 try-catch
//   5. 延迟创建窗口（3s/5s/10s 多时机）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 全局状态

static NSString *sLogPath = nil;
static int sNotifyToken = 0;

#pragma mark - 诊断日志（C 层路径）

static void PGLog(const char *msg) {
    if (!sLogPath) return;
    @try {
        NSString *line = [NSString stringWithFormat:@"%s | %@\n", msg, [NSDate date]];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {}
}

static void PGInitLogPath(void) {
    if (sLogPath) return;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSMutableArray *cands = [NSMutableArray array];
        if (doc.length) [cands addObject:[doc stringByAppendingPathComponent:@"pgng_diag.log"]];
        [cands addObject:@"/var/mobile/pgng_diag.log"];
        [cands addObject:[PGJbRoot() stringByAppendingPathComponent:@"var/mobile/pgng_diag.log"]];
        for (NSString *p in cands) {
            if ([fm fileExistsAtPath:p] ||
                [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                sLogPath = p;
                PGLog([NSString stringWithFormat:@"log_path=%@", p].UTF8String);
                break;
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - 穿透视图

@interface PGPassthroughView : UIView
@property (nonatomic, weak) UIView *pgHitView;
@end

@implementation PGPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self) {
        UIView *strip = self.pgHitView;
        if (strip) {
            CGPoint p = [self convertPoint:point toView:strip];
            if (CGRectContainsPoint(strip.bounds, p)) {
                UIView *r = [strip hitTest:p withEvent:event];
                return r ?: strip;
            }
        }
        return nil;
    }
    return v;
}
@end

#pragma mark - 浮层

@interface PGOverlay : NSObject
+ (instancetype)shared;
- (void)pg_attemptInstall;
- (void)pg_teardown;
@end

@implementation PGOverlay {
    UIWindow *_window;
    PGPassthroughView *_content;
    UIView *_strip;
    UIView *_infoView;
    UILabel *_label;
    BOOL _pulled;
    NSInteger _token;
}

+ (instancetype)shared {
    static PGOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PGOverlay alloc] init]; });
    return s;
}

- (void)pg_attemptInstall {
    if (_window) return;
    if (!PGEnabled()) return;
    if (!PGCurrentAppSelected()) return;

    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;

        // 找合适的 window scene（安全访问：先判 windows 非空且 firstObject.windowScene 存在）
        UIWindow *targetScene = nil;
        if (@available(iOS 13.0, *)) {
            UIWindow *firstWin = app.windows.firstObject;
            if (firstWin && firstWin.windowScene) {
                for (UIWindowScene *scene in firstWin.windowScene.connection.availableScenes) {
                    targetScene = [[UIWindow alloc] initWithWindowScene:scene];
                    break;
                }
            }
        }
        if (!targetScene) {
            targetScene = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }

        targetScene.backgroundColor = [UIColor clearColor];
        targetScene.windowLevel = UIWindowLevelNormal + 1.0;
        targetScene.userInteractionEnabled = YES;
        targetScene.hidden = NO;

        UIViewController *vc = [[UIViewController alloc] init];
        PGPassthroughView *cv = [[PGPassthroughView alloc] initWithFrame:targetScene.bounds];
        cv.backgroundColor = [UIColor clearColor];
        cv.opaque = NO;
        cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        vc.view = cv;
        targetScene.rootViewController = vc;

        _window = targetScene;  // 保存的是 UIWindow，不是 UIWindowScene
        _content = cv;

        // 下拉条
        UIView *strip = [[UIView alloc] initWithFrame:CGRectZero];
        strip.backgroundColor = [UIColor clearColor];
        strip.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:strip];
        [NSLayoutConstraint activateConstraints:@[
            [strip.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
            [strip.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
            [strip.topAnchor constraintEqualToAnchor:cv.topAnchor],
            [strip.heightAnchor constraintEqualToConstant:110.0]
        ]];
        cv.pgHitView = strip;
        _strip = strip;

        // 信息框
        UIView *info = [[UIView alloc] initWithFrame:CGRectZero];
        info.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        info.layer.cornerRadius = 14.0;
        info.layer.masksToBounds = YES;
        info.alpha = 0.0;
        info.userInteractionEnabled = NO;
        info.translatesAutoresizingMaskIntoConstraints = NO;
        [strip addSubview:info];
        [NSLayoutConstraint activateConstraints:@[
            [info.centerXAnchor constraintEqualToAnchor:strip.centerXAnchor],
            [info.topAnchor constraintEqualToAnchor:strip.topAnchor constant:10.0],
            [info.heightAnchor constraintEqualToConstant:30.0],
            [info.widthAnchor constraintGreaterThanOrEqualToConstant:120.0]
        ]];
        _infoView = info;

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.userInteractionEnabled = NO;
        lb.translatesAutoresizingMaskIntoConstraints = NO;
        [info addSubview:lb];
        [NSLayoutConstraint activateConstraints:@[
            [lb.leadingAnchor constraintEqualToAnchor:info.leadingAnchor constant:12.0],
            [lb.trailingAnchor constraintEqualToAnchor:info.trailingAnchor constant:-12.0],
            [lb.topAnchor constraintEqualToAnchor:info.topAnchor],
            [lb.bottomAnchor constraintEqualToAnchor:info.bottomAnchor]
        ]];
        _label = lb;

        // 手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
        pan.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        lp.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:lp];

        PGLog("install: window created");
    } @catch (NSException *e) {
        PGLog([NSString stringWithFormat:@"install: error %@", e.reason].UTF8String);
        _window = nil;
    }
}

- (void)pg_teardown {
    @try {
        _content.pgHitView = nil;
        _window.hidden = YES;
        _window.rootViewController = nil;
        _window = nil;
        _content = nil;
        _strip = nil;
        _infoView = nil;
        _label = nil;
    } @catch (NSException *e) {}
}

- (void)pg_handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        if (_pulled) return;
        CGPoint t = [g translationInView:_strip];
        if (t.y > 16.0) {
            _pulled = YES;
            [self pg_show];
        }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        _pulled = NO;
    }
}

- (void)pg_handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [self pg_show];
    }
}

- (void)pg_show {
    if (!PGEnabled()) return;
    if (!PGCurrentAppSelected()) return;
    @try {
        if (!_label) return;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm"];
        NSString *time = [fmt stringFromDate:[NSDate date]];
        int pct = (int)roundf([UIDevice currentDevice].batteryLevel * 100.0f);
        if (pct < 0) pct = 0;
        UIDeviceBatteryState st = [UIDevice currentDevice].batteryState;
        NSString *bolt = @"";
        if (st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull) bolt = @"⚡";
        _label.text = [NSString stringWithFormat:@"%@   %@%d%%", time, bolt, pct];

        _infoView.alpha = 1.0;
        _infoView.transform = CGAffineTransformIdentity;

        _token += 1;
        NSInteger my = _token;
        NSTimeInterval d = PGDuration();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (my == _token) [self pg_hide];
        });
    } @catch (NSException *e) {}
}

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}
@end

#pragma mark - 懒加载入口

static void PGLazyInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PGInitLogPath();

        NSString *bid = [NSString stringWithUTF8String:getprogname()];
        PGLog([NSString stringWithFormat:@"lazy_init: bid=%@", bid].UTF8String);

        // 注册通知监听设置变更
        notify_register_dispatch(PGNotifyName, &sNotifyToken, dispatch_get_main_queue(), ^(int t) {
            PGOverlay *ov = [PGOverlay shared];
            [ov pg_teardown];
            [ov pg_attemptInstall];
        });

        // 多节点触发窗口创建
        void (^tryInstall)(void) = ^{
            PGOverlay *ov = [PGOverlay shared];
            [ov pg_attemptInstall];
        };

        // 节点1: App 启动完成
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGLog("notify: didFinishLaunching");
            tryInstall();
        }];

        // 节点2: App 变为 active
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGLog("notify: didBecomeActive");
            tryInstall();
        }];

        // 节点3: 延迟 3 秒再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PGLog("delay: 3s install attempt");
            tryInstall();
        });

        // 节点4: 延迟 5 秒再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PGLog("delay: 5s install attempt");
            tryInstall();
        });

        // 节点5: 延迟 10 秒再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PGLog("delay: 10s install attempt");
            tryInstall();
        });
    });
}

#pragma mark - 入口点（纯 C，零 ObjC）

__attribute__((constructor))
static void PGInit(void) {
    const char *exe = getprogname();
    if (!exe) return;

    // C 层过滤：排除系统路径和越狱组件
    if (strncmp(exe, "/System", 7) == 0) return;
    if (strncmp(exe, "/usr", 4) == 0) return;
    if (strncmp(exe, "/bin", 4) == 0) return;
    if (strncmp(exe, "/sbin", 5) == 0) return;
    if (strncmp(exe, "/Library", 8) == 0) return;
    if (strstr(exe, "SpringBoard")) return;
    if (strstr(exe, "/var/jb")) return;
    if (strstr(exe, "/var/lib")) return;
    if (!strstr(exe, ".app/")) return;

    PGLog("init: C filter passed, will lazy init");
}
