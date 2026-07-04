#import "MUIRuntime.h"
#import "MUIConfigStore.h"
#import "MUIConstants.h"
#import "MUIDesignerViewController.h"
#import "MUIScreenEditorViewController.h"
#import "MUIScreenOverlayManager.h"
#import "MUIModule.h"

@interface MUIRuntime ()
@property (nonatomic, weak, readwrite) UITabBarController *tabBarController;
@property (nonatomic, copy, readwrite) NSArray<MUIModule *> *currentModules;
@property (nonatomic, copy) NSArray<MUIModule *> *baselineModules;
@property (nonatomic, copy) NSArray<UIViewController *> *baselineControllers;
@property (nonatomic, assign) BOOL applying;
@property (nonatomic, assign) BOOL disableSavedLayoutForThisLaunch;
@property (nonatomic, assign) BOOL handledCrashMarker;
@property (nonatomic, weak) UILongPressGestureRecognizer *designerGesture;
@end

@implementation MUIRuntime

+ (instancetype)sharedRuntime {
    static MUIRuntime *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ runtime = [MUIRuntime new]; });
    return runtime;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentModules = @[];
        _baselineModules = @[];
        _baselineControllers = @[];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _disableSavedLayoutForThisLaunch = [defaults boolForKey:@"MT5ModuleUIApplyWatchdog"];
        [defaults setBool:NO forKey:@"MT5ModuleUIApplyWatchdog"];
    }
    return self;
}

- (void)observeTabBarController:(UITabBarController *)tabBarController {
    if (!tabBarController || self.applying) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self captureAndConfigureTabBarController:tabBarController];
    });
}

- (void)observeContentViewController:(UIViewController *)viewController {
    if (!self.tabBarController || !self.tabBarController.view.window) return;
    if ([NSStringFromClass(viewController.class) hasPrefix:@"MUI"]) return;
    // Apply before the next frame is committed so the original icon never
    // flashes at its default position during a tab transition.
    [self refreshCurrentScreenLayout];
    // A next-runloop pass catches controllers that finish adding subviews in
    // viewWillAppear without introducing a visible fixed delay.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshCurrentScreenLayout];
    });
}

- (UIViewController *)tabRootControllerForController:(UIViewController *)viewController {
    if (!viewController || !self.tabBarController) return nil;
    UIViewController *cursor = viewController;
    while (cursor.parentViewController && cursor.parentViewController != self.tabBarController) {
        cursor = cursor.parentViewController;
    }
    if (cursor.parentViewController == self.tabBarController ||
        [self.tabBarController.viewControllers containsObject:cursor]) return cursor;
    if ([self.tabBarController.viewControllers containsObject:viewController]) return viewController;
    return nil;
}

- (void)prepareContentViewController:(UIViewController *)viewController {
    if (!viewController || !self.tabBarController || !self.tabBarController.view.window) return;
    if ([NSStringFromClass(viewController.class) hasPrefix:@"MUI"]) return;
    UITabBarController *owner = viewController.tabBarController;
    BOOL isRootTab = [self.tabBarController.viewControllers containsObject:viewController];
    if (owner != self.tabBarController && !isRootTab) return;

    // Use the controller receiving viewWillAppear instead of selectedViewController.
    // During an animated tab transition UIKit may not update selectedViewController
    // until later, which previously caused the layout to appear ~0.5 s late.
    UIViewController *leaf = [self topViewControllerFrom:viewController];
    UIViewController *tabRoot = [self tabRootControllerForController:viewController];
    if (!tabRoot) return;
    NSString *screenID = [[MUIScreenOverlayManager sharedManager] screenIDForViewController:leaf];
    [[MUIScreenOverlayManager sharedManager] applyScreenID:screenID
                                                 rootView:tabRoot.view
                                                   tabBar:nil];
}

- (void)refreshCurrentScreenLayout {
    if (!self.tabBarController || !self.tabBarController.view.window) return;
    if (self.tabBarController.presentedViewController) return;
    UIViewController *selected = self.tabBarController.selectedViewController;
    if (!selected) return;
    UIViewController *leaf = [self topViewControllerFrom:selected];
    NSString *screenID = [[MUIScreenOverlayManager sharedManager] screenIDForViewController:leaf];
    [[MUIScreenOverlayManager sharedManager] applyScreenID:screenID
                                                 rootView:selected.view
                                                   tabBar:nil];
}

- (NSString *)identifierForController:(UIViewController *)controller
                            occurrence:(NSInteger)occurrence {
    NSString *className = NSStringFromClass(controller.class) ?: @"UIViewController";
    NSString *title = controller.tabBarItem.title ?: controller.title ?: @"untitled";
    return [NSString stringWithFormat:@"%@|%@#%ld", className, title, (long)occurrence];
}

