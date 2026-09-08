// PGPrivate.h —— 手动声明系统私有类（Preferences / MobileCoreServices）
// 编译设置面板时用 -undefined dynamic_lookup，这些符号在运行时由「设置」App 提供。
#import <UIKit/UIKit.h>

#pragma mark - Preferences 私有类

typedef NS_ENUM(NSInteger, PGCellType) {
    PGPSGroupCell       = 0,
    PGPSLinkCell        = 1,
    PGPSLinkListCell    = 2,
    PGPSListItemCell    = 3,
    PGTitleValueCell    = 4,
    PGPSSliderCell      = 5,
    PGPSSwitchCell      = 6,
    PGPSStaticTextCell  = 7,
    PGPSEditTextCell    = 8,
    PGPSButtonCell      = 13
};

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PGCellType)cell
                                    edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:( NSString * _Nullable )name;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSViewController : UIViewController
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
@end

@interface PSListController : PSViewController
- (instancetype)initForContentSize:(CGSize)size;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (PSSpecifier *)specifierAtIndex:(NSInteger)index;
// 从 bundle 内的 plist 声明式加载界面（Choicy 用的就是这套，稳定）
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

#pragma mark - 安全构造工具（异常一律转成提示，绝不让设置 App 闪退）

#import <string.h>

// group specifier 的安全创建
NS_INLINE PSSpecifier * _Nullable PGGroupSpec(NSString *_Nullable name) {
    Class c = NSClassFromString(@"PSSpecifier");
    if (c == Nil) return nil;
    @try { return (PSSpecifier *)[c performSelector:@selector(groupSpecifierWithName:) withObject:(name ?: @"")]; }
    @catch (NSException *e) { return nil; }
}

// 7 参 specifier 构造（performSelector 最多 2 参，必须用 NSInvocation）
// cell 参数在 iOS 13+ 是 NSInteger(8B)、iOS 12- 是 int(4B)，按运行时编码自适应
// 关键：PSSpecifier 的工厂选择器在 iOS 版本间有差异
//   （新版叫 specifierWithName:… ，旧版叫 preferenceSpecifierNamed:…）。
//   运行时探测，哪个存在用哪个，避免「unrecognized selector」被 @try 吞掉后页面空白。
NS_INLINE SEL _Nullable PGSpecifierFactorySEL(void) {
    Class c = NSClassFromString(@"PSSpecifier");
    if (c != Nil && [c respondsToSelector:@selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:)])
        return @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:);
    return NSSelectorFromString(@"specifierWithName:target:set:get:detail:cell:edit:");
}

NS_INLINE PSSpecifier * _Nullable PGMakeSpec(id target, NSString *name, SEL setSel, SEL getSel, Class detail, NSInteger cell) {
    Class c = NSClassFromString(@"PSSpecifier");
    if (c == Nil) return nil;
    SEL sel = PGSpecifierFactorySEL();
    if (![c respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [c methodSignatureForSelector:sel];
    if (!sig) return nil;
    @try {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = sel;
        [inv setArgument:&name   atIndex:2];
        [inv setArgument:&target atIndex:3];
        [inv setArgument:&setSel atIndex:4];
        [inv setArgument:&getSel atIndex:5];
        [inv setArgument:&detail atIndex:6];
        const char *enc = [sig getArgumentTypeAtIndex:7];
        if (enc && strcmp(enc, "i") == 0) { int v = (int)cell; [inv setArgument:&v atIndex:7]; }
        else { NSInteger v = cell; [inv setArgument:&v atIndex:7]; }
        Class editPane = Nil;
        [inv setArgument:&editPane atIndex:8];
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        return (PSSpecifier *)result;
    }
    @catch (NSException *e) { return nil; }
}

NS_INLINE NSArray *PGSafeBuild(NSArray *(^build)(void)) {
    if (NSClassFromString(@"PSSpecifier") == Nil) return @[];
    @try { NSArray *r = build(); return r ?: @[]; }
    @catch (NSException *e) {
        NSString *msg = [NSString stringWithFormat:@"面板加载出错：%@ %@",
                         e.name ?: @"Exception", e.reason ?: @"(无原因)"];
        id g = PGGroupSpec(msg);
        return g ? @[g] : @[];
    }
}

#pragma mark - MobileCoreServices（列出已安装 App）

@interface LSApplicationProxy : NSObject
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
@end
