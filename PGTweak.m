// PGTweak.m —— V2.0.25：独立 UIWindow 方案，根治游戏进程闪退
//
// 根因分析（基于 H5GG/IMGUI Mod Menu 等成熟项目对比）：
//   V2.0.24 每次 show 时实时查 keyWindow 然后 addSubview: 到游戏 window。
//   但 Unity/Metal 游戏在加载/切场景时会销毁重建 UIWindow，此期间 Metal
//   render command buffer 仍在提交，此时 addSubview: 会触发并发访问 → SIGSEGV。
//   即使用 @try/@catch 也无法阻止 Metal 端的崩溃。
//
// V2.0.25 根治方案（参考 H5GG/IMGUI Mod Menu）：
//   ★ 创建独立 UIWindow（windowLevel = UIWindowLevelAlert - 1），不抢 keyWindow
//   ★ 所有视图挂到独立窗口上，永不触碰游戏 window 层级
//   ★ 用 setHidden: 控制显隐，不用 makeKeyAndVisible
//   ★ 窗口只在激活时显示，切换回前台时自动刷新位置
//
// 参照基准：H5GG globalview（FloatWindow + setHidden，tested on iOS 11+）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 诊断日志

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

#pragma mark - 浮层（V2.0.25：独立 UIWindow 方案）

@interface PGOverlay : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)pg_install;
- (void)pg_reload;
@end

@implementation PGOverlay {
    // V2.0.25：独立 UIWindow，永不触碰游戏 window 层级
    UIWindow *_pgWindow;
    PGPassthroughView *_content;
    UIView *_strip;
    UIView *_infoView;
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

#pragma mark - install：创建独立 UIWindow + 构建视图层级

- (void)pg_install {
    if (_content) return;  // 已安装
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

        // V2.0.25：获取当前屏幕 bounds（用于独立窗口全屏覆盖）
        CGFloat screenWidth = 0, screenHeight = 0;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                CGRect b = ((UIWindowScene *)sc).applicationFrame;
                if (b.size.width > 0 && b.size.height > 0) {
                    screenWidth = b.size.width;
                    screenHeight = b.size.height;
                    break;
                }
            }
        }
        if (screenWidth <= 0) screenWidth = [UIScreen mainScreen].bounds.size.width;
        if (screenHeight <= 0) screenHeight = [UIScreen mainScreen].bounds.size.height;

        // V2.0.25：创建独立 UIWindow，windowLevel 低于 Alert，不抢 keyWindow
        // 关键：不调用 makeKeyAndVisible，只用 setHidden 控制显隐
        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, screenWidth, screenHeight)];
        win.windowLevel = UIWindowLevelAlert - 1;  // 高于普通但低于 Alert
        win.backgroundColor = [UIColor clearColor];
        win.hidden = YES;  // 初始隐藏
        _pgWindow = win;

        // 构建穿透容器
        PGPassthroughView *cv = [[PGPassthroughView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, screenHeight)];
        cv.backgroundColor = [UIColor clearColor];
        cv.opaque = NO;
        [_pgWindow addSubview:cv];
        _content = cv;

        // 顶部触发条（透明，高度 120）
        UIView *strip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 120)];
        strip.backgroundColor = [UIColor clearColor];
        [cv addSubview:strip];
        cv.pgHitView = strip;
        _strip = strip;

        // 状态栏高度
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
        UIView *info = [[UIView alloc] initWithFrame:CGRectMake((screenWidth - 140) / 2, infoTop, 140, 30)];
        info.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        info.layer.cornerRadius = 14.0;
        info.layer.masksToBounds = YES;
        info.layer.borderWidth = 1.0;
        info.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35].CGColor;
        info.alpha = 0.0;
        info.userInteractionEnabled = YES;
        [strip addSubview:info];
        _infoView = info;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(pg_handleTap:)];
        tap.cancelsTouchesInView = NO;
        [info addGestureRecognizer:tap];

        UILabel *lb = [[UILabel alloc] initWithFrame:info.bounds];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [info addSubview:lb];
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

        PGLog(@"install: 独立 UIWindow 创建完成（不抢 keyWindow）");

        // 监听 foreground 通知，确保窗口在应用激活时显示
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            // 窗口已在，只需确保可见性
            if (_pgWindow && !_pgWindow.hidden) return;
            // 重新获取屏幕尺寸（可能旋转）
            CGFloat w = [UIScreen mainScreen].bounds.size.width;
            CGFloat h = [UIScreen mainScreen].bounds.size.height;
            _pgWindow.frame = CGRectMake(0, 0, w, h);
            _content.frame = CGRectMake(0, 0, w, h);
            _pgWindow.hidden = NO;
            PGLog(@"install: 应用激活，独立窗口显示");
        }];

        // 1 秒后自检：确保窗口正确显示
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!_pgWindow.hidden) {
                [self pg_showFor:2.0];
            } else {
                PGLog(@"install: 等待应用激活...");
            }
        });
      } @catch (NSException *e) {
          PGLog([NSString stringWithFormat:@"install: 异常 %@", e.reason]);
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

#pragma mark - teardown：完整清理

- (void)pg_teardown {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_keepTimer invalidate]; _keepTimer = nil;
        [_pgWindow removeFromSuperview];
        _pgWindow = nil;
        _content = nil; _strip = nil; _infoView = nil; _label = nil;
        PGLog(@"teardown: 独立窗口已清理");
    });
}

#pragma mark - 手势处理

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

#pragma mark - show / hide

- (void)pg_show {
    [self pg_showFor:PGDuration()];
}

- (void)pg_showFor:(NSTimeInterval)d {
    if (!PGEnabled() || !PGCurrentAppSelected()) return;
    if (!_pgWindow || !_content || !_label) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // V2.0.25：直接操作独立窗口，不触碰游戏 window
        if (_pgWindow.hidden) {
            _pgWindow.hidden = NO;
            PGLog(@"show: 独立窗口显示");
        }

        [self pg_updateText];

        // 直接 alpha，不动画
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
    // 纯 C 层白名单：在 ObjC 之前过滤掉系统/越狱进程
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

        // 构造后 1 秒启动安装（游戏进程初始化完成后）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[PGOverlay shared] pg_install];
        });
    }
}