- (NSArray<MUIModule *> *)inventoryControllers:(NSArray<UIViewController *> *)controllers {
    NSMutableDictionary<NSString *, NSNumber *> *classCounts = [NSMutableDictionary dictionary];
    NSMutableArray<MUIModule *> *modules = [NSMutableArray arrayWithCapacity:controllers.count];
    [controllers enumerateObjectsUsingBlock:^(UIViewController *controller, NSUInteger index, BOOL *stop) {
        NSString *className = NSStringFromClass(controller.class) ?: @"UIViewController";
        NSInteger occurrence = [classCounts[className] integerValue];
        classCounts[className] = @(occurrence + 1);

        UITabBarItem *item = controller.tabBarItem;
        MUIModule *module = [MUIModule new];
        module.identifier = [self identifierForController:controller occurrence:occurrence];
        module.controllerClass = className;
        module.originalTitle = item.title ?: controller.title ?: [NSString stringWithFormat:@"Module %lu", (unsigned long)index + 1];
        module.displayTitle = module.originalTitle;
        module.originalImage = item.image;
        module.originalSelectedImage = item.selectedImage;
        module.enabled = YES;
        module.originalIndex = index;
        module.controller = controller;
        [modules addObject:module];
    }];
    return modules;
}

- (void)captureAndConfigureTabBarController:(UITabBarController *)tabBarController {
    if (self.applying) return;
    NSArray<UIViewController *> *controllers = tabBarController.viewControllers;
    if (controllers.count < 2 || !tabBarController.view.window) return;

    BOOL newController = self.tabBarController != tabBarController;
    if (newController && self.baselineControllers.count > 0 && controllers.count < self.baselineControllers.count) {
        return;
    }
    if (newController || self.baselineControllers.count == 0) {
        self.tabBarController = tabBarController;
        self.baselineControllers = [controllers copy];
        self.baselineModules = [self inventoryControllers:controllers];
    } else {
        // MT5 can rebuild its tabs after account/session changes. Refresh retained
        // controller instances only when the app presents a complete fresh set.
        NSSet *known = [NSSet setWithArray:self.baselineControllers];
        BOOL containsFreshController = NO;
        for (UIViewController *controller in controllers) {
            if (![known containsObject:controller]) {
                containsFreshController = YES;
                break;
            }
        }
        if (containsFreshController && controllers.count >= self.baselineControllers.count) {
            self.baselineControllers = [controllers copy];
            self.baselineModules = [self inventoryControllers:controllers];
        }
    }

    [self installDesignerGestureOnTabBar:tabBarController.tabBar];

    if (self.disableSavedLayoutForThisLaunch && !self.handledCrashMarker) {
        self.handledCrashMarker = YES;
        [[MUIConfigStore sharedStore] resetWithError:nil];
        NSLog(@"[MT5ModuleUI] Previous Apply did not finish; saved layout disabled for safe recovery.");
        [self restoreBaselineWithoutSaving];
        return;
    }

    NSError *error = nil;
    NSArray<MUIModule *> *saved = [[MUIConfigStore sharedStore] loadModulesWithError:&error];
    if (saved.count > 0) {
        [self armApplyWatchdog];
        if (![self applyModules:saved error:&error]) {
            NSLog(@"[MT5ModuleUI] Refused saved layout: %@", error.localizedDescription);
            [self restoreBaselineWithoutSaving];
        }
        [self disarmApplyWatchdogAfterDelay];
    } else {
        self.currentModules = [self editableModulesFromBaselineUsingConfig:nil];
    }
}

- (void)armApplyWatchdog {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"MT5ModuleUIApplyWatchdog"];
    [NSUserDefaults.standardUserDefaults synchronize];
}

- (void)disarmApplyWatchdogAfterDelay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"MT5ModuleUIApplyWatchdog"];
        [NSUserDefaults.standardUserDefaults synchronize];
    });
}

- (void)installDesignerGestureOnTabBar:(UITabBar *)tabBar {
    if (!tabBar) return;
    if (self.designerGesture && self.designerGesture.view == tabBar) return;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDesignerGesture:)];
    gesture.minimumPressDuration = 0.8;
    gesture.cancelsTouchesInView = NO;
    [tabBar addGestureRecognizer:gesture];
    self.designerGesture = gesture;
}

- (void)handleDesignerGesture:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self presentDesigner];
    }
}

- (NSArray<MUIModule *> *)editableModulesFromBaselineUsingConfig:(NSArray<MUIModule *> * _Nullable)config {
    NSMutableDictionary<NSString *, MUIModule *> *baselineByID = [NSMutableDictionary dictionary];
    for (MUIModule *module in self.baselineModules) {
        baselineByID[module.identifier] = module;
    }

    NSMutableArray<MUIModule *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    for (MUIModule *configured in config ?: @[]) {
        MUIModule *baseline = baselineByID[configured.identifier];
        if (!baseline) continue;
        MUIModule *merged = [baseline copy];
        merged.displayTitle = configured.displayTitle.length > 0 ? configured.displayTitle : baseline.originalTitle;
        merged.customIconPath = configured.customIconPath;
        merged.enabled = configured.enabled;
        [result addObject:merged];
        [used addObject:merged.identifier];
    }
    for (MUIModule *baseline in self.baselineModules) {
        if (![used containsObject:baseline.identifier]) {
            [result addObject:[baseline copy]];
        }
    }
    return result;
}

