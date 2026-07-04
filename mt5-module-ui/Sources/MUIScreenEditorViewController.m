#import <PhotosUI/PhotosUI.h>
#import "MUIScreenEditorViewController.h"
#import "MUIConfigStore.h"
#import "MUIScreenCandidate.h"
#import "MUIScreenLayoutStore.h"
#import "MUIScreenOverlayManager.h"
#import "MUIRuntime.h"

@interface MUIScreenHandle : UIButton
@property (nonatomic, copy) NSString *elementID;
@property (nonatomic, copy, nullable) NSString *targetID;
@property (nonatomic, copy) NSString *elementType;
@property (nonatomic, assign) BOOL actionableTarget;
@end

@implementation MUIScreenHandle
- (CGRect)imageRectForContentRect:(CGRect)contentRect {
    return CGRectInset(contentRect, 2.0, 2.0);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -10.0, -10.0), point);
}
@end

@interface MUIScreenEditorViewController () <PHPickerViewControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) MUIRuntime *runtime;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, weak) UITabBar *tabBar;
@property (nonatomic, copy) NSString *screenID;
@property (nonatomic, copy) NSArray<MUIScreenCandidate *> *candidates;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *elements;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MUIScreenCandidate *> *candidateByID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MUIScreenHandle *> *handleByElementID;
@property (nonatomic, weak) MUIScreenHandle *selectedHandle;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIView *precisionPanel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISlider *scaleSlider;
@property (nonatomic, strong) UILabel *scaleValueLabel;
@property (nonatomic, strong) UIPanGestureRecognizer *relativeMoveGesture;
@property (nonatomic, assign) CGSize scaleBaseSize;
@property (nonatomic, assign) BOOL linkingMode;
@property (nonatomic, copy, nullable) NSString *photoMode;
@end

@implementation MUIScreenEditorViewController

- (instancetype)initWithRuntime:(MUIRuntime *)runtime
                       rootView:(UIView *)rootView
                         tabBar:(UITabBar *)tabBar
                       screenID:(NSString *)screenID {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _runtime = runtime;
        _rootView = rootView;
        _tabBar = tabBar;
        _screenID = [screenID copy];
        _elements = [NSMutableArray array];
        _candidateByID = [NSMutableDictionary dictionary];
        _handleByElementID = [NSMutableDictionary dictionary];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.08];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.9];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.layer.cornerRadius = 10.0;
    self.statusLabel.clipsToBounds = YES;
    self.statusLabel.text = @"Select an icon • drag anywhere to move relatively";
    [self.view addSubview:self.statusLabel];

    [self buildToolbar];
    [self buildPrecisionPanel];
    self.relativeMoveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(canvasPanned:)];
    self.relativeMoveGesture.delegate = self;
    self.relativeMoveGesture.maximumNumberOfTouches = 1;
    [self.view addGestureRecognizer:self.relativeMoveGesture];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.precisionPanel.topAnchor constant:-6.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24.0],
        [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:34.0],
        [self.toolbar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [self.toolbar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [self.toolbar.heightAnchor constraintEqualToConstant:54.0]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[MUIScreenOverlayManager sharedManager] removeOverlayAndRestoreOriginalsForRootView:self.rootView];
    [self reloadCanvas];
}

- (UIButton *)toolbarButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.65;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildToolbar {
    UIVisualEffectView *background = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    background.layer.cornerRadius = 16.0;
    background.clipsToBounds = YES;
    self.toolbar = background;
    [self.view addSubview:background];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self toolbarButton:@"Cancel" action:@selector(cancelTapped)],
        [self toolbarButton:@"Add" action:@selector(addTapped)],
        [self toolbarButton:@"Replace" action:@selector(replaceTapped)],
        [self toolbarButton:@"Hide/Delete" action:@selector(hideTapped)],
        [self toolbarButton:@"Link" action:@selector(linkTapped)],
        [self toolbarButton:@"Reset" action:@selector(resetTapped)],
        [self toolbarButton:@"Apply" action:@selector(applyTapped)]
    ]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [background.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:background.contentView.leadingAnchor constant:4.0],
        [stack.trailingAnchor constraintEqualToAnchor:background.contentView.trailingAnchor constant:-4.0],
        [stack.topAnchor constraintEqualToAnchor:background.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:background.contentView.bottomAnchor]
    ]];
}

