// PGTweak.m —— V2.0.22：去 UIWindow，改 addSubview 到 keyWindow
//
// 根因诊断（2026-09-11 二进制 diff 证实）：
//   roothide 下新建 scene-bound UIWindow（initWithWindowScene + connectedScenes）
//   会在 Unity/Metal 游戏加载期触发内核 SIGKILL，无崩溃日志。
//   Netskao rootless 1.1-7（原神能跑）的机制是：MSHookMessageEx 钩子 +
//   initWithFrame: 建 UIView 后 addSubview 到已有窗口——全程不碰 UIWindow。
//
// V2.0.22 改动：
//   1) 移除 PGPickWindowScene()、UIWindow *_window、initWithWindowScene:、connectedScenes、
//      UIWindowLevel、rootViewController——这些就是崩点。
//   2) 取 UIApplication.sharedApplication.keyWindow，addSubview: 一个 PGPassthroughView 容器。
//   3) 手势识别器、PGPassthroughView 穿透逻辑保留（这些是显示层，不崩）。
//   4) build.sh VER → 2.0.22。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 诊断日志（写失败即静默，不影响功能）

static void PGLog(NSString *s) {
    @try {
        static NSString *path = nil;
        static BOOL tried = NO;
        if (!tried) {
            tried = YES;
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSMutableArray *cands = [NSMutableArray array];
            if (doc.length) [cands addObject:[doc stringByAppendingPathComponent:@"pgng_diag.log"]];
            [cands addObject:@"/var/mobile/pgng_diag.log"];
            [cands addObject:[PGJbRoot() stringByAppendingPathComponent:@"var/mobile/pgng_diag.log"]];
            for (NSString *p in cands) {
                if ([fm fileExistsAtPath:p] ||
                    [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                    path = p; break;
                }
            }
        }
        if (!path.length) return;
        NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], s];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {}
}

#pragma mark - 穿透视图：只有顶部条区域吃触摸，其余穿透给游戏

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

#pragma mark - 浮层（无 UIWindow 版）

@interface PGOverlay : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)pg_install;
- (void)pg_reload;
@end

@implementation PGOverlay {
    PGPassthroughView *_content;   // 直接 addSubview 到 keyWindow 的容器
    UIView *_strip;        // 顶部触发条
    UIView *_infoView;     // 时间+电量胶囊
    UILabel *_label;
    BOOL _pulled;
    NSInteger _token;
    NSTimer *_keepTimer;
}

+ (instancetype)shared {
    static PGOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PGOverlay alloc] init]; });
    return s;
}

- (void)pg_install {
    if (_content) return;   // 已挂载则不重复
    if (!PGEnabled()) { PGLog(@"install: 总开关关闭"); return; }
    if (!PGCurrentAppSelected()) {
        PGLog([NSString stringWithFormat:@"install: 未勾选 bid=%@", PGAppBundleID()]);
        return;
    }
    [self pg_tryInstallWithRetry:0];
}

- (void)pg_tryInstallWithRetry:(int)n {
    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        if (_content) return;
        // 取当前 keyWindow，加不上就去通知 DidBecomeActive 再试
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (!kw) { PGLog(@"install: 暂无 keyWindow，等待 DidBecomeActive"); return; }

        // 直接 addSubview 到 keyWindow，不新建 UIWindow
        PGPassthroughView *cv = [[PGPassthroughView alloc] initWithFrame:CGRectZero];
        cv.backgroundColor = [UIColor clearColor];
        cv.opaque = NO;
        [kw addSubview:cv];
        _content = cv;

        // 顶部触发条（透明，高度 120）
        UIView *strip = [[UIView alloc] initWithFrame:CGRectZero];
        strip.backgroundColor = [UIColor clearColor];
        strip.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:strip];
        [NSLayoutConstraint activateConstraints:@[
            [strip.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
            [strip.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
            [strip.topAnchor constraintEqualToAnchor:cv.topAnchor],
            [strip.heightAnchor constraintEqualToConstant:120.0]
        ]];
        cv.pgHitView = strip;
        _strip = strip;

        // 状态栏高度：把胶囊挪到灵动岛下方
        CGFloat sbh = 0;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)sc).statusBarManager) {
                    sbh = ((UIWindowScene *)sc).statusBarManager.statusBarFrame.size.height;
                    break;
                }
            }
        }
        if (sbh <= 0) sbh = [UIApplication sharedApplication].statusBarFrame.size.height;
        if (sbh <= 0) sbh = 54.0;
        CGFloat infoTop = sbh + 4.0;

        // 时间+电量胶囊
        UIView *info = [[UIView alloc] initWithFrame:CGRectZero];
        info.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        info.layer.cornerRadius = 14.0;
        info.layer.masksToBounds = YES;
        info.layer.borderWidth = 1.0;
        info.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35].CGColor;
        info.alpha = 0.0;
        info.userInteractionEnabled = YES;
        info.translatesAutoresizingMaskIntoConstraints = NO;
        [strip addSubview:info];
        [NSLayoutConstraint activateConstraints:@[
            [info.centerXAnchor constraintEqualToAnchor:strip.centerXAnchor],
            [info.topAnchor constraintEqualToAnchor:strip.topAnchor constant:infoTop],
            [info.heightAnchor constraintEqualToConstant:30.0],
            [info.widthAnchor constraintGreaterThanOrEqualToConstant:120.0]
        ]];
        _infoView = info;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(pg_handleTap:)];
        tap.cancelsTouchesInView = NO;
        [info addGestureRecognizer:tap];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.translatesAutoresizingMaskIntoConstraints = NO;
        [info addSubview:lb];
        [NSLayoutConstraint activateConstraints:@[
            [lb.leadingAnchor constraintEqualToAnchor:info.leadingAnchor constant:12.0],
            [lb.trailingAnchor constraintEqualToAnchor:info.trailingAnchor constant:-12.0],
            [lb.topAnchor constraintEqualToAnchor:info.topAnchor],
            [lb.bottomAnchor constraintEqualToAnchor:info.bottomAnchor]
        ]];
        _label = lb;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
        pan.cancelsTouchesInView = NO;
        pan.delegate = self;
        [strip addGestureRecognizer:pan];

        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleSwipeDown:)];
        swipe.direction = UISwipeGestureRecognizerDirectionDown;
        swipe.cancelsTouchesInView = NO;
        swipe.delegate = self;
        [strip addGestureRecognizer:swipe];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        lp.cancelsTouchesInView = NO;
        lp.delegate = self;
        [strip addGestureRecognizer:lp];

        PGLog(@"install: addSubview 完成");

        // 1秒后自检闪现（避免 Metal 渲染线程干扰）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self pg_showFor:2.0];
        });
      } @catch (NSException *e) {
          PGLog([NSString stringWithFormat:@"install: 异常 %@", e.reason]);
          // 失败重试，最多 3 次
          if (n < 3) {
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{ [self pg_tryInstallWithRetry:n+1]; });
          }
      }
    });
}

