#import "AppDelegate.h"

#import "DatabaseManager.h"
#import "GBYManager.h"

#import "ABYServer.h"
#import "ABYContextManager.h"
#import "GCDWebDAVServer.h"

@interface AppDelegate ()

// Copied from Ambly Demo
@property (strong, nonatomic) ABYContextManager* contextManager;
@property (strong, nonatomic) ABYServer* replServer;
@property (strong, nonatomic) GCDWebDAVServer* davServer;

@end

void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"CRASH: %@", exception);
    NSLog(@"Stack Trace: %@", [exception callStackSymbols]);
}


@implementation AppDelegate

-(void)bootstrapContext:(JSContext*)context
{
    // Setup CLOSURE_IMPORT_SCRIPT
    [context evaluateScript:@"CLOSURE_IMPORT_SCRIPT = function(src) { require('goog/' + src); return true; }"];
    
    // TODO there is a path here assuming "out"
    
    // Load goog base
    NSString *basePath = [[NSBundle mainBundle] pathForResource:@"out/goog/base" ofType:@"js"];
    NSString *baseScriptString = [NSString stringWithContentsOfFile:basePath encoding:NSUTF8StringEncoding error:nil];
    [context evaluateScript:baseScriptString];
    
    // Load the deps file
    NSString *path = [[NSBundle mainBundle] pathForResource:@"main" ofType:@"js"];
    NSString *scriptString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSAssert(scriptString != nil, @"The JavaScript text could not be loaded");
    [context evaluateScript:scriptString];
    
    [context evaluateScript:@"goog.isProvided_ = function(x) { return false; };"];
    
    [context evaluateScript:@"goog.require = function (name) { return CLOSURE_IMPORT_SCRIPT(goog.dependencies_.nameToPath[name]); };"];
    
    [context evaluateScript:@"goog.require('cljs.core');"];
    
    // redef goog.require to track loaded libs
    [context evaluateScript:@"cljs.core._STAR_loaded_libs_STAR_ = new cljs.core.PersistentHashSet(null, new cljs.core.PersistentArrayMap(null, 1, ['cljs.core',null], null), null);\n"
     "\n"
     "goog.require = (function (name,reload){\n"
     "   if(cljs.core.truth_((function (){var or__4112__auto__ = !(cljs.core.contains_QMARK_.call(null,cljs.core._STAR_loaded_libs_STAR_,name));\n"
     "       if(or__4112__auto__){\n"
     "           return or__4112__auto__;\n"
     "       } else {\n"
     "           return reload;\n"
     "       }\n"
     "   })())){\n"
     "       cljs.core._STAR_loaded_libs_STAR_ = cljs.core.conj.call(null,(function (){var or__4112__auto__ = cljs.core._STAR_loaded_libs_STAR_;\n"
     "           if(cljs.core.truth_(or__4112__auto__)){\n"
     "               return or__4112__auto__;\n"
     "           } else {\n"
     "               return cljs.core.PersistentHashSet.EMPTY;\n"
     "           }\n"
     "       })(),name);\n"
     "       \n"
     "       return CLOSURE_IMPORT_SCRIPT((goog.dependencies_.nameToPath[name]));\n"
     "   } else {\n"
     "       return null;\n"
     "   }\n"
     "});"];

}