- (void)buildPrecisionPanel {
    UIVisualEffectView *background = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    background.layer.cornerRadius = 14.0;
    background.clipsToBounds = YES;
    self.precisionPanel = background;
    [self.view addSubview:background];

    UILabel *title = [UILabel new];
    title.text = @"Scale";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    self.scaleSlider = [UISlider new];
    self.scaleSlider.minimumValue = 0.2;
    self.scaleSlider.maximumValue = 50.0;
    self.scaleSlider.value = 1.0;
    self.scaleSlider.enabled = NO;
    self.scaleSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scaleSlider addTarget:self action:@selector(scaleSliderChanged:)
               forControlEvents:UIControlEventValueChanged];

    self.scaleValueLabel = [UILabel new];
    self.scaleValueLabel.text = @"1.00×";
    self.scaleValueLabel.textColor = UIColor.whiteColor;
    self.scaleValueLabel.textAlignment = NSTextAlignmentRight;
    self.scaleValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.scaleValueLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [background.contentView addSubview:title];
    [background.contentView addSubview:self.scaleSlider];
    [background.contentView addSubview:self.scaleValueLabel];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [background.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [background.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [background.bottomAnchor constraintEqualToAnchor:self.toolbar.topAnchor constant:-6.0],
        [background.heightAnchor constraintEqualToConstant:46.0],
        [title.leadingAnchor constraintEqualToAnchor:background.contentView.leadingAnchor constant:12.0],
        [title.centerYAnchor constraintEqualToAnchor:background.contentView.centerYAnchor],
        [title.widthAnchor constraintEqualToConstant:38.0],
        [self.scaleSlider.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8.0],
        [self.scaleSlider.centerYAnchor constraintEqualToAnchor:background.contentView.centerYAnchor],
        [self.scaleValueLabel.leadingAnchor constraintEqualToAnchor:self.scaleSlider.trailingAnchor constant:8.0],
        [self.scaleValueLabel.trailingAnchor constraintEqualToAnchor:background.contentView.trailingAnchor constant:-12.0],
        [self.scaleValueLabel.centerYAnchor constraintEqualToAnchor:background.contentView.centerYAnchor],
        [self.scaleValueLabel.widthAnchor constraintEqualToConstant:62.0]
    ]];
}

- (NSMutableDictionary *)mutableElementForID:(NSString *)elementID {
    for (NSMutableDictionary *element in self.elements) {
        if ([element[@"id"] isEqualToString:elementID]) return element;
    }
    return nil;
}

- (NSMutableDictionary *)elementForCandidate:(MUIScreenCandidate *)candidate create:(BOOL)create {
    for (NSMutableDictionary *element in self.elements) {
        if ([element[@"type"] isEqualToString:@"existing"] && [element[@"target_id"] isEqualToString:candidate.identifier]) {
            return element;
        }
    }
    if (!create) return nil;
    NSMutableDictionary *element = [@{
        @"id": [@"existing:" stringByAppendingString:candidate.identifier],
        @"type": @"existing",
        @"target_id": candidate.identifier,
        @"name": candidate.displayName ?: @"Icon",
        @"hidden": @NO,
        @"template": @NO,
        @"frame": [self normalizedFrameDictionary:candidate.frameInRoot]
    } mutableCopy];
    [self.elements addObject:element];
    return element;
}

- (NSDictionary *)normalizedFrameDictionary:(CGRect)frame {
    CGRect bounds = self.rootView.bounds;
    CGFloat width = MAX(CGRectGetWidth(bounds), 1.0);
    CGFloat height = MAX(CGRectGetHeight(bounds), 1.0);
    return @{
        @"x": @(CGRectGetMinX(frame) / width),
        @"y": @(CGRectGetMinY(frame) / height),
        @"w": @(CGRectGetWidth(frame) / width),
        @"h": @(CGRectGetHeight(frame) / height)
    };
}

- (CGRect)rootFrameFromDictionary:(NSDictionary *)frame {
    CGRect bounds = self.rootView.bounds;
    return CGRectMake([frame[@"x"] doubleValue] * CGRectGetWidth(bounds),
                      [frame[@"y"] doubleValue] * CGRectGetHeight(bounds),
                      [frame[@"w"] doubleValue] * CGRectGetWidth(bounds),
                      [frame[@"h"] doubleValue] * CGRectGetHeight(bounds));
}

