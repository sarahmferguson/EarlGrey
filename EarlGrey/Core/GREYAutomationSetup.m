//
// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "Core/GREYAutomationSetup.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>

#import "Common/GREYDefines.h"
#import "Common/GREYExposed.h"

@implementation GREYAutomationSetup

+ (instancetype)sharedInstance {
  static GREYAutomationSetup *sharedInstance = nil;
  static dispatch_once_t token = 0;
  dispatch_once(&token, ^{
    sharedInstance = [[GREYAutomationSetup alloc] initOnce];
  });
  return sharedInstance;
}

- (instancetype)initOnce {
  self = [super init];
  return self;
}

- (void)perform {
  Class selfClass = [self class];
  [selfClass grey_setupCrashHandlers];

  [self grey_enableAccessibility];
  // Force software keyboard.
  [[UIKeyboardImpl sharedInstance] setAutomaticMinimizationEnabled:NO];
  // Turn off auto correction as it interferes with typing on iOS8.2+.
  if (iOS8_2_OR_ABOVE()) {
    [selfClass grey_modifyKeyboardSettings];
  }
}

#pragma mark - Automation Setup

// Modifies the autocorrect and predictive typing settings to turn them off through the
// keyboard settings bundle.
+ (void)grey_modifyKeyboardSettings {
  NSString *keyboardSettingsPrefBundlePath =
      @"/System/Library/PreferenceBundles/KeyboardSettings.bundle/KeyboardSettings";
  NSString *keyboardControllerClassName = @"KeyboardController";
  id keyboardControllerInstance =
      [self grey_classInstanceFromBundleAtPath:keyboardSettingsPrefBundlePath
                                 withClassName:keyboardControllerClassName];
  [keyboardControllerInstance setAutocorrectionPreferenceValue:@(NO) forSpecifier:nil];
  [keyboardControllerInstance setPredictionPreferenceValue:@(NO) forSpecifier:nil];
}

// For the provided bundle @c path, we use the actual @c className of the class to extract and
// return a class instance that can be modified.
+ (id)grey_classInstanceFromBundleAtPath:(NSString *)path withClassName:(NSString *)className {
  NSParameterAssert(path);
  NSParameterAssert(className);
  char const *const preferenceBundlePath = [path fileSystemRepresentation];
  void *handle = dlopen(preferenceBundlePath, RTLD_LAZY);
  if (!handle) {
    NSAssert(NO, @"dlopen couldn't open settings bundle at path bundle %@", path);
  }

  Class klass = NSClassFromString(className);
  if (!klass) {
    NSAssert(NO, @"Couldn't find %@ class", klass);
  }

  id klassInstance = [[klass alloc] init];
  if (!klassInstance) {
    NSAssert(NO, @"Couldn't initialize controller for class: %@", klass);
  }

  return klassInstance;
}

// Enables accessibility as it is required for using any properties of the accessibility tree.
- (void)grey_enableAccessibility {
  char const *const libAccessibilityPath =
      [@"/usr/lib/libAccessibility.dylib" fileSystemRepresentation];
  void *handle = dlopen(libAccessibilityPath, RTLD_LOCAL);
  NSAssert(handle, @"dlopen couldn't open libAccessibility.dylib at path %s", libAccessibilityPath);
  void (*_AXSSetAutomationEnabled)(BOOL) = dlsym(handle, "_AXSSetAutomationEnabled");
  NSAssert(_AXSSetAutomationEnabled, @"Pointer to _AXSSetAutomationEnabled must not be NULL");

  _AXSSetAutomationEnabled(YES);
}

#pragma mark - Crash Handlers

// Call only asynchronous-safe functions within signal handlers
// Learn more: https://www.securecoding.cert.org/confluence/display/c/SIG00-C.+Mask+signals+handled+by+noninterruptible+signal+handlers
static void grey_signalHandler(int signal) {
  char *signalString = strsignal(signal);
  write(STDERR_FILENO, signalString, strlen(signalString));
  write(STDERR_FILENO, "\n", 1);
  static const int kMaxStackSize = 128;
  void *callStack[kMaxStackSize];
  const int numFrames = backtrace(callStack, kMaxStackSize);
  backtrace_symbols_fd(callStack, numFrames, STDERR_FILENO);
  kill(getpid(), SIGKILL);
}

static void grey_uncaughtExceptionHandler(NSException *exception) {
  NSLog(@"Uncaught exception: %@", exception);
  exit(-1);
}

static void grey_installSignalHandler(int signalId, struct sigaction *handler) {
  int returnValue = sigaction(signalId, handler, NULL);
  if (returnValue != 0) {
    NSLog(@"Error installing %s handler: '%s'.", strsignal(signalId), strerror(errno));
  }
}

+ (void)grey_setupCrashHandlers {
  NSLog(@"Crash handler setup started.");

  struct sigaction signalActionHandler;
  memset(&signalActionHandler, 0, sizeof(signalActionHandler));
  int result = sigemptyset(&signalActionHandler.sa_mask);
  if (result != 0) {
    NSLog(@"Unable to empty sa_mask. Return value:%d", result);
    exit(-1);
  }
  signalActionHandler.sa_handler = &grey_signalHandler;

  // Register the signal handlers.
  grey_installSignalHandler(SIGQUIT, &signalActionHandler);
  grey_installSignalHandler(SIGILL, &signalActionHandler);
  grey_installSignalHandler(SIGTRAP, &signalActionHandler);
  grey_installSignalHandler(SIGABRT, &signalActionHandler);
  grey_installSignalHandler(SIGFPE, &signalActionHandler);
  grey_installSignalHandler(SIGBUS, &signalActionHandler);
  grey_installSignalHandler(SIGSEGV, &signalActionHandler);
  grey_installSignalHandler(SIGSYS, &signalActionHandler);

  // Register the handler for uncaught exceptions.
  NSSetUncaughtExceptionHandler(&grey_uncaughtExceptionHandler);

  NSLog(@"Crash handlers setup complete.");
}

@end
