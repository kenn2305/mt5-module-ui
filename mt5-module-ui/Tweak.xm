#import <UIKit/UIKit.h>
#import "Sources/MUIRuntime.h"

%hook UITabBarController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[MUIRuntime sharedRuntime] observeTabBarController:self];
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    %orig;
    [[MUIRuntime sharedRuntime] observeTabBarController:self];
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    %orig;
    [[MUIRuntime sharedRuntime] refreshCurrentScreenLayout];
}

- (void)setSelectedViewController:(UIViewController *)selectedViewController {
    %orig;
    [[MUIRuntime sharedRuntime] refreshCurrentScreenLayout];
}

%end

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    [[MUIRuntime sharedRuntime] prepareContentViewController:self];
    %orig;
    [[MUIRuntime sharedRuntime] observeContentViewController:self];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[MUIRuntime sharedRuntime] observeContentViewController:self];
}

%end

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"net.metaquotes.MetaTrader5Terminal"]) {
            return;
        }
        NSLog(@"[MT5ModuleUI] Loaded");
    }
}
