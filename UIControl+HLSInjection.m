//
//  UIResponder+HLSInjection.m
//  nut
//
//  Created by Samuel Défago on 3/8/11.
//  Copyright 2011 Hortis. All rights reserved.
//

#import <objc/runtime.h> 

// Constants
static const char * const kSentinelTouchDownSelectorNameCStr = "hls_sentinelTouchDownAction";
static const char * const kSentinelTouchUpSelectorNameCStr = "hls_sentinelTouchUpAction";

static NSString * const kWrapperDownPrefix = @"hls_wrapper_down_";
static NSString * const kWrapperUpPrefix = @"hls_wrapper_up_";

// No threading issues here, UIKit is not to be used concurrently
static UIControl *s_currentControl;
static NSMutableSet *s_inhibitedControls;

// Original implementation of the methods we swizzle
static IMP s_initWithFrame$Imp;
static IMP s_initWithCoder$Imp;
static IMP s_addTarget$action$forControlEvents$Imp;
static IMP s_removeTarget$action$forControlEvents$Imp;
static IMP s_actionsForTarget$forControlEvent$Imp;

// Sentinel selectors
static SEL s_sentinelTouchDownActionSel;
static SEL s_sentinelTouchUpActionSel;

// Static methods
static void swizzleSelector(Class class, SEL origSel, SEL newSel);

static void sentinelTouchDownActionImp(id self, SEL sel, id sender);
static void sentinelTouchUpActionImp(id self, SEL sel, id sender);

static void wrapperTouchDownActionImp(id self, SEL sel, id sender);
static void wrapperTouchUpActionImp(id self, SEL sel, id sender);

static void callWrappedAction(id self, SEL sel, id sender);

#pragma mark -
#pragma mark UIControl (HLSInjectionPrivate) interface

/** 
 * The code works as follows: We replace the usual UIControl event / target methods by wrappers using swizzling (the
 * implementations we replace are still called internally, the original behavior is therefore preserved). To track touch
 * events (touch up and down events), we then register two "sentinel" actions:
 *   - touch down event sentinel (must stay the first action in the list of touch down actions): To start tracking a 
 *     control if none was currently active. If a control is already active, any control receiving a touch down event 
 *     is marked as inhibited, and will remain so until this flag is removed (see below)
 *   - touch up event sentinel (must stay the last action in the list of touch up actions): To strop tracking the currently 
 *     active control
 * To be able to track touch up / down events added by the user, the addTarget:action:forControlEvents: method is
 * also swizzled to register a wrapper for the action, instead of the action itself. This wrapper simply executes the 
 * original action if the control is active, but immediately returns if the control has been inhibited. The other 
 * target / action methods are swizzled as well to make the injection invisible externally.
 *
 * When a control is tapped but no other one is the currently active one, all controls which were marked as inhibited 
 * are reset. We identify such inhibited controls by storing them into a set. To avoid retaining controls unnecessarily, 
 * this set stores weak references by wrapping object pointers into NSValue objects.
 */
@interface UIControl (HLSInjectionPrivate)

- (id)swizzledInitWithFrame:(CGRect)frame;
- (id)swizzledInitWithCoder:(NSCoder *)aDecoder;
- (void)swizzledAddTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents;
- (void)swizzledRemoveTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents;
- (NSArray *)swizzledActionsForTarget:(id)target forControlEvent:(UIControlEvents)controlEvent;

- (void)addSentinelActions;

@end

#pragma mark -
#pragma mark UIControl (HLSInjection) implementation

@implementation UIControl (HLSInjection)

#pragma mark Class methods

