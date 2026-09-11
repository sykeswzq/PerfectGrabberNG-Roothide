// PGAppListController.m —— 注入 App 列表（搜索栏置顶 + 分段 + 开关勾选）
//
// 数据源（对齐 Choicy 模式）：
//   优先用 AltList 提供的 LSApplicationWorkspace 分类方法 atl_allInstalledApplications
//   （设备上装了 com.opa334.altlist 就有，带分组、覆盖更全）；
//   没有则自动回退到系统自带 allInstalledApplications / allApplications。
//   面板页是本项目自写的控制器，继承 PSViewController，零 Cephei 依赖。
#import <UIKit/UIKit.h>
#import "PGCommon.h"
#import "PGPrivate.h"   // PSViewController

@interface PGAppListController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation PGAppListController {
    UITableView *_tv;
    UISearchBar *_searchBar;
    UISegmentedControl *_segment;
    NSArray<NSDictionary *> *_allApps;   // @[@{@"id":bid, @"name":name, @"system":@(BOOL)}]
    NSArray<NSDictionary *> *_shown;
    NSMutableSet<NSString *> *_selected;
    BOOL _showSystem;
    BOOL _filterTried;   // 是否尝试过同步注入 filter
    BOOL _filterOK;      // 同步是否成功
}

#pragma mark - 视图

- (void)loadView {
    // 根视图就是普通 UIView，永远不可能是 UITableView，杜绝「系统表盖住我们的表」。
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if (@available(iOS 13.0, *)) self.view.backgroundColor = [UIColor systemBackgroundColor];
    else self.view.backgroundColor = [UIColor whiteColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"注入 App 列表";

    if (!(self.navigationController && self.navigationController.viewControllers.count > 1)) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(pg_close)];
    }

    CGRect b = self.view.bounds;
    if (b.size.width <= 0) b = CGRectMake(0, 0, 375, 667);

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44.0)];
    _searchBar.placeholder = @"搜索 App 名称或 Bundle ID";
    _searchBar.delegate = self;
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _segment = [[UISegmentedControl alloc] initWithItems:@[@"仅用户 App", @"全部 App"]];
    _segment.frame = CGRectMake(12.0, 50.0, b.size.width - 24.0, 32.0);
    _segment.selectedSegmentIndex = 0;
    _segment.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_segment addTarget:self action:@selector(pg_segmentChanged:) forControlEvents:UIControlEventValueChanged];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 86.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (@available(iOS 13.0, *)) header.backgroundColor = [UIColor systemBackgroundColor];
    else header.backgroundColor = [UIColor whiteColor];
    [header addSubview:_searchBar];
    [header addSubview:_segment];

    _tv = [[UITableView alloc] initWithFrame:b style:UITableViewStylePlain];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.dataSource = self;
    _tv.delegate = self;
    _tv.tableHeaderView = header;
    [self.view addSubview:_tv];

    [self pg_loadAndFilter];
    [_tv reloadData];
}

#pragma mark - 数据

- (NSMutableSet<NSString *> *)pg_selected {
    if (_selected) return _selected;
    _selected = [NSMutableSet set];
    @try {
        id v = PGValue(PGKeyApps);
        if ([v isKindOfClass:[NSArray class]]) {
            for (id s in (NSArray *)v) {
                if ([s isKindOfClass:[NSString class]]) [_selected addObject:(NSString *)s];
            }
        }
    } @catch (NSException *e) {}
    return _selected;
}

- (NSArray<NSDictionary *> *)pg_allApps {
    if (_allApps) return _allApps;
    _allApps = [self pg_loadApps];
    return _allApps ?: @[];
}

- (NSArray<NSDictionary *> *)pg_loadApps {
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) return @[];
        SEL dwsSel = NSSelectorFromString(@"defaultWorkspace");
        id ws = [wsClass performSelector:dwsSel];
        if (!ws) return @[];

        // 1) AltList 优先（装了 com.opa334.altlist 就有这个分类方法）
        SEL atlSel = NSSelectorFromString(@"atl_allInstalledApplications");
        // 2) 系统自带回退
        SEL allISel = NSSelectorFromString(@"allInstalledApplications");
        SEL allSel  = NSSelectorFromString(@"allApplications");

        NSArray *proxies = nil;
        if ([ws respondsToSelector:atlSel])
            proxies = [ws performSelector:atlSel];
        if (![proxies isKindOfClass:[NSArray class]] || proxies.count == 0) {
            if ([ws respondsToSelector:allISel])
                proxies = [ws performSelector:allISel];
        }
        if (![proxies isKindOfClass:[NSArray class]] || proxies.count == 0) {
            if ([ws respondsToSelector:allSel])
                proxies = [ws performSelector:allSel];
        }
        if (![proxies isKindOfClass:[NSArray class]]) return @[];

        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        for (id proxy in proxies) {
            @try {
                NSString *bid = nil, *name = nil;
                BOOL system = NO;
                id v = [proxy valueForKey:@"bundleIdentifier"];
                if ([v isKindOfClass:[NSString class]]) bid = v;
                if (bid.length == 0) {
                    v = [proxy valueForKey:@"applicationIdentifier"];
                    if ([v isKindOfClass:[NSString class]]) bid = v;
                }
                v = [proxy valueForKey:@"localizedName"];
                if ([v isKindOfClass:[NSString class]]) name = v;
                if (name.length == 0) name = bid;
                if (bid.length == 0) continue;

                v = [proxy valueForKey:@"applicationType"];
                if ([v isKindOfClass:[NSString class]])
                    system = ![(NSString *)v isEqualToString:@"User"];
                else {
                    v = [proxy valueForKey:@"isSystemApplication"];
                    if ([v respondsToSelector:@selector(boolValue)]) system = [v boolValue];
                }
                [out addObject:@{@"id": bid, @"name": name, @"system": @(system)}];
            } @catch (NSException *e) { continue; }
        }
        [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                   ascending:YES
                                                                    selector:@selector(localizedCaseInsensitiveCompare:)]]];
        return out;
    } @catch (NSException *e) {
        return @[];
    }
}

