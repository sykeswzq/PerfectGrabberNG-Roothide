// PGPrivate.h —— 手动声明系统私有类（Preferences 框架）
// 编译设置面板 bundle 时用 -undefined dynamic_lookup，这些符号运行时由「设置」App 提供。
#import <UIKit/UIKit.h>

#pragma mark - Preferences 私有类

typedef NS_ENUM(NSInteger, PGCellType) {
    PGPSGroupCell       = 0,
    PGPSLinkCell        = 1,
    PGPSLinkListCell    = 2,
    PGPSListItemCell    = 3,
    PGPSStaticTextCell  = 7
};

@interface PSSpecifier : NSObject
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

// 面板控制器继承 PSViewController：
// PSListController 把 detail 控制器 push 进导航栈时会调用 setRootController:/setParentController:，
// 普通 UIViewController 没有这些方法 → unrecognized selector 闪退。补齐这些注入点。
@interface PSViewController : UIViewController
- (void)setRootController:(id)rootController;
- (void)setParentController:(id)parentController;
- (id)rootController;
- (id)parentController;
@end

#pragma mark - MobileCoreServices（列出已安装 App）

@interface LSApplicationProxy : NSObject
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
@end