+ (void)injectQuasiSimultaneousTapsDisabler
{
    // Test if already injected
    if (s_inhibitedControls) {
        return;
    }
    
    // Get the original implementations we want to swizzle
    s_initWithFrame$Imp = method_getImplementation(class_getInstanceMethod([self class], 
                                                                           @selector(initWithFrame:)));
    s_initWithCoder$Imp = method_getImplementation(class_getInstanceMethod([self class], 
                                                                           @selector(initWithCoder:)));
    s_addTarget$action$forControlEvents$Imp = method_getImplementation(class_getInstanceMethod([self class], 
                                                                                               @selector(addTarget:action:forControlEvents:)));
    s_removeTarget$action$forControlEvents$Imp = method_getImplementation(class_getInstanceMethod([self class], 
                                                                                                  @selector(removeTarget:action:forControlEvents:)));
    s_actionsForTarget$forControlEvent$Imp = method_getImplementation(class_getInstanceMethod([self class], 
                                                                                              @selector(actionsForTarget:forControlEvent:)));    
    // Swizzle with custom wrappers
    swizzleSelector([self class], @selector(initWithFrame:), @selector(swizzledInitWithFrame:));
    swizzleSelector([self class], @selector(initWithCoder:), @selector(swizzledInitWithCoder:));
    swizzleSelector([self class], @selector(addTarget:action:forControlEvents:), @selector(swizzledAddTarget:action:forControlEvents:));
    swizzleSelector([self class], @selector(removeTarget:action:forControlEvents:), @selector(swizzledRemoveTarget:action:forControlEvents:));
    swizzleSelector([self class], @selector(actionsForTarget:forControlEvent:), @selector(swizzledActionsForTarget:forControlEvent:));
    
    // Create and inject sentinel methods
    s_sentinelTouchDownActionSel = sel_registerName(kSentinelTouchDownSelectorNameCStr);
    class_addMethod([self class],
                    s_sentinelTouchDownActionSel,
                    (IMP)sentinelTouchDownActionImp,
                    "v@:@");
    s_sentinelTouchUpActionSel = sel_registerName(kSentinelTouchUpSelectorNameCStr);
    class_addMethod([self class],
                    s_sentinelTouchUpActionSel,
                    (IMP)sentinelTouchUpActionImp,
                    "v@:@");    
    
    // Set for tracking inhibited controls
    s_inhibitedControls = [[NSMutableSet alloc] init];
}

@end

#pragma mark -
#pragma mark UIControl (HLSInjectionPrivate) implementation

@implementation UIControl (HLSInjectionPrivate)

#pragma mark Methods injected by swizzling

- (id)swizzledInitWithFrame:(CGRect)frame
{    
    // Call the original implementation
    if ((self = (*s_initWithFrame$Imp)(self, @selector(initWithFrame:), frame))) {
        [self addSentinelActions];
    }
    return self;
}

- (id)swizzledInitWithCoder:(NSCoder *)aDecoder
{
    // Call the original implementation
    if ((self = (*s_initWithCoder$Imp)(self, @selector(initWithCoder:), aDecoder))) {
        [self addSentinelActions];
    }
    return self;
}

