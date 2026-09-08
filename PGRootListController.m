// PGRootListController.m —— 设置面板首页
//
// 关键教训（roothide / iOS 16.5）：
//   纯 PSListController 的 loadSpecifiersFromPlistName:target: 是从【mainBundle】（即设置 App）
//   找 plist 的，不会去我们的 PreferenceBundle 里找，所以直接调用它会拿到空数组 → 设置页空白。
//   解决办法：自己从本 bundle 读 Root.plist，用 PSSpecifier 工厂手动构造 specifiers。
//   set/get 用框架标准选择器，由框架把值写进 Root.plist 里声明的 defaults 域（com.sykes.perfectgrabberng），
//   tweak(dylib) 端用同一域读取，闭环一致。
#import "PGPrivate.h"
#import "PGCommon.h"
#import <notify.h>

@interface PGRootListController : PSListController
@end

@implementation PGRootListController {
    NSArray *_pgSpecs;
}

// 让框架在本类相关场景下能拿到正确的 bundle（声明式解析 Root.plist 时也依赖它）
- (NSBundle *)bundle {
    NSBundle *b = [NSBundle bundleForClass:[self class]];
    return b ?: [NSBundle mainBundle];
}

- (void)viewDidLoad {
    @try { [super viewDidLoad]; } @catch (NSException *e) {}
    @try { self.title = @"下拉时间电量"; } @catch (NSException *e) {}
}

// 手动从 bundle 内 Root.plist 构造 specifiers（不依赖框架内部从 mainBundle 找 plist 的行为）
- (NSArray *)specifiers {
    if (_pgSpecs) return _pgSpecs;
    NSMutableArray *arr = [NSMutableArray array];
    @try {
        NSString *path = [[self bundle] pathForResource:@"Root" ofType:@"plist"];
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
                sp = [PSSpecifier preferenceSpecifierNamed:it[@"label"] ?: @""
                                 target:self
                                 set:@selector(setPreferenceValue:forSpecifier:)
                                 get:@selector(readPreferenceValueForSpecifier:)
                                 detail:Nil cell:PGPSSwitchCell edit:Nil];
                [sp setProperty:it[@"key"]      forKey:@"key"];
                [sp setProperty:it[@"defaults"] forKey:@"defaults"];
                if (it[@"default"])         [sp setProperty:it[@"default"]         forKey:@"default"];
                if (it[@"PostNotification"]) [sp setProperty:it[@"PostNotification"] forKey:@"PostNotification"];
            }
            else if ([cell isEqualToString:@"PSLinkListCell"]) {
                sp = [PSSpecifier preferenceSpecifierNamed:it[@"label"] ?: @""
                                 target:self
                                 set:@selector(setPreferenceValue:forSpecifier:)
                                 get:@selector(readPreferenceValueForSpecifier:)
                                 detail:Nil cell:PGSPSLinkListCell edit:Nil];
                [sp setProperty:it[@"key"]      forKey:@"key"];
                [sp setProperty:it[@"defaults"] forKey:@"defaults"];
                if (it[@"default"])      [sp setProperty:it[@"default"]      forKey:@"default"];
                if (it[@"validValues"])  [sp setProperty:it[@"validValues"]  forKey:@"validValues"];
                if (it[@"validTitles"])  [sp setProperty:it[@"validTitles"]  forKey:@"validTitles"];
                if (it[@"PostNotification"]) [sp setProperty:it[@"PostNotification"] forKey:@"PostNotification"];
            }
            else if ([cell isEqualToString:@"PSLinkCell"]) {
                Class detail = NSClassFromString(it[@"detail"] ?: @"");
                sp = [PSSpecifier preferenceSpecifierNamed:it[@"label"] ?: @""
                                 target:self set:Nil get:Nil detail:detail cell:PGPSLinkCell edit:Nil];
                [sp setProperty:@YES forKey:@"isController"];
            }

            if (sp) [arr addObject:sp];
        }
    } @catch (NSException *e) {}
    _pgSpecs = arr;
    return _pgSpecs;
}

@end
