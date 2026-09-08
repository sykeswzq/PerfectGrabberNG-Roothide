// PGRootListController.m —— 设置面板首页
// 范式完全对齐 Choicy（roothide 官方源里的成熟插件）：
//   界面由 bundle 内的 Root.plist 声明，交给 Preferences 框架原生解析；
//   本类只做「定位自己的 bundle + 兜底加载」，一行 PSSpecifier 构造代码都不写。
#import "PGPrivate.h"
#import "PGCommon.h"
#import <notify.h>

@interface PGRootListController : PSListController
@end

@implementation PGRootListController

// 关键：让 PSListController 从我们自己的 bundle 里找 Root.plist，而不是设置 App 的 mainBundle
- (NSBundle *)bundle {
    NSBundle *b = [NSBundle bundleForClass:[self class]];
    return b ?: [NSBundle mainBundle];
}

- (void)viewDidLoad {
    @try { [super viewDidLoad]; } @catch (NSException *e) {}
    @try { self.title = @"下拉时间电量"; } @catch (NSException *e) {}
}

// 正常情况下 super 会自动加载 Root.plist；万一没加载出来，这里兜底再试一次
- (NSArray *)specifiers {
    NSArray *s = nil;
    @try { s = [super specifiers]; } @catch (NSException *e) {}
    if (s.count == 0) {
        @try { s = [self loadSpecifiersFromPlistName:@"Root" target:self]; }
        @catch (NSException *e) {}
    }
    return s ?: @[];
}

@end
