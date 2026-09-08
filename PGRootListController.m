// PGRootListController.m —— 设置面板首页
//
// 关键教训（roothide / iOS 16.5，本次空白的真因）：
//   之前重写了 - (NSBundle *)bundle 返回 [NSBundle bundleForClass:]，
//   但插件 bundle 是被 PreferenceLoader 用 dlopen 加载的，此时 bundleForClass
//   拿到的是「设置 App 本体(mainBundle)」，于是 [self bundle] pathForResource:@"Root"
//   在设置 App 里找 Root.plist → 找不到 → 空数组 → 页面空白。
//   正确做法：不要把 bundle 重写为 bundleForClass。PSListController 的 bundle 属性
//   由 PreferenceLoader 加载 entry 时已正确设置（并解析了 roothide 路径），框架原生的
//   loadSpecifiersFromPlistName:target: 正是用它。
//   这里：方案1 用框架原生加载；方案2 兜底（bundle 万一没设好时，自己按 bundleIdentifier
//   在 allBundles 里定位，再手工构造 specifiers，用 PGMakeSpec 运行时探测工厂选择器）。
#import "PGPrivate.h"
#import "PGCommon.h"
#import <notify.h>

@interface PGRootListController : PSListController
@end

@implementation PGRootListController {
    NSArray *_pgSpecs;
}

- (void)viewDidLoad {
    @try { [super viewDidLoad]; } @catch (NSException *e) {}
    @try { self.title = @"下拉时间电量"; } @catch (NSException *e) {}
}

// 定位真正装有 Root.plist 的 bundle（绝不用 bundleForClass）
- (NSBundle *)_pg_bundle {
    @try {
        NSBundle *b = [self bundle];   // 父类 getter，PreferenceLoader 已设置
        if ([[b pathForResource:@"Root" ofType:@"plist"] length]) return b;
    } @catch (NSException *e) {}
    @try {
        for (NSBundle *c in [NSBundle allBundles]) {
            NSString *bid = c.bundleIdentifier ?: @"";
            if ([bid rangeOfString:@"perfectgrabber" options:NSCaseInsensitiveSearch].length
                && [[c pathForResource:@"Root" ofType:@"plist"] length]) {
                return c;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// 自己从定位到的 bundle 读 Root.plist 构造 specifiers（兜底用）
- (NSArray *)_pg_buildFromBundle {
    NSMutableArray *arr = [NSMutableArray array];
    @try {
        NSBundle *b = [self _pg_bundle];
        NSString *path = [b pathForResource:@"Root" ofType:@"plist"];
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *items = root[@"items"] ?: @[];
        for (NSDictionary *it in items) {
            NSString *cell = it[@"cell"];
            PSSpecifier *sp = nil;

            if ([cell isEqualToString:@"PSGroupCell"]) {
                sp = [PSSpecifier groupSpecifierWithName:it[@"label"] ?: @""];
                if (it[@"footerText"]) [sp setProperty:it[@"footerText"] forKey:@"footerText"];
            }
            else if ([cell isEqualToString:@"PSSwitchCell"]) {
                sp = PGMakeSpec(self, it[@"label"] ?: @"",
                                @selector(setPreferenceValue:forSpecifier:),
                                @selector(readPreferenceValueForSpecifier:),
                                Nil, PGPSSwitchCell);
                [sp setProperty:it[@"key"]      forKey:@"key"];
                [sp setProperty:it[@"defaults"] forKey:@"defaults"];
                if (it[@"default"])         [sp setProperty:it[@"default"]         forKey:@"default"];
                if (it[@"PostNotification"]) [sp setProperty:it[@"PostNotification"] forKey:@"PostNotification"];
            }
            else if ([cell isEqualToString:@"PSLinkListCell"]) {
                sp = PGMakeSpec(self, it[@"label"] ?: @"",
                                @selector(setPreferenceValue:forSpecifier:),
                                @selector(readPreferenceValueForSpecifier:),
                                Nil, PGPSLinkListCell);
                [sp setProperty:it[@"key"]      forKey:@"key"];
                [sp setProperty:it[@"defaults"] forKey:@"defaults"];
                if (it[@"default"])      [sp setProperty:it[@"default"]      forKey:@"default"];
                if (it[@"validValues"])  [sp setProperty:it[@"validValues"]  forKey:@"validValues"];
                if (it[@"validTitles"])  [sp setProperty:it[@"validTitles"]  forKey:@"validTitles"];
                if (it[@"PostNotification"]) [sp setProperty:it[@"PostNotification"] forKey:@"PostNotification"];
            }
            else if ([cell isEqualToString:@"PSLinkCell"]) {
                Class detail = NSClassFromString(it[@"detail"] ?: @"");
                sp = PGMakeSpec(self, it[@"label"] ?: @"", Nil, Nil, detail, PGPSLinkCell);
                [sp setProperty:@YES forKey:@"isController"];
            }

            if (sp) [arr addObject:sp];
        }
    } @catch (NSException *e) {}
    return arr;
}

- (NSArray *)specifiers {
    if (_pgSpecs) return _pgSpecs;

    // 方案1：框架原生加载（最可靠，内部正确处理 bundle 路径与 PSSpecifier 构造）
    NSArray *loaded = nil;
    @try {
        loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
    } @catch (NSException *e) { loaded = nil; }
    if (loaded.count) { _pgSpecs = loaded; return _pgSpecs; }

    // 方案2：兜底——自己定位 bundle 并构造
    _pgSpecs = [self _pg_buildFromBundle];
    return _pgSpecs;
}

@end