- (void)swizzledAddTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents
{
    // Register action wrappers for touch down actions (if any)
    UIControlEvents touchDownFlags = UIControlEventTouchDown | UIControlEventTouchDownRepeat;
    if (controlEvents & touchDownFlags) {
        // A target has been given; the most natural location where to insert the wrapper action is the target class itself (where the non-wrapped 
        // action must have already been defined)
        Class class;
        if (target) {
            class = [target class];
        }
        // If the target is nil, then the message is sent along the responder chain until a responder handles it (see UIControl documentation). To be
        // able to reach our wrapper first, we add it as early as possible in the responder chain (i.e. in UIControl). We will then use it to send
        // the original action along the responder chain
        else {
            class = [UIControl class];
        }
        
        // Wrapper name is simply original name with prefix
        NSString *wrapperTouchDownActionName = [kWrapperDownPrefix stringByAppendingString:[NSString stringWithUTF8String:sel_getName(action)]];
        
        // Create the method dynamically and add it to the target class
        SEL wrapperTouchDownActionSel = sel_registerName([wrapperTouchDownActionName UTF8String]);
        class_addMethod(class,
                        wrapperTouchDownActionSel,
                        (IMP)wrapperTouchDownActionImp,
                        "v@:@");            // Same prototype as action, i.e. - (void)methodName:(id)sender
        
        // Register the new target / action
        (*s_addTarget$action$forControlEvents$Imp)(self, 
                                                   @selector(addTarget:action:forControlEvents:), 
                                                   target, 
                                                   wrapperTouchDownActionSel, 
                                                   controlEvents & touchDownFlags); 
        
        // Already dealt with these events specifically; remove them from the mask
        controlEvents &= ~touchDownFlags;
    }
    
    // Register action wrappers for touch up actions (if any)
    UIControlEvents touchUpFlags = UIControlEventTouchUpInside | UIControlEventTouchUpOutside;
    if (controlEvents & touchUpFlags) {
        // A target has been given; the most natural location where to insert the wrapper action is the target class itself (where the non-wrapped 
        // action must have already been defined)
        Class class;
        if (target) {
            class = [target class];
        }
        // If the target is nil, then the message is sent along the responder chain until a responder handles it (see UIControl documentation). To be
        // able to reach our wrapper first, we add it as early as possible in the responder chain (i.e. in UIControl). We will then use it to send
        // the original action along the responder chain        
        else {
            class = [UIControl class];
        }
        
        // Wrapper name is simply original name with prefix
        NSString *wrapperTouchUpActionName = [kWrapperUpPrefix stringByAppendingString:[NSString stringWithUTF8String:sel_getName(action)]];
        
        // Create the method dynamically and add it to the UIControl class
        SEL wrapperTouchUpActionSel = sel_registerName([wrapperTouchUpActionName UTF8String]);
        class_addMethod(class,
                        wrapperTouchUpActionSel,
                        (IMP)wrapperTouchUpActionImp,
                        "v@:@");            // Same prototype as action, i.e. - (void)methodName:(id)sender 
        
        // We want the touch up sentinel method to be always the last one to be called; remove the one already installed
        (*s_removeTarget$action$forControlEvents$Imp)(self,
                                                      @selector(removeTarget:action:forControlEvents:),
                                                      target,
                                                      s_sentinelTouchUpActionSel,
                                                      controlEvents & touchUpFlags);
        
        // Register the new target / action
        (*s_addTarget$action$forControlEvents$Imp)(self, 
                                                   @selector(addTarget:action:forControlEvents:), 
                                                   target, 
                                                   wrapperTouchUpActionSel, 
                                                   controlEvents & touchUpFlags); 
        
        // Re-install the sentinel method as last action
        (*s_addTarget$action$forControlEvents$Imp)(self, 
                                                   @selector(addTarget:action:forControlEvents:), 
                                                   self, 
                                                   s_sentinelTouchUpActionSel, 
                                                   controlEvents & touchUpFlags);       
        
        // Already dealt with these events specifically; remove them from the mask
        controlEvents &= ~touchUpFlags;
    }
    
    // For all other events (if any remain) simply register the action we receive
    if (controlEvents != 0) {
        (*s_addTarget$action$forControlEvents$Imp)(self, 
                                                   @selector(addTarget:action:forControlEvents:), 
                                                   target, 
                                                   action, 
                                                   controlEvents);         
    }
}

- (void)swizzledRemoveTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents
{
    // Touch down event: Remove the wrapper
    UIControlEvents touchDownFlags = UIControlEventTouchDown | UIControlEventTouchDownRepeat;
    if (controlEvents & touchDownFlags) {
        // Wrapper name is simply original name with prefix
        NSString *wrapperTouchDownActionName = [kWrapperDownPrefix stringByAppendingString:[NSString stringWithUTF8String:sel_getName(action)]];
        SEL wrapperTouchDownActionSel = sel_registerName([wrapperTouchDownActionName UTF8String]);
        
        (*s_removeTarget$action$forControlEvents$Imp)(self, 
                                                      @selector(removeTarget:action:forControlEvents:), 
                                                      target, 
                                                      wrapperTouchDownActionSel, 
                                                      controlEvents & touchDownFlags);        
        
        // Already dealt with these events specifically; remove them from the mask
        controlEvents &= ~touchDownFlags;
    }
    
    // Touch up event: Remove the wrapper
    UIControlEvents touchUpFlags = UIControlEventTouchUpInside | UIControlEventTouchUpOutside;
    if (controlEvents & touchUpFlags) {
        // Wrapper name is simply original name with prefix
        NSString *wrapperTouchUpActionName = [kWrapperUpPrefix stringByAppendingString:[NSString stringWithUTF8String:sel_getName(action)]];
        SEL wrapperTouchUpActionSel = sel_registerName([wrapperTouchUpActionName UTF8String]);
        
        (*s_removeTarget$action$forControlEvents$Imp)(self, 
                                                      @selector(removeTarget:action:forControlEvents:), 
                                                      target, 
                                                      wrapperTouchUpActionSel, 
                                                      controlEvents & touchUpFlags);       
        
        // Already dealt with these events specifically; remove them from the mask
        controlEvents &= ~touchUpFlags;
    }
    
    // Remove directly if registrations for other events remain
    if (controlEvents != 0) {
        (*s_removeTarget$action$forControlEvents$Imp)(self, 
                                                      @selector(removeTarget:action:forControlEvents:), 
                                                      target, 
                                                      action, 
                                                      controlEvents);        
    }
}