-(void)requireAppNamespaces:(JSContext*)context
{
    [context evaluateScript:@"goog.require('shrimp.core');"];
    
    // Need to require these as they are not referenced by shrimp.core (munging also needed)
    [context evaluateScript:@"goog.require('shrimp.master_view_controller');"];
    [context evaluateScript:@"goog.require('shrimp.detail_view_controller');"];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
    
    // Shut down the idle timer so that you can easily experiment
    // with the demo app from a device that is not connected to a Mac
    // running Xcode. Since this demo app isn't being released we
    // can do this unconditionally.
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    // All of the setup below is for dev.
    // For release the app would load files from shipping bundle.
    
    // Set up the compiler output directory
    NSURL* compilerOutputDirectory = [[self privateDocumentsDirectory] URLByAppendingPathComponent:@"cljs-out"];
    
    // Ensure private documents directory exists
    [self createDirectoriesUpTo:[self privateDocumentsDirectory]];
    
    // Copy resources from bundle "out" to compilerOutputDirectory

    NSFileManager* fileManager = [NSFileManager defaultManager];
    fileManager.delegate = self;
    
    // First blow away old compiler output directory
    
    [fileManager removeItemAtPath:compilerOutputDirectory.path error:nil];
    
    NSString *outPath = [[NSBundle mainBundle] pathForResource:@"out" ofType:nil];
    [fileManager copyItemAtPath:outPath toPath:compilerOutputDirectory.path error:nil];
    
    // Start up the REPL server
    self.contextManager = [[ABYContextManager alloc] initWithCompilerOutputDirectory:compilerOutputDirectory];
    self.replServer = [[ABYServer alloc] init];
    BOOL success = [self.replServer startListening:50505 forContext:self.contextManager.context];
    
    if (success) {
        // Start up the WebDAV server
        self.davServer = [[GCDWebDAVServer alloc] initWithUploadDirectory:compilerOutputDirectory.path];
#if TARGET_IPHONE_SIMULATOR
        NSString* bonjourName = [NSString stringWithFormat:@"Ambly %@ (%@)", [UIDevice currentDevice].model, [[NSProcessInfo processInfo] hostName]];
#else
        NSString* bonjourName = [NSString stringWithFormat:@"Ambly %@", [UIDevice currentDevice].name];
#endif
        
        bonjourName = [self cleanseBonjourName:bonjourName];
        
        [GCDWebDAVServer setLogLevel:2]; // Info
        [self.davServer startWithPort:8080 bonjourName:bonjourName];
    }
    
    
    // Override point for customization after application launch.
    
    NSLog(@"Initializing ClojureScript");
    
    [self bootstrapContext:self.contextManager.context];
    [self requireAppNamespaces:self.contextManager.context];
    
    self.cljsManager = [[GBYManager alloc] initWithInitFnName:@"init!" inNamespace:@"shrimp.core" withContext:self.contextManager.context];
    
    NSLog(@"Initializing database");
    self.databaseManager = [[DatabaseManager alloc] init];
    
    JSValue* setDatabaseManagerFn = [self.cljsManager getValue:@"set-database-manager!" inNamespace:@"shrimp.database"];
    [setDatabaseManagerFn callWithArguments:@[self.databaseManager]];

    return YES;
}

- (BOOL)fileManager:(NSFileManager *)fileManager shouldProceedAfterError:(NSError *)error copyingItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath{
    if ([error code] == 516) //error code for: The operation couldn’t be completed. File exists
        return YES;
    else
        return NO;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    // Saves changes in the application's managed object context before the application terminates.
}


// HELPERS COPIED VERBATIM FROM Ambly Demo

- (NSURL *)privateDocumentsDirectory
{
    NSURL *libraryDirectory = [[[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] lastObject];
    
    return [libraryDirectory URLByAppendingPathComponent:@"Private Documents"];
}

- (void)createDirectoriesUpTo:(NSURL*)directory
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:[directory path]]) {
        NSError *error = nil;
        
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[directory path]
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
            NSLog(@"Can't create directory %@ [%@]", [directory path], error);
            abort();
        }
    }
}

- (NSString*)cleanseBonjourName:(NSString*)bonjourName
{
    // Bonjour names  cannot contain dots
    bonjourName = [bonjourName stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    // Bonjour names cannot be longer than 63 characters in UTF-8
    
    int upperBound = 63;
    while (strlen(bonjourName.UTF8String) > 63) {
        NSRange stringRange = {0, upperBound};
        stringRange = [bonjourName rangeOfComposedCharacterSequencesForRange:stringRange];
        bonjourName = [bonjourName substringWithRange:stringRange];
        upperBound--;
    }
    return bonjourName;
}

// END HELPERS COPIED VERBATIM FROM Ambly Demo

@end
