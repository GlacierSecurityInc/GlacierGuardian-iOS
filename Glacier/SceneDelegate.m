//
//  SceneDelegate.m
//  Glacier
//
//  Created by Codex on 2026-02-03.
//

#import "SceneDelegate.h"
#import "GlacierAppDelegate.h"

@interface GlacierAppDelegate (SceneSupport)
- (UIViewController *)setupMainInterfaceIfNeeded;
@end

typedef NS_ENUM(NSInteger, GlacierSceneLifecycleEvent) {
    GlacierSceneLifecycleEventWillResignActive,
    GlacierSceneLifecycleEventDidBecomeActive,
    GlacierSceneLifecycleEventWillEnterForeground,
    GlacierSceneLifecycleEventDidEnterBackground
};

@implementation SceneDelegate
{
    GlacierSceneLifecycleEvent _lastLifecycleEvent;
    CFTimeInterval _lastLifecycleEventTime;
}

- (BOOL)shouldForwardLifecycleEvent:(GlacierSceneLifecycleEvent)event
{
    CFTimeInterval now = CACurrentMediaTime();
    if (_lastLifecycleEvent == event && (now - _lastLifecycleEventTime) < 0.5) {
        return NO;
    }
    _lastLifecycleEvent = event;
    _lastLifecycleEventTime = now;
    return YES;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    // NSLog(@"*****DBG SceneDelegate willConnectToSession");

    GlacierAppDelegate *appDelegate = GlacierAppDelegate.appDelegate;
    UIWindowScene *windowScene = (UIWindowScene *)scene;

    if (appDelegate.window == nil || appDelegate.window.windowScene != windowScene) {
        appDelegate.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    }

    UIViewController *rootViewController = [appDelegate setupMainInterfaceIfNeeded];
    if (rootViewController != nil) {
        appDelegate.window.rootViewController = rootViewController;
    }

    [appDelegate.window makeKeyAndVisible];
    self.window = appDelegate.window;

    if (connectionOptions.URLContexts.count > 0) {
        // NSLog(@"*****DBG SceneDelegate willConnectToSession forwarding URLContexts: %lu", (unsigned long)connectionOptions.URLContexts.count);
        [self scene:scene openURLContexts:connectionOptions.URLContexts];
    }

    if (connectionOptions.userActivities.count > 0) {
        // NSLog(@"*****DBG SceneDelegate willConnectToSession forwarding userActivities: %lu", (unsigned long)connectionOptions.userActivities.count);
        for (NSUserActivity *activity in connectionOptions.userActivities) {
            [self scene:scene continueUserActivity:activity];
        }
    }
}

- (void)sceneWillResignActive:(UIScene *)scene
{
    if ([self shouldForwardLifecycleEvent:GlacierSceneLifecycleEventWillResignActive]) {
        // NSLog(@"*****DBG SceneDelegate sceneWillResignActive forwarding to GlacierAppDelegate");
        [GlacierAppDelegate.appDelegate applicationWillResignActive:UIApplication.sharedApplication];
    } else {
        // NSLog(@"*****DBG SceneDelegate sceneWillResignActive suppressed (duplicate)");
    }
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
    if ([self shouldForwardLifecycleEvent:GlacierSceneLifecycleEventDidBecomeActive]) {
        // NSLog(@"*****DBG SceneDelegate sceneDidBecomeActive forwarding to GlacierAppDelegate");
        [GlacierAppDelegate.appDelegate applicationDidBecomeActive:UIApplication.sharedApplication];
    } else {
        // NSLog(@"*****DBG SceneDelegate sceneDidBecomeActive suppressed (duplicate)");
    }
}

- (void)sceneWillEnterForeground:(UIScene *)scene
{
    if ([self shouldForwardLifecycleEvent:GlacierSceneLifecycleEventWillEnterForeground]) {
        // NSLog(@"*****DBG SceneDelegate sceneWillEnterForeground forwarding to GlacierAppDelegate");
        [GlacierAppDelegate.appDelegate applicationWillEnterForeground:UIApplication.sharedApplication];
    } else {
        // NSLog(@"*****DBG SceneDelegate sceneWillEnterForeground suppressed (duplicate)");
    }
}

- (void)sceneDidEnterBackground:(UIScene *)scene
{
    if ([self shouldForwardLifecycleEvent:GlacierSceneLifecycleEventDidEnterBackground]) {
        // NSLog(@"*****DBG SceneDelegate sceneDidEnterBackground forwarding to GlacierAppDelegate");
        [GlacierAppDelegate.appDelegate applicationDidEnterBackground:UIApplication.sharedApplication];
    } else {
        // NSLog(@"*****DBG SceneDelegate sceneDidEnterBackground suppressed (duplicate)");
    }
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity
{
    // NSLog(@"*****DBG SceneDelegate continueUserActivity forwarding to GlacierAppDelegate");
    [GlacierAppDelegate.appDelegate application:UIApplication.sharedApplication
                        continueUserActivity:userActivity
                          restorationHandler:^(NSArray<id<UIUserActivityRestoring>> * _Nonnull restorableObjects) {
    }];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
    // NSLog(@"*****DBG SceneDelegate openURLContexts count=%lu", (unsigned long)URLContexts.count);
    for (UIOpenURLContext *context in URLContexts) {
        NSURL *url = context.URL;
        NSMutableDictionary<UIApplicationOpenURLOptionsKey, id> *options = [NSMutableDictionary dictionary];
        UISceneOpenURLOptions *sceneOptions = context.options;
        if (sceneOptions.sourceApplication != nil) {
            options[UIApplicationOpenURLOptionsSourceApplicationKey] = sceneOptions.sourceApplication;
        }
        if (sceneOptions.annotation != nil) {
            options[UIApplicationOpenURLOptionsAnnotationKey] = sceneOptions.annotation;
        }
        options[UIApplicationOpenURLOptionsOpenInPlaceKey] = @(sceneOptions.openInPlace);
        [GlacierAppDelegate.appDelegate application:UIApplication.sharedApplication openURL:url options:options];
    }
}

@end