- (NSArray *)swizzledActionsForTarget:(id)target forControlEvent:(UIControlEvents)controlEvent
{   
    // Call the original implementation
    NSArray *internalActionNames = (*s_actionsForTarget$forControlEvent$Imp)(self,
                                                                             @selector(actionsForTarget:forControlEvent:),
                                                                             target,
                                                                             controlEvent);
    
    // Returned wrapped methods, not wrappers. This way, our wrapper injection remains completely invisible
    NSMutableArray *actionNames = [NSMutableArray array];
    for (NSString *actionName in internalActionNames) {
        // Cleanup wrapper prefixes (if any)
        NSString *originalActionName = [actionName stringByReplacingOccurrencesOfString:kWrapperDownPrefix withString:@""];
        originalActionName = [originalActionName stringByReplacingOccurrencesOfString:kWrapperUpPrefix withString:@""];
        [actionNames addObject:originalActionName];
    }
    
    return [NSArray arrayWithArray:actionNames];
}

#pragma mark Miscellaneous methods

- (void)addSentinelActions
{   
    (*s_addTarget$action$forControlEvents$Imp)(self, 
                                               @selector(addTarget:action:forControlEvents:), 
                                               self, 
                                               s_sentinelTouchDownActionSel, 
                                               UIControlEventTouchDown | UIControlEventTouchDownRepeat);  
    
    (*s_addTarget$action$forControlEvents$Imp)(self, 
                                               @selector(addTarget:action:forControlEvents:), 
                                               self, 
                                               s_sentinelTouchUpActionSel, 
                                               UIControlEventTouchUpInside | UIControlEventTouchUpOutside); 
}

@end

#pragma mark Swizzler

static void swizzleSelector(Class class, SEL origSel, SEL newSel)
{
    Method origMethod = class_getInstanceMethod(class, origSel);
    Method newMethod = class_getInstanceMethod(class, newSel);
    if (class_addMethod(class, origSel, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(class, origSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    }
    else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

#pragma mark Sentinel action implementations

static void sentinelTouchDownActionImp(id self, SEL sel, id sender)
{
    // Other control pressed while one is active. Inhibit
    if (s_currentControl && s_currentControl != self) {
        // Store a weak ref to the object using an NSValue
        [s_inhibitedControls addObject:[NSValue valueWithPointer:self]];
        return;
    }
    
    // Cleanup inhibited list; some controls might not have had the time to unflag them in some situations
    [s_inhibitedControls removeAllObjects];
    
    s_currentControl = self;
}

static void sentinelTouchUpActionImp(id self, SEL sel, id sender)
{
    // Last event; if current control, done protecting it
    if (s_currentControl == self) {
        s_currentControl = nil;
    }
}

#pragma mark Wrapper action implementations

static void wrapperTouchDownActionImp(id self, SEL sel, id sender)
{
    if ([s_inhibitedControls containsObject:[NSValue valueWithPointer:self]]) {
        return;
    }
    
    // Remove the prefix
    NSString *selectorName = [[NSString stringWithUTF8String:sel_getName(sel)] stringByReplacingOccurrencesOfString:kWrapperDownPrefix
                                                                                                         withString:@""];
    
    // Deduce the original action and call it
    SEL originalSel = sel_registerName([selectorName UTF8String]);
    callWrappedAction(self, originalSel, sender);
}

static void wrapperTouchUpActionImp(id self, SEL sel, id sender)
{
    if ([s_inhibitedControls containsObject:[NSValue valueWithPointer:sender]]) {
        return;
    }
    
    // Remove the prefix
    NSString *selectorName = [[NSString stringWithUTF8String:sel_getName(sel)] stringByReplacingOccurrencesOfString:kWrapperUpPrefix
                                                                                                         withString:@""];
    
    // Deduce the original action and call it
    SEL originalSel = sel_registerName([selectorName UTF8String]);
    callWrappedAction(self, originalSel, sender);
}

static void callWrappedAction(id self, SEL sel, id sender)
{
    // Original action defined on self; case where the wrapper has been directly added to the target class; we can call the original
    // action directly
    if ([self respondsToSelector:sel]) {
        IMP originalImp = method_getImplementation(class_getInstanceMethod([self class], sel));
        (*originalImp)(self, sel, sender);
    }
    // Original action not defined on self; send it along the responder chain until some responder deals with it
    else {
        [self sendAction:sel to:nil forEvent:nil];
    }
}