- (void)pg_loadAndFilter {
    [self pg_filter:_searchBar.text ?: @""];
}

- (void)pg_filter:(NSString *)text {
    NSString *q = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *app in [self pg_allApps]) {
        if (!_showSystem && [app[@"system"] boolValue]) continue;
        if (q.length > 0) {
            NSString *name = app[@"name"] ?: @"";
            NSString *bid  = app[@"id"]   ?: @"";
            if ([name rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [bid  rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [out addObject:app];
    }
    _shown = out;
}

#pragma mark - 交互

- (void)pg_segmentChanged:(UISegmentedControl *)sender {
    @try {
        _showSystem = (sender.selectedSegmentIndex == 1);
        [self pg_filter:_searchBar.text ?: @""];
        [_tv reloadData];
    } @catch (NSException *e) {}
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    @try {
        [self pg_filter:searchText];
        [_tv reloadData];
    } @catch (NSException *e) {}
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    @try { [searchBar resignFirstResponder]; } @catch (NSException *e) {}
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    @try { [_searchBar resignFirstResponder]; } @catch (NSException *e) {}
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_shown.count == 0) return 1;
    return (NSInteger)_shown.count;
}

// 头部直接显示「filter 里现在到底写了什么」——
// 这是排查「勾了却没效果」最快的一手信息，用户不必再去 Filza 翻 plist。
// 2.0.6：改用自绘 UILabel（numberOfLines=0），不再走系统表头 textLabel ——
// 系统表头会把多行诊断文本截断成一行，导致 filter 那行根本看不到。
// 进页面时若「已勾选列表」与「filter 实际内容」不一致，就静默重写一次 filter 自愈。
// 场景：用户在旧版勾过（只存进偏好、filter 没写进去），升级后一进列表就能自动补上。
- (void)pg_autoResync {
    // V2.0.19：filter 是静态 Classes=[UIApplication]，由 RootHide 白名单版决定注入范围，
    // 不再运行时改写 filter，无需在此自愈同步。
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self pg_autoResync];
    [_tv reloadData];
}

- (NSString *)pg_headerText {
    NSMutableString *s = [NSMutableString string];
    NSUInteger n = [self pg_selected].count;
    [s appendFormat:@"显示范围：已限定 %lu 个 App", (unsigned long)n];
    if (n == 0) {
        [s appendString:@"\n（留空 = RootHide 白名单版内全部显示）"];
    } else {
        [s appendString:@"\n（仅在这些 App 显示浮层）"];
    }
    [s appendString:@"\n注入总闸：RootHide 白名单版（roothideinject）"];
    [s appendString:@"\n改完后需彻底退出并重开该 App 才生效"];
    return s;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 208.0; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 208.0)];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (@available(iOS 13.0, *)) v.backgroundColor = [UIColor secondarySystemBackgroundColor];
    else v.backgroundColor = [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16.0, 6.0, v.bounds.size.width - 32.0, 196.0)];
    lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lb.font = [UIFont systemFontOfSize:9.0];
    lb.numberOfLines = 0;
    lb.text = [self pg_headerText];
    [v addSubview:lb];
    // 点一下表头 = 把完整诊断复制到剪贴板并弹窗展示，方便直接粘贴给开发者
    v.userInteractionEnabled = YES;
    [v addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(pg_copyDiag)]];
    return v;
}

- (void)pg_copyDiag {
    @try {
        NSString *s = [self pg_headerText];
        [UIPasteboard generalPasteboard].string = s;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"诊断信息已复制"
                                                                    message:s
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    } @catch (NSException *e) {}
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"PGAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (_shown.count == 0) {
        cell.textLabel.text = @"未找到匹配的 App（请确认已安装 AltList）";
        cell.detailTextLabel.text = nil;
        cell.accessoryView = nil;
        return cell;
    }

    NSDictionary *app = _shown[(NSUInteger)indexPath.row];
    NSString *bid = app[@"id"];
    cell.textLabel.text = app[@"name"] ?: bid;
    cell.detailTextLabel.text = bid;
    if (@available(iOS 13.0, *)) cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [[self pg_selected] containsObject:bid];
    sw.tag = (NSInteger)indexPath.row;
    [sw addTarget:self action:@selector(pg_switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)pg_switchChanged:(UISwitch *)sw {
    @try {
        NSInteger row = sw.tag;
        if (row < 0 || row >= (NSInteger)_shown.count) return;
        NSString *bid = _shown[(NSUInteger)row][@"id"];
        if (!bid) return;
        if (sw.on) [[self pg_selected] addObject:bid];
        else       [[self pg_selected] removeObject:bid];
        [self pg_save];
        [_tv reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    } @catch (NSException *e) {}
}

- (void)pg_save {
    @try {
        // 勾选为空 = 不限定（白名单版内全部显示）；勾选了则只在这些 App 显示浮层。
        if ([self pg_selected].count == 0) {
            // 必须写空数组而不是 nil：nil 表示"读不到偏好"，会被兜底逻辑当成已勾选。
            PGSetValue(PGKeyApps, @[]);
        } else {
            NSArray *list = [[[self pg_selected] allObjects] sortedArrayUsingSelector:@selector(compare:)];
            PGSetValue(PGKeyApps, list);
        }
    } @catch (NSException *e) {}
}

- (void)pg_close {
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1)
            [self.navigationController popViewControllerAnimated:YES];
        else
            [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *e) {}
}

@end
