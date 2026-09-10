// PGRootListController.m —— 设置面板首页
// 不依赖 PSListController / loadSpecifiersFromPlistName 的 specifier 机制（roothide 下解析 bundle
// 内 Root.plist 易失败 → 空白），直接用 PSViewController + UITableView 手写面板，零黑盒必显示。
#import <UIKit/UIKit.h>
#import "PGCommon.h"
#import "PGPrivate.h"   // PSViewController

@interface PGRootListController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation PGRootListController {
    UITableView *_tv;
    NSArray<NSNumber *> *_durations;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"下拉时间电量";
    if (@available(iOS 13.0, *)) self.view.backgroundColor = [UIColor systemBackgroundColor];
    else self.view.backgroundColor = [UIColor whiteColor];

    _durations = @[@1, @2, @3, @5, @10];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(pg_done)];

    CGRect b = self.view.bounds;
    if (b.size.width <= 0) b = CGRectMake(0, 0, 375, 667);
    _tv = [[UITableView alloc] initWithFrame:b style:UITableViewStyleGrouped];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.dataSource = self;
    _tv.delegate = self;
    [self.view addSubview:_tv];

    // 打开面板时自动把已保存的勾选同步进注入 filter：
    // 避免「重装插件后勾选列表还在、但 filter 被重置成全关」导致的不生效。
    @try {
        if ([PGValue(PGKeyApps) isKindOfClass:[NSArray class]]) PGSyncFilterPlist();
    } @catch (NSException *e) {}
}

- (void)pg_done {
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1)
            [self.navigationController popViewControllerAnimated:YES];
        else
            [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

// 某些旧版 PreferenceLoader 会用 initForContentSize: 实例化控制器，补齐免得崩。
- (instancetype)initForContentSize:(CGSize)size {
    return [self init];
}

#pragma mark - 数据辅助

- (BOOL)pg_enabled { return PGEnabled(); }
- (void)pg_setEnabled:(BOOL)on { PGSetValue(PGKeyEnabled, @(on)); }
- (double)pg_duration { return PGDuration(); }

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"基本";
    if (section == 1) return @"显示时长";
    return @"注入范围";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"游戏中从屏幕顶部向下拉一次（或长按顶部 0.3 秒），顶部会浮出当前时间与电量，若干秒后自动消失。开启「常驻显示」后时间电量一直挂在顶部，点一下胶囊可临时隐藏 5 秒。进入 App 后 1~8 秒内还会自动闪现三次「PGNG✓」自检提示——三次都看不到说明插件没被注入该 App。";
    if (section == 2)
        return @"默认不注入任何 App（全关）。勾选后，插件只会被加载进这些 App，SpringBoard / Sileo / 系统 App 完全不注入，因此不会进安全模式。注意：改完需完全退出并重新打开该 App 才生效。App 列表由 AltList 提供，需已安装 com.opa334.altlist。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return (NSInteger)_durations.count;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"PGRootCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:ID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"启用";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [self pg_enabled];
            [sw addTarget:self action:@selector(pg_enabledChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"常驻显示";
            cell.detailTextLabel.text = @"不用下拉，一直显示";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = PGKeepOn();
            [sw addTarget:self action:@selector(pg_keepOnChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    else if (indexPath.section == 1) {
        NSNumber *d = _durations[(NSUInteger)indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ 秒", d];
        double cur = [self pg_duration];
        cell.accessoryType = (fabs(cur - d.doubleValue) < 0.01)
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else {
        id apps = PGValue(PGKeyApps);
        long n = [apps isKindOfClass:[NSArray class]] ? (long)((NSArray *)apps).count : 0;
        cell.textLabel.text = n > 0
            ? [NSString stringWithFormat:@"注入 App 列表（已选 %ld 个）", n]
            : @"注入 App 列表（当前：全关）";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        NSNumber *d = _durations[(NSUInteger)indexPath.row];
        PGSetValue(PGKeyDuration, d);
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
    }
    else if (indexPath.section == 2) {
        @try {
            Class cls = NSClassFromString(@"PGAppListController");
            UIViewController *appList = [cls new];
            if (self.navigationController) {
                [self.navigationController pushViewController:appList animated:YES];
            } else {
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:appList];
                [self presentViewController:nav animated:YES completion:nil];
            }
        } @catch (NSException *e) {}
    }
}

- (void)pg_enabledChanged:(UISwitch *)sw {
    [self pg_setEnabled:sw.on];
}

- (void)pg_keepOnChanged:(UISwitch *)sw {
    PGSetValue(PGKeyKeepOn, @(sw.on));
}

@end