- (BOOL)applyModules:(NSArray<MUIModule *> *)configuredModules error:(NSError **)error {
    if (!self.tabBarController || self.baselineModules.count == 0) return NO;
    NSArray<MUIModule *> *modules = [self editableModulesFromBaselineUsingConfig:configuredModules];

    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    for (MUIModule *module in modules) {
        if (!module.enabled || !module.controller) continue;
        UIViewController *controller = module.controller;
        UITabBarItem *item = controller.tabBarItem;
        item.title = module.displayTitle.length > 0 ? module.displayTitle : module.originalTitle;
        if (module.customIconPath.length > 0) {
            UIImage *custom = [[MUIConfigStore sharedStore] imageAtRelativePath:module.customIconPath];
            if (custom) {
                UIImage *templated = [custom imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                item.image = templated;
                item.selectedImage = templated;
            } else {
                item.image = module.originalImage;
                item.selectedImage = module.originalSelectedImage;
            }
        } else {
            item.image = module.originalImage;
            item.selectedImage = module.originalSelectedImage;
        }
        [controllers addObject:controller];
    }
    if (controllers.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.vietanh.mt5moduleui.runtime" code:10
                                      userInfo:@{NSLocalizedDescriptionKey: @"No visible module remains after validation."}];
        }
        return NO;
    }

    UIViewController *selected = self.tabBarController.selectedViewController;
    self.applying = YES;
    [self.tabBarController setViewControllers:controllers animated:NO];
    if (selected && [controllers containsObject:selected]) {
        self.tabBarController.selectedViewController = selected;
    } else {
        self.tabBarController.selectedIndex = 0;
    }
    self.applying = NO;
    self.currentModules = modules;
    return YES;
}

- (NSArray<MUIModule *> *)editableSnapshot {
    NSMutableArray *snapshot = [NSMutableArray arrayWithCapacity:self.currentModules.count];
    for (MUIModule *module in self.currentModules) [snapshot addObject:[module copy]];
    return snapshot;
}

- (BOOL)applyAndSaveModules:(NSArray<MUIModule *> *)modules error:(NSError **)error {
    if (![[MUIConfigStore sharedStore] saveModules:modules error:error]) return NO;
    [self armApplyWatchdog];
    if (![self applyModules:modules error:error]) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"MT5ModuleUIApplyWatchdog"];
        [[MUIConfigStore sharedStore] restoreBackupWithError:nil];
        [self restoreBaselineWithoutSaving];
        return NO;
    }
    [self disarmApplyWatchdogAfterDelay];
    return YES;
}

- (void)restoreBaselineWithoutSaving {
    if (!self.tabBarController || self.baselineControllers.count == 0) return;
    self.applying = YES;
    for (MUIModule *module in self.baselineModules) {
        UITabBarItem *item = module.controller.tabBarItem;
        item.title = module.originalTitle;
        item.image = module.originalImage;
        item.selectedImage = module.originalSelectedImage;
    }
    [self.tabBarController setViewControllers:self.baselineControllers animated:NO];
    self.tabBarController.selectedIndex = 0;
    self.applying = NO;
    self.currentModules = [self editableModulesFromBaselineUsingConfig:nil];
}

- (BOOL)resetToOriginalWithError:(NSError **)error {
    if (![[MUIConfigStore sharedStore] resetWithError:error]) return NO;
    [self restoreBaselineWithoutSaving];
    return YES;
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)controller {
    if (controller.presentedViewController) return [self topViewControllerFrom:controller.presentedViewController];
    if ([controller isKindOfClass:UINavigationController.class]) {
        return [self topViewControllerFrom:((UINavigationController *)controller).visibleViewController];
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return [self topViewControllerFrom:((UITabBarController *)controller).selectedViewController];
    }
    return controller;
}

- (void)presentDesigner {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.tabBarController || self.tabBarController.presentedViewController) return;
        MUIDesignerViewController *designer = [[MUIDesignerViewController alloc] initWithRuntime:self];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:designer];
        navigation.modalPresentationStyle = UIModalPresentationFormSheet;
        UIViewController *presenter = [self topViewControllerFrom:self.tabBarController];
        [presenter presentViewController:navigation animated:YES completion:nil];
    });
}

- (void)presentScreenEditor {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.tabBarController || self.tabBarController.presentedViewController) return;
        UIViewController *leaf = [self topViewControllerFrom:self.tabBarController.selectedViewController];
        UIViewController *tabRoot = self.tabBarController.selectedViewController;
        if (!tabRoot) return;
        NSString *screenID = [[MUIScreenOverlayManager sharedManager] screenIDForViewController:leaf];
        [[MUIScreenOverlayManager sharedManager] removeOverlayAndRestoreOriginalsForRootView:tabRoot.view];
        MUIScreenEditorViewController *editor = [[MUIScreenEditorViewController alloc]
            initWithRuntime:self
                   rootView:tabRoot.view
                     tabBar:nil
                   screenID:screenID];
        [leaf presentViewController:editor animated:YES completion:nil];
    });
}

@end