- (CGRect)editorFrameForRootFrame:(CGRect)frame {
    return [self.rootView convertRect:frame toView:self.view];
}

- (CGRect)rootFrameForHandle:(MUIScreenHandle *)handle {
    return [self.view convertRect:handle.frame toView:self.rootView];
}

- (UIImage *)imageForElement:(NSDictionary *)element fallback:(UIImage *)fallback {
    NSString *path = element[@"icon_path"];
    UIImage *custom = [path isKindOfClass:NSString.class]
        ? [[MUIConfigStore sharedStore] imageAtRelativePath:path] : nil;
    NSString *symbol = element[@"symbol"];
    UIImage *symbolImage = [symbol isKindOfClass:NSString.class] ? [UIImage systemImageNamed:symbol] : nil;
    return custom ?: symbolImage ?: fallback ?: [UIImage systemImageNamed:@"square.dashed"];
}

- (void)reloadCanvas {
    for (MUIScreenHandle *handle in self.handleByElementID.allValues) [handle removeFromSuperview];
    [self.handleByElementID removeAllObjects];
    [self.candidateByID removeAllObjects];
    self.selectedHandle = nil;
    self.scaleSlider.enabled = NO;
    self.scaleSlider.value = 1.0;
    self.scaleValueLabel.text = @"1.00×";

    self.candidates = [[MUIScreenOverlayManager sharedManager] scanCandidatesInRootView:self.rootView tabBar:self.tabBar];
    for (MUIScreenCandidate *candidate in self.candidates) self.candidateByID[candidate.identifier] = candidate;

    [self.elements removeAllObjects];
    for (NSDictionary *element in [[MUIScreenLayoutStore sharedStore] elementsForScreenID:self.screenID]) {
        [self.elements addObject:[element mutableCopy]];
    }

    for (MUIScreenCandidate *candidate in self.candidates) {
        NSMutableDictionary *element = [self elementForCandidate:candidate create:NO];
        CGRect rootFrame = element ? [self rootFrameFromDictionary:element[@"frame"]] : candidate.frameInRoot;
        NSString *elementID = element[@"id"] ?: [@"candidate:" stringByAppendingString:candidate.identifier];
        [self createHandleWithElementID:elementID
                               targetID:candidate.identifier
                                   type:@"existing"
                                  frame:[self editorFrameForRootFrame:rootFrame]
                                  image:[self imageForElement:element fallback:candidate.image]
                             actionable:candidate.actionable
                                 hidden:[element[@"hidden"] boolValue]];
    }

    for (NSDictionary *element in self.elements) {
        if (![element[@"type"] isEqualToString:@"custom"]) continue;
        CGRect rootFrame = [self rootFrameFromDictionary:element[@"frame"]];
        [self createHandleWithElementID:element[@"id"]
                               targetID:nil
                                   type:@"custom"
                                  frame:[self editorFrameForRootFrame:rootFrame]
                                  image:[self imageForElement:element fallback:nil]
                             actionable:NO
                                 hidden:NO];
    }
    self.statusLabel.text = [NSString stringWithFormat:@"%lu icons found • tap, drag, pinch to edit", (unsigned long)self.candidates.count];
}

- (void)createHandleWithElementID:(NSString *)elementID
                         targetID:(NSString *)targetID
                             type:(NSString *)type
                            frame:(CGRect)frame
                            image:(UIImage *)image
                       actionable:(BOOL)actionable
                           hidden:(BOOL)hidden {
    if (elementID.length == 0 || CGRectIsEmpty(frame)) return;
    MUIScreenHandle *handle = [[MUIScreenHandle alloc] initWithFrame:frame];
    handle.elementID = elementID;
    handle.targetID = targetID;
    handle.elementType = type;
    handle.actionableTarget = actionable;
    [handle setImage:image forState:UIControlStateNormal];
    handle.imageView.contentMode = UIViewContentModeScaleAspectFit;
    handle.backgroundColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:hidden ? 0.28 : 0.12];
    handle.layer.borderColor = (hidden ? UIColor.systemRedColor : UIColor.systemBlueColor).CGColor;
    handle.layer.borderWidth = 1.0;
    handle.layer.cornerRadius = 6.0;
    [handle addTarget:self action:@selector(handleTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanned:)];
    pan.delegate = self;
    [handle addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinched:)];
    pinch.delegate = self;
    [handle addGestureRecognizer:pinch];

    [self.view insertSubview:handle belowSubview:self.toolbar];
    self.handleByElementID[elementID] = handle;
}