- (void)pg_reload {
    if (!PGEnabled() || !PGCurrentAppSelected()) {
        [self pg_teardown];
    } else {
        [self pg_install];
    }
}

- (void)pg_teardown {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_keepTimer invalidate]; _keepTimer = nil;
        _content.pgHitView = nil;
        [_content removeFromSuperview];
        _content = nil; _strip = nil; _infoView = nil; _label = nil;
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)pg_handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        if (_pulled) return;
        CGPoint t = [g translationInView:_strip];
        if (t.y > 12.0) { _pulled = YES; PGLog(@"trigger: pan"); [self pg_show]; }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        _pulled = NO;
    }
}

- (void)pg_handleSwipeDown:(UISwipeGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) { PGLog(@"trigger: swipe"); [self pg_show]; }
}

- (void)pg_handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { PGLog(@"trigger: longpress"); [self pg_show]; }
}

- (void)pg_show {
    [self pg_showFor:PGDuration()];
}

- (void)pg_showFor:(NSTimeInterval)d {
    if (!PGEnabled() || !PGCurrentAppSelected()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_content || !_label) return;

        [self pg_updateText];

        // 直接 alpha，不动画（避免 Metal 渲染线程干扰）
        _infoView.alpha = 1.0;
        _infoView.transform = CGAffineTransformIdentity;
        if (PGKeepOn()) { [self pg_startKeepTimer]; return; }
        _token += 1;
        NSInteger my = _token;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (my == _token) [self pg_hide];
        });
    });
}

- (void)pg_updateText {
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
}

- (void)pg_startKeepTimer {
    if (_keepTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_keepTimer || !_content) return;
        _keepTimer = [NSTimer timerWithTimeInterval:30.0
                                             target:self
                                           selector:@selector(pg_keepTick)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_keepTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)pg_keepTick {
    if (!PGKeepOn() || !_content || !_label) { [_keepTimer invalidate]; _keepTimer = nil; return; }
    [self pg_updateText];
    _infoView.alpha = 1.0;
}

- (void)pg_handleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    if (!_infoView || _infoView.alpha < 0.5) return;
    PGLog(@"trigger: tap-hide");
    [self pg_hide];
    if (PGKeepOn()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (PGKeepOn()) [self pg_show];
        });
    }
}

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void PGInit(void) {
    // 纯 C 层白名单：在 ObjC 之前过滤掉系统/越狱进程，杜绝安全模式崩溃。
    const char *img0 = _dyld_get_image_name(0);
    if (!img0 || !img0[0]) return;
    const char *p = img0;
    if (strncmp(p, "/System", 7) == 0) return;
    if (strncmp(p, "/usr", 4) == 0) return;
    if (strncmp(p, "/bin", 4) == 0) return;
    if (strncmp(p, "/sbin", 5) == 0) return;
    if (strncmp(p, "/Library", 8) == 0) return;
    if (strstr(p, "SpringBoard")) return;
    if (strstr(p, "/var/jb")) return;
    if (strstr(p, "/var/lib")) return;
    if (!strstr(p, ".app/")) return;

    @autoreleasepool {
        if (PGIsSystemProcess()) return;
        if (PGIsJailbreakManager()) return;

        PGLog([NSString stringWithFormat:@"init: 已进入 bid=%@ img=%s", PGAppBundleID(), img0]);

        int token = 0;
        notify_register_dispatch(PGNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });

        // DidFinishLaunching + DidBecomeActive 两次兜底
        void (^tryInstall)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[PGOverlay shared] pg_install];
            });
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { tryInstall(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { tryInstall(); }];
        // 构造后 2 秒兜底（覆盖 roothide 注入过晚、通知已错过的情况）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[PGOverlay shared] pg_install];
        });
    }
}
