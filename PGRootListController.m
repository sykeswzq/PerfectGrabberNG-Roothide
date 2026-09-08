// PGRootListController.m —— 设置面板首页
//
// 根因（roothide / iOS 16.5，连续多版空白的唯一真因）：
//   系统 PSListController 的 loadSpecifiersFromPlistName: 在 roothide 环境下，
//   解析不到我们 bundle 内的 Root.plist（PreferenceLoader 给子类设的 bundle 路径
//   在 roothide 下异常），于是拿到空数组 → 页面空白。
//   Choicy 之所以能显示，是因为它用 Cephei 的 HBListController 重写了一套加载逻辑。
//
// 本方案：不依赖 PSListController / PSSpecifier / loadSpecifiersFromPlistName 任何机制，
// 直接用纯 UIViewController + UITableView 手写面板。零依赖、零黑盒，必定显示。
// 等效于 Choicy 的 HBListController 效果，但不需要设备上额外装有 Cephei。
#import <UIKit/UIKit.h>
#import "PGCommon.h"

@interface PGRootListController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation PGRootListController {
    UITableView *_tv;
    NSArray<NSNumber *> *_durations;   // 1,2,3,5,10 秒
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"下拉时间电量";
    if (@available(iOS 13.0, *)) self.view.backgroundColor = [UIColor systemBackgroundColor];
    else self.view.backgroundColor = [UIColor whiteColor];

    _durations = @[@1, @2, @3, @5, @10];

    // 关闭按钮：兼容 PreferenceLoader 把本页以 push 或 modal 形式呈现
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
}

- (void)pg_done {
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    } @catch (NSException *e) {}
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
        return @"游戏中从屏幕顶部向下拉一次，顶部会浮出当前时间与电量，若干秒后自动消失。";
    if (section == 2)
        return @"默认不注入任何 App。请在「注入 App 列表」里勾选要显示时间电量的 App，勾选后立即生效（无需重启游戏）。roothide 下还需在 Bootstrap 的 App List 里打开对应 App 的注入开关。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return (NSInteger)_durations.count;
    return 1;   // 注入 App 列表
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"PGRootCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:ID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == 0) {
        cell.textLabel.text = @"启用";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self pg_enabled];
        [sw addTarget:self action:@selector(pg_enabledChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
        cell.textLabel.text = @"注入 App 列表";
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

@end