- (void)selectHandle:(MUIScreenHandle *)handle {
    self.selectedHandle.layer.borderWidth = 1.0;
    self.selectedHandle.layer.borderColor = UIColor.systemBlueColor.CGColor;
    self.selectedHandle = handle;
    self.scaleBaseSize = handle.bounds.size;
    self.scaleSlider.value = 1.0;
    self.scaleSlider.enabled = YES;
    self.scaleValueLabel.text = @"1.00×";
    handle.layer.borderWidth = 3.0;
    handle.layer.borderColor = UIColor.systemYellowColor.CGColor;
    NSString *name = [self mutableElementForID:handle.elementID][@"name"] ?: self.candidateByID[handle.targetID].displayName ?: @"Icon";
    self.statusLabel.text = [NSString stringWithFormat:@"Selected: %@", name];
}

- (void)scaleSliderChanged:(UISlider *)slider {
    MUIScreenHandle *handle = self.selectedHandle;
    if (!handle) return;
    CGFloat scale = slider.value;
    CGFloat width = MIN(MAX(self.scaleBaseSize.width * scale, 8.0), 20000.0);
    CGFloat height = MIN(MAX(self.scaleBaseSize.height * scale, 8.0), 20000.0);
    handle.bounds = CGRectMake(0, 0, width, height);
    self.scaleValueLabel.text = [NSString stringWithFormat:@"%.2f×", scale];
    [self materializeElementForHandle:handle];
}

- (void)canvasPanned:(UIPanGestureRecognizer *)gesture {
    MUIScreenHandle *handle = self.selectedHandle;
    if (!handle) return;
    CGPoint translation = [gesture translationInView:self.view];
    handle.center = CGPointMake(handle.center.x + translation.x, handle.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.view];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.statusLabel.text = @"Precision move: icon follows finger delta";
    }
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self materializeElementForHandle:handle];
        self.statusLabel.text = @"Position updated • tap Apply to save";
    }
}

- (void)handleTapped:(MUIScreenHandle *)handle {
    if (self.linkingMode && self.selectedHandle && [self.selectedHandle.elementType isEqualToString:@"custom"]) {
        if (![handle.elementType isEqualToString:@"existing"] || !handle.actionableTarget) {
            self.statusLabel.text = @"Choose an outlined button that performs an action";
            return;
        }
        NSMutableDictionary *custom = [self mutableElementForID:self.selectedHandle.elementID];
        custom[@"action_target"] = handle.targetID;
        self.linkingMode = NO;
        self.statusLabel.text = @"Action linked. Tap Apply to save.";
        return;
    }
    [self selectHandle:handle];
}

- (void)materializeElementForHandle:(MUIScreenHandle *)handle {
    NSMutableDictionary *element = [self mutableElementForID:handle.elementID];
    if (!element && handle.targetID) {
        MUIScreenCandidate *candidate = self.candidateByID[handle.targetID];
        element = [self elementForCandidate:candidate create:YES];
        self.handleByElementID[element[@"id"]] = handle;
        [self.handleByElementID removeObjectForKey:handle.elementID];
        handle.elementID = element[@"id"];
    }
    element[@"frame"] = [self normalizedFrameDictionary:[self rootFrameForHandle:handle]];
}

- (void)handlePanned:(UIPanGestureRecognizer *)gesture {
    MUIScreenHandle *handle = (MUIScreenHandle *)gesture.view;
    if (gesture.state == UIGestureRecognizerStateBegan) [self selectHandle:handle];
    CGPoint translation = [gesture translationInView:self.view];
    handle.center = CGPointMake(handle.center.x + translation.x, handle.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.view];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self materializeElementForHandle:handle];
    }
}

