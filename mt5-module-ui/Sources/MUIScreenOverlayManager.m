#import "MUIScreenOverlayManager.h"
#import "MUIConfigStore.h"
#import "MUIScreenCandidate.h"
#import "MUIScreenLayoutStore.h"

static NSInteger const MUIScreenOverlayHostTag = 0x4D553149;

@interface MUIPassthroughView : UIView
@end

@implementation MUIPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface MUIForwardingButton : UIButton
@property (nonatomic, weak) UIControl *forwardTarget;
@property (nonatomic, copy, nullable) dispatch_block_t tapHandler;
@end

@implementation MUIForwardingButton
- (CGRect)imageRectForContentRect:(CGRect)contentRect {
    return contentRect;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self addTarget:self action:@selector(forwardTap) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)forwardTap {
    if (self.tapHandler) self.tapHandler();
    else [self.forwardTarget sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

@interface MUIScreenOverlayManager ()
@property (nonatomic, strong) NSMapTable<UIView *, UIView *> *hostsByRoot;
@property (nonatomic, strong) NSMapTable<UIView *, NSMapTable<UIView *, NSNumber *> *> *hiddenStatesByRoot;
@property (nonatomic, strong) NSMapTable<UIView *, NSString *> *screenIDsByRoot;
@end

@implementation MUIScreenOverlayManager

+ (instancetype)sharedManager {
    static MUIScreenOverlayManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [MUIScreenOverlayManager new]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hostsByRoot = [NSMapTable weakToStrongObjectsMapTable];
        _hiddenStatesByRoot = [NSMapTable weakToStrongObjectsMapTable];
        _screenIDsByRoot = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (UIViewController *)leafController:(UIViewController *)controller {
    if ([controller isKindOfClass:UINavigationController.class]) {
        UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
        return visible ? [self leafController:visible] : controller;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        return selected ? [self leafController:selected] : controller;
    }
    return controller;
}

- (NSString *)screenIDForViewController:(UIViewController *)viewController {
    UIViewController *leaf = [self leafController:viewController];
    NSString *className = NSStringFromClass(leaf.class) ?: @"UIViewController";
    NSString *title = leaf.navigationItem.title ?: leaf.title ?: @"screen";
    return [NSString stringWithFormat:@"%@|%@", className, title];
}

- (UIImage *)candidateImageForView:(UIView *)view {
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        return [button imageForState:UIControlStateNormal] ?: button.imageView.image;
    }
    if ([view isKindOfClass:UIImageView.class]) return ((UIImageView *)view).image;
    return nil;
}

- (NSString *)candidateTextForView:(UIView *)view {
    if ([view isKindOfClass:UILabel.class]) return ((UILabel *)view).text;
    return nil;
}

- (BOOL)viewIsInsideButton:(UIView *)view {
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([ancestor isKindOfClass:UIButton.class]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

- (void)scanView:(UIView *)view
             path:(NSString *)path
             root:(UIView *)root
           tabBar:(UITabBar *)tabBar
          results:(NSMutableArray<MUIScreenCandidate *> *)results {
    if (!view || view.tag == MUIScreenOverlayHostTag || view == tabBar || [view isDescendantOfView:tabBar]) return;
    if (view != root && (view.hidden || view.alpha < 0.05)) return;

    UIImage *image = [self candidateImageForView:view];
    NSString *text = [self candidateTextForView:view];
    BOOL duplicateImageView = [view isKindOfClass:UIImageView.class] && [self viewIsInsideButton:view];
    CGRect frame = view == root ? root.bounds : [view.superview convertRect:view.frame toView:root];
    CGFloat width = CGRectGetWidth(frame);
    CGFloat height = CGRectGetHeight(frame);
    BOOL sensibleSize = width >= 12.0 && height >= 12.0 && width <= 380.0 && height <= 380.0;
    if (image && sensibleSize && !duplicateImageView) {
        MUIScreenCandidate *candidate = [MUIScreenCandidate new];
        candidate.sourceView = view;
        NSString *semantic = view.accessibilityIdentifier.length > 0 ? view.accessibilityIdentifier : view.accessibilityLabel;
        candidate.identifier = semantic.length > 0
            ? [NSString stringWithFormat:@"%@|%@", NSStringFromClass(view.class), semantic]
            : path;
        candidate.displayName = semantic.length > 0 ? semantic : NSStringFromClass(view.class);
        candidate.contentType = @"icon";
        candidate.image = image;
        candidate.frameInRoot = frame;
        candidate.actionable = [view isKindOfClass:UIControl.class];
        [results addObject:candidate];
    }
    if (text.length > 0 && sensibleSize) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            MUIScreenCandidate *candidate = [MUIScreenCandidate new];
            candidate.sourceView = view;
            NSString *semantic = view.accessibilityIdentifier.length > 0 ? view.accessibilityIdentifier : view.accessibilityLabel;
            candidate.identifier = semantic.length > 0
                ? [NSString stringWithFormat:@"%@|text|%@", NSStringFromClass(view.class), semantic]
                : [path stringByAppendingString:@"|text"];
            candidate.displayName = trimmed;
            candidate.contentType = @"text";
            candidate.text = trimmed;
            if ([view isKindOfClass:UILabel.class]) {
                UILabel *label = (UILabel *)view;
                candidate.textColor = label.textColor;
                candidate.font = label.font;
            } else if ([view isKindOfClass:UIButton.class]) {
                UIButton *button = (UIButton *)view;
                candidate.textColor = [button titleColorForState:UIControlStateNormal] ?: button.tintColor;
                candidate.font = button.titleLabel.font;
            }
            candidate.frameInRoot = frame;
            candidate.actionable = [view isKindOfClass:UIControl.class];
            [results addObject:candidate];
        }
    }

    NSArray<UIView *> *subviews = view.subviews;
    [subviews enumerateObjectsUsingBlock:^(UIView *subview, NSUInteger index, BOOL *stop) {
        NSString *childPath = [path stringByAppendingFormat:@"/%@:%lu", NSStringFromClass(subview.class), (unsigned long)index];
        [self scanView:subview path:childPath root:root tabBar:tabBar results:results];
    }];
}

- (NSArray<MUIScreenCandidate *> *)scanCandidatesInRootView:(UIView *)rootView tabBar:(UITabBar *)tabBar {
    if (!rootView) return @[];
    NSMutableArray *results = [NSMutableArray array];
    [self scanView:rootView path:NSStringFromClass(rootView.class) root:rootView tabBar:tabBar results:results];
    return results;
}

- (NSMapTable<UIView *, NSNumber *> *)hiddenStatesForRoot:(UIView *)root create:(BOOL)create {
    NSMapTable *states = [self.hiddenStatesByRoot objectForKey:root];
    if (!states && create) {
        states = [NSMapTable weakToStrongObjectsMapTable];
        [self.hiddenStatesByRoot setObject:states forKey:root];
    }
    return states;
}

- (void)hideOriginalView:(UIView *)view inRoot:(UIView *)root {
    if (!view || !root) return;
    NSMapTable *states = [self hiddenStatesForRoot:root create:YES];
    if ([states objectForKey:view]) return;
    [states setObject:@(view.hidden) forKey:view];
    view.hidden = YES;
}

- (void)removeOverlayAndRestoreOriginalsForRootView:(UIView *)rootView {
    if (!rootView) return;
    [[self.hostsByRoot objectForKey:rootView] removeFromSuperview];
    NSMapTable *states = [self hiddenStatesForRoot:rootView create:NO];
    for (UIView *view in states.keyEnumerator) {
        NSNumber *hidden = [states objectForKey:view];
        view.hidden = hidden.boolValue;
    }
    [states removeAllObjects];
    [self.hostsByRoot removeObjectForKey:rootView];
    [self.hiddenStatesByRoot removeObjectForKey:rootView];
    [self.screenIDsByRoot removeObjectForKey:rootView];
}

- (void)removeOverlaysAndRestoreOriginals {
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    for (UIView *root in self.hostsByRoot.keyEnumerator) if (root) [roots addObject:root];
    for (UIView *root in self.hiddenStatesByRoot.keyEnumerator) {
        if (root && ![roots containsObject:root]) [roots addObject:root];
    }
    for (UIView *root in roots) [self removeOverlayAndRestoreOriginalsForRootView:root];
}

- (CGRect)frameFromDictionary:(NSDictionary *)dictionary inBounds:(CGRect)bounds {
    CGFloat x = [dictionary[@"x"] doubleValue] * CGRectGetWidth(bounds);
    CGFloat y = [dictionary[@"y"] doubleValue] * CGRectGetHeight(bounds);
    CGFloat width = [dictionary[@"w"] doubleValue] * CGRectGetWidth(bounds);
    CGFloat height = [dictionary[@"h"] doubleValue] * CGRectGetHeight(bounds);
    return CGRectMake(x, y, width, height);
}

- (UIImage *)imageForElement:(NSDictionary *)element fallback:(UIImage *)fallback {
    NSString *path = [element[@"icon_path"] isKindOfClass:NSString.class] ? element[@"icon_path"] : nil;
    UIImage *custom = path.length > 0 ? [[MUIConfigStore sharedStore] imageAtRelativePath:path] : nil;
    NSString *symbol = [element[@"symbol"] isKindOfClass:NSString.class] ? element[@"symbol"] : nil;
    UIImage *symbolImage = symbol.length > 0 ? [UIImage systemImageNamed:symbol] : nil;
    return custom ?: symbolImage ?: fallback;
}

- (NSString *)textForElement:(NSDictionary *)element {
    NSString *text = [element[@"text"] isKindOfClass:NSString.class] ? element[@"text"] : nil;
    return text.length > 0 ? text : @"Text";
}

- (void)styleTextLabel:(UILabel *)label inFrame:(CGRect)frame {
    CGFloat fontSize = MIN(MAX(CGRectGetHeight(frame) * 0.62, 8.0), 420.0);
    label.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.25;
    label.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.75];
    label.shadowOffset = CGSizeMake(0.0, 1.0);
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

- (void)presentActionPanelForElement:(NSDictionary *)element
                       forwardTarget:(UIControl *)forwardTarget
                          sourceView:(UIView *)sourceView {
    UIWindow *window = sourceView.window;
    UIViewController *presenter = window.rootViewController
        ? [self topViewControllerFrom:window.rootViewController] : nil;
    if (!presenter || presenter.presentedViewController) return;

    NSString *title = [element[@"panel_title"] isKindOfClass:NSString.class]
        ? element[@"panel_title"] : @"Số dư";
    NSString *message = [element[@"panel_message"] isKindOfClass:NSString.class]
        ? element[@"panel_message"] : @"Nhanh chóng di chuyển đến trang nạp/rút tiền trên trang web của broker";
    UIAlertController *panel = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [panel addAction:[UIAlertAction actionWithTitle:@"Tiền nạp" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [forwardTarget sendActionsForControlEvents:UIControlEventTouchUpInside];
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Tiền rút" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [forwardTarget sendActionsForControlEvents:UIControlEventTouchUpInside];
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    panel.popoverPresentationController.sourceView = sourceView;
    panel.popoverPresentationController.sourceRect = sourceView.bounds;
    [presenter presentViewController:panel animated:YES completion:nil];
}

- (void)applyScreenID:(NSString *)screenID rootView:(UIView *)rootView tabBar:(UITabBar *)tabBar {
    if (screenID.length == 0 || !rootView) return;
    UIView *cachedHost = [self.hostsByRoot objectForKey:rootView];
    NSString *cachedScreenID = [self.screenIDsByRoot objectForKey:rootView];
    if (cachedHost && [cachedScreenID isEqualToString:screenID]) {
        [rootView bringSubviewToFront:cachedHost];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [rootView layoutIfNeeded];
    [self removeOverlayAndRestoreOriginalsForRootView:rootView];
    NSArray<NSDictionary *> *elements = [[MUIScreenLayoutStore sharedStore] elementsForScreenID:screenID];
    if (elements.count == 0) {
        [CATransaction commit];
        return;
    }

    NSArray<MUIScreenCandidate *> *candidates = [self scanCandidatesInRootView:rootView tabBar:tabBar];
    NSMutableDictionary<NSString *, MUIScreenCandidate *> *candidateByID = [NSMutableDictionary dictionary];
    for (MUIScreenCandidate *candidate in candidates) candidateByID[candidate.identifier] = candidate;

    MUIPassthroughView *host = [[MUIPassthroughView alloc] initWithFrame:rootView.bounds];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.backgroundColor = UIColor.clearColor;
    host.tag = MUIScreenOverlayHostTag;
    [rootView addSubview:host];
    [self.hostsByRoot setObject:host forKey:rootView];
    [self.screenIDsByRoot setObject:screenID forKey:rootView];

    for (NSDictionary *element in elements) {
        NSString *type = element[@"type"];
        NSString *targetID = element[@"target_id"];
        MUIScreenCandidate *target = [type isEqualToString:@"existing"] ? candidateByID[targetID] : nil;
        if ([element[@"hidden"] boolValue]) {
            if (target.sourceView) [self hideOriginalView:target.sourceView inRoot:rootView];
            continue;
        }

        CGRect frame = [self frameFromDictionary:element[@"frame"] inBounds:rootView.bounds];
        if (CGRectGetWidth(frame) < 4.0 || CGRectGetHeight(frame) < 4.0) continue;
        BOOL isTextElement = [type isEqualToString:@"text"] ||
            [element[@"content_type"] isEqualToString:@"text"] ||
            [target.contentType isEqualToString:@"text"];
        if (isTextElement) {
            UILabel *label = [[UILabel alloc] initWithFrame:frame];
            NSString *text = [element[@"text"] isKindOfClass:NSString.class] ? element[@"text"] : target.text;
            label.text = text.length > 0 ? text : [self textForElement:element];
            label.backgroundColor = UIColor.clearColor;
            label.userInteractionEnabled = NO;
            [self styleTextLabel:label inFrame:frame];
            if (target.textColor) label.textColor = target.textColor;
            if (target.font) {
                CGFloat multiplier = CGRectGetHeight(frame) / MAX(CGRectGetHeight(target.frameInRoot), 1.0);
                label.font = [target.font fontWithSize:MIN(MAX(target.font.pointSize * multiplier, 8.0), 420.0)];
            }
            [host addSubview:label];
            if (target.sourceView) [self hideOriginalView:target.sourceView inRoot:rootView];
            continue;
        }
        UIImage *image = [self imageForElement:element fallback:target.image];
        if (!image) continue;

        NSString *actionTargetID = element[@"action_target"];
        MUIScreenCandidate *actionCandidate = candidateByID[actionTargetID ?: targetID];
        UIControl *actionControl = [actionCandidate.sourceView isKindOfClass:UIControl.class]
            ? (UIControl *)actionCandidate.sourceView : nil;

        UIView *overlay = nil;
        BOOL isCustom = [type isEqualToString:@"custom"];
        if (actionControl || isCustom) {
            MUIForwardingButton *button = [[MUIForwardingButton alloc] initWithFrame:frame];
            [button setImage:image forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            button.tintColor = target.sourceView.tintColor ?: rootView.tintColor;
            button.forwardTarget = actionControl;
            button.accessibilityLabel = element[@"name"] ?: target.displayName;
            if (isCustom) {
                __weak typeof(self) weakSelf = self;
                __weak UIControl *weakTarget = actionControl;
                __weak UIView *weakSource = button;
                button.tapHandler = ^{
                    [weakSelf presentActionPanelForElement:element
                                             forwardTarget:weakTarget
                                                sourceView:weakSource];
                };
            }
            overlay = button;
        } else {
            UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
            imageView.frame = frame;
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.tintColor = target.sourceView.tintColor ?: rootView.tintColor;
            imageView.userInteractionEnabled = NO;
            overlay = imageView;
        }
        if ([element[@"template"] boolValue]) {
            if ([overlay isKindOfClass:UIImageView.class]) ((UIImageView *)overlay).image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            if ([overlay isKindOfClass:UIButton.class]) [(UIButton *)overlay setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        }
        [host addSubview:overlay];
        if (target.sourceView) [self hideOriginalView:target.sourceView inRoot:rootView];
    }
    [CATransaction commit];
    [CATransaction flush];
}

@end
