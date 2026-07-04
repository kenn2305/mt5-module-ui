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
@end

@implementation MUIForwardingButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self addTarget:self action:@selector(forwardTap) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)forwardTap {
    [self.forwardTarget sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

@interface MUIScreenOverlayManager ()
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *originalHiddenStates;
@property (nonatomic, weak) UIView *activeHost;
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
    if (self) _originalHiddenStates = [NSMapTable weakToStrongObjectsMapTable];
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
        candidate.image = image;
        candidate.frameInRoot = frame;
        candidate.actionable = [view isKindOfClass:UIControl.class];
        [results addObject:candidate];
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

- (void)hideOriginalView:(UIView *)view {
    if (!view || [self.originalHiddenStates objectForKey:view]) return;
    [self.originalHiddenStates setObject:@(view.hidden) forKey:view];
    view.hidden = YES;
}

- (void)removeOverlaysAndRestoreOriginals {
    [self.activeHost removeFromSuperview];
    for (UIView *view in self.originalHiddenStates.keyEnumerator) {
        NSNumber *hidden = [self.originalHiddenStates objectForKey:view];
        view.hidden = hidden.boolValue;
    }
    [self.originalHiddenStates removeAllObjects];
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

- (void)applyScreenID:(NSString *)screenID rootView:(UIView *)rootView tabBar:(UITabBar *)tabBar {
    if (screenID.length == 0 || !rootView || !rootView.window) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [rootView layoutIfNeeded];
    [self removeOverlaysAndRestoreOriginals];
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
    self.activeHost = host;

    for (NSDictionary *element in elements) {
        NSString *type = element[@"type"];
        NSString *targetID = element[@"target_id"];
        MUIScreenCandidate *target = [type isEqualToString:@"existing"] ? candidateByID[targetID] : nil;
        if ([element[@"hidden"] boolValue]) {
            if (target.sourceView) [self hideOriginalView:target.sourceView];
            continue;
        }

        CGRect frame = [self frameFromDictionary:element[@"frame"] inBounds:rootView.bounds];
        if (CGRectGetWidth(frame) < 4.0 || CGRectGetHeight(frame) < 4.0) continue;
        UIImage *image = [self imageForElement:element fallback:target.image];
        if (!image) continue;

        NSString *actionTargetID = element[@"action_target"];
        MUIScreenCandidate *actionCandidate = candidateByID[actionTargetID ?: targetID];
        UIControl *actionControl = [actionCandidate.sourceView isKindOfClass:UIControl.class]
            ? (UIControl *)actionCandidate.sourceView : nil;

        UIView *overlay = nil;
        if (actionControl) {
            MUIForwardingButton *button = [[MUIForwardingButton alloc] initWithFrame:frame];
            [button setImage:image forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            button.tintColor = target.sourceView.tintColor ?: rootView.tintColor;
            button.forwardTarget = actionControl;
            button.accessibilityLabel = element[@"name"] ?: target.displayName;
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
        if (target.sourceView) [self hideOriginalView:target.sourceView];
    }
    [CATransaction commit];
    [CATransaction flush];
}

@end