- (void)handlePinched:(UIPinchGestureRecognizer *)gesture {
    MUIScreenHandle *handle = (MUIScreenHandle *)gesture.view;
    if (gesture.state == UIGestureRecognizerStateBegan) [self selectHandle:handle];
    CGFloat width = MIN(MAX(CGRectGetWidth(handle.bounds) * gesture.scale, 8.0), 20000.0);
    CGFloat height = MIN(MAX(CGRectGetHeight(handle.bounds) * gesture.scale, 8.0), 20000.0);
    handle.bounds = CGRectMake(0, 0, width, height);
    gesture.scale = 1.0;
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self materializeElementForHandle:handle];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.relativeMoveGesture) return YES;
    if (!self.selectedHandle) return NO;
    UIView *touchView = touch.view;
    if ([touchView isDescendantOfView:self.toolbar] ||
        [touchView isDescendantOfView:self.precisionPanel] ||
        [touchView isDescendantOfView:self.statusLabel] ||
        [touchView isKindOfClass:MUIScreenHandle.class]) return NO;
    return YES;
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [[MUIScreenOverlayManager sharedManager] applyScreenID:self.screenID rootView:self.rootView tabBar:self.tabBar];
    }];
}

- (void)addTapped {
    [self presentIconSourceForMode:@"add"];
}

- (void)replaceTapped {
    if (!self.selectedHandle) {
        self.statusLabel.text = @"Select an icon before replacing it";
        return;
    }
    [self presentIconSourceForMode:@"replace"];
}

- (void)presentIconSourceForMode:(NSString *)mode {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[mode isEqualToString:@"add"] ? @"Add icon" : @"Replace icon"
                                                                   message:@"Choose a built-in shape or a photo"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *symbols = @{
        @"Plus": @"plus",
        @"Pencil": @"pencil",
        @"Clock": @"clock",
        @"Menu": @"line.3.horizontal",
        @"More": @"ellipsis",
        @"Chart": @"chart.xyaxis.line"
    };
    __weak typeof(self) weakSelf = self;
    for (NSString *title in @[@"Plus", @"Pencil", @"Clock", @"Menu", @"More", @"Chart"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf useSymbol:symbols[title] mode:mode];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose from Photos" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf presentPhotoPickerForMode:mode];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.toolbar;
    sheet.popoverPresentationController.sourceRect = self.toolbar.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)useSymbol:(NSString *)symbol mode:(NSString *)mode {
    if ([mode isEqualToString:@"add"]) {
        [self addCustomElementWithIconPath:nil symbol:symbol];
    } else {
        [self replaceSelectedWithIconPath:nil symbol:symbol];
    }
}

- (void)presentPhotoPickerForMode:(NSString *)mode {
    self.photoMode = mode;
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = PHPickerFilter.imagesFilter;
    configuration.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    NSString *mode = self.photoMode;
    self.photoMode = nil;
    if (!result || ![result.itemProvider canLoadObjectOfClass:UIImage.class]) return;
    __weak typeof(self) weakSelf = self;
    [result.itemProvider loadObjectOfClass:UIImage.class completionHandler:^(UIImage *image, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image || error) {
                weakSelf.statusLabel.text = error.localizedDescription ?: @"Could not load image";
                return;
            }
            NSString *iconID = [NSString stringWithFormat:@"screen_%@", NSUUID.UUID.UUIDString];
            NSError *saveError = nil;
            NSString *path = [[MUIConfigStore sharedStore] saveIconImage:image forModuleID:iconID error:&saveError];
            if (!path) {
                weakSelf.statusLabel.text = saveError.localizedDescription ?: @"Could not save image";
                return;
            }
            if ([mode isEqualToString:@"add"]) [weakSelf addCustomElementWithIconPath:path symbol:nil];
            else [weakSelf replaceSelectedWithIconPath:path symbol:nil];
        });
    }];
}

