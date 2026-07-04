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

%end

%hook UIViewController

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
