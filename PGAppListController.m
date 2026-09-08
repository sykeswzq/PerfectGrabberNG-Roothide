// PGAppListController.m —— 注入 App 列表（搜索栏置顶 + 开关选择）
//
// 设计要点（解决之前「列表空白」的根因）：
//   之前继承 PSListController 并「接管系统表」，但 PSListController 自己的空表
//   会在 viewWillAppear 之后被叠到我们表的上层，于是看到的是空的系统表。
//   这里改为【普通 UIViewController】，完全自控视图，绝不和 Preferences 框架
//   的表视图产生冲突，列表一定能正常显示。
//
// 由 Root.plist 的 PSLinkCell(detail=PGAppListController, isController=true) 推入，
// Preferences 会把任意 UIViewController 压入设置导航栈，返回按钮与标题自动生效。
#import <UIKit/UIKit.h>
#import "PGCommon.h"

@interface PGAppListController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation PGAppListController {
    UITableView *_tv;
    UISearchBar *_searchBar;
    UISegmentedControl *_segment;
    NSArray<NSDictionary *> *_allApps;   // @[@{@"id":bid, @"name":name, @"system":@(BOOL)}]
    NSArray<NSDictionary *> *_shown;
    NSMutableSet<NSString *> *_selected;
    BOOL _showSystem;
}

#pragma mark - 视图

- (void)loadView {
    // 关键：根视图就是普通 UIView，永远不可能是 UITableView，
    // 从根本上杜绝「系统表盖住我们的表」这一类空白问题。
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if (@available(iOS 13.0, *)) self.view.backgroundColor = [UIColor systemBackgroundColor];
    else self.view.backgroundColor = [UIColor whiteColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"注入 App 列表";

    CGRect b = self.view.bounds;
    if (b.size.width <= 0) b = CGRectMake(0, 0, 375, 667);

    // 顶部搜索栏（Choicy 同款位置：列表最上方）
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 44.0)];
    _searchBar.placeholder = @"搜索 App 名称或 Bundle ID";
    _searchBar.delegate = self;
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // 分段：仅用户 App / 全部 App
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
        id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)]
                    ? [wsClass performSelector:@selector(defaultWorkspace)]
                    : nil;
        if (!ws) return @[];

        NSArray *proxies = nil;
        if ([ws respondsToSelector:@selector(allInstalledApplications)])
            proxies = [ws performSelector:@selector(allInstalledApplications)];
        else if ([ws respondsToSelector:@selector(allApplications)])
            proxies = [ws performSelector:@selector(allApplications)];
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
    NSString *q = (text ?: @"");
    q = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
    if (_shown.count == 0) return 1;   // 空态提示行
    return (NSInteger)_shown.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"已选 %lu 个 App（列表为空 = 全部生效）",
            (unsigned long)[self pg_selected].count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const ID = @"PGAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (_shown.count == 0) {
        cell.textLabel.text = @"未找到匹配的 App";
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
        NSArray *list = [[[self pg_selected] allObjects] sortedArrayUsingSelector:@selector(compare:)];
        PGSetValue(PGKeyApps, list);
    } @catch (NSException *e) {}
}

@end