- (void)addCustomElementWithIconPath:(NSString *)iconPath symbol:(NSString *)symbol {
    NSString *identifier = [@"custom:" stringByAppendingString:NSUUID.UUID.UUIDString];
    CGRect rootBounds = self.rootView.bounds;
    CGRect frame = CGRectMake((CGRectGetWidth(rootBounds) - 52.0) / 2.0,
                              (CGRectGetHeight(rootBounds) - 52.0) / 2.0,
                              52.0, 52.0);
    NSMutableDictionary *element = [@{
        @"id": identifier,
        @"type": @"custom",
        @"name": @"Custom icon",
        @"hidden": @NO,
        @"template": @(symbol.length > 0),
        @"frame": [self normalizedFrameDictionary:frame]
    } mutableCopy];
    if (iconPath.length > 0) element[@"icon_path"] = iconPath;
    if (symbol.length > 0) element[@"symbol"] = symbol;
    [self.elements addObject:element];
    [self createHandleWithElementID:identifier targetID:nil type:@"custom"
                              frame:[self editorFrameForRootFrame:frame]
                              image:[self imageForElement:element fallback:nil]
                         actionable:NO hidden:NO];
    [self selectHandle:self.handleByElementID[identifier]];
    self.statusLabel.text = @"New icon added. Drag and pinch, then optionally Link an action.";
}

- (void)replaceSelectedWithIconPath:(NSString *)iconPath symbol:(NSString *)symbol {
    if (!self.selectedHandle) return;
    [self materializeElementForHandle:self.selectedHandle];
    NSMutableDictionary *element = [self mutableElementForID:self.selectedHandle.elementID];
    [element removeObjectForKey:@"icon_path"];
    [element removeObjectForKey:@"symbol"];
    if (iconPath.length > 0) element[@"icon_path"] = iconPath;
    if (symbol.length > 0) element[@"symbol"] = symbol;
    element[@"template"] = @(symbol.length > 0);
    UIImage *image = [self imageForElement:element fallback:self.candidateByID[self.selectedHandle.targetID].image];
    [self.selectedHandle setImage:image forState:UIControlStateNormal];
    self.statusLabel.text = @"Icon replaced. Tap Apply to save.";
}

- (void)hideTapped {
    if (!self.selectedHandle) {
        self.statusLabel.text = @"Select an icon first";
        return;
    }
    if ([self.selectedHandle.elementType isEqualToString:@"custom"]) {
        NSMutableDictionary *element = [self mutableElementForID:self.selectedHandle.elementID];
        [self.elements removeObject:element];
        [self.handleByElementID removeObjectForKey:self.selectedHandle.elementID];
        [self.selectedHandle removeFromSuperview];
        self.statusLabel.text = @"Custom icon deleted";
        self.selectedHandle = nil;
        self.scaleSlider.enabled = NO;
        return;
    }
    [self materializeElementForHandle:self.selectedHandle];
    NSMutableDictionary *element = [self mutableElementForID:self.selectedHandle.elementID];
    BOOL hidden = ![element[@"hidden"] boolValue];
    element[@"hidden"] = @(hidden);
    self.selectedHandle.backgroundColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:hidden ? 0.3 : 0.12];
    self.statusLabel.text = hidden ? @"Icon will be hidden" : @"Icon restored";
}

- (void)linkTapped {
    if (!self.selectedHandle || ![self.selectedHandle.elementType isEqualToString:@"custom"]) {
        self.statusLabel.text = @"Select a custom icon first";
        return;
    }
    self.linkingMode = YES;
    self.statusLabel.text = @"Now tap an outlined MT5 button to copy its action";
}

- (void)resetTapped {
    NSError *error = nil;
    if (![[MUIScreenLayoutStore sharedStore] resetScreenID:self.screenID error:&error]) {
        self.statusLabel.text = error.localizedDescription ?: @"Reset failed";
        return;
    }
    [self.elements removeAllObjects];
    [[MUIScreenOverlayManager sharedManager] removeOverlayAndRestoreOriginalsForRootView:self.rootView];
    [self reloadCanvas];
    self.statusLabel.text = @"Original screen layout restored";
}

- (void)applyTapped {
    for (MUIScreenHandle *handle in self.handleByElementID.allValues) {
        if ([handle.elementType isEqualToString:@"custom"] || [self mutableElementForID:handle.elementID]) {
            [self materializeElementForHandle:handle];
        }
    }
    NSError *error = nil;
    if (![[MUIScreenLayoutStore sharedStore] saveElements:self.elements forScreenID:self.screenID error:&error]) {
        self.statusLabel.text = error.localizedDescription ?: @"Could not save screen layout";
        return;
    }
    [self dismissViewControllerAnimated:YES completion:^{
        [[MUIScreenOverlayManager sharedManager] applyScreenID:self.screenID rootView:self.rootView tabBar:self.tabBar];
    }];
}

@end
