/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBDeviceApplicationLaunchStrategy.h"

#import "FBAMDServiceConnection.h"
#import "FBDevice.h"
#import "FBDeviceApplicationProcess.h"
#import "FBDeviceControlError.h"
#import "FBGDBClient.h"

static NSTimeInterval LaunchTimeout = 60;

@interface FBDeviceApplicationLaunchStrategy ()

@property (nonatomic, strong, readonly) FBDevice *device;
@property (nonatomic, strong, readonly) FBAMDServiceConnection *connection;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;
@property (nonatomic, strong, readonly) dispatch_queue_t writeQueue;

@end

@implementation FBDeviceApplicationLaunchStrategy

#pragma mark Initializers

+ (instancetype)strategyWithDevice:(FBDevice *)device debugConnection:(FBAMDServiceConnection *)connection logger:(id<FBControlCoreLogger>)logger
{
  return [[self alloc] initWithDevice:device debugConnection:connection logger:logger];
}

- (instancetype)initWithDevice:(FBDevice *)device debugConnection:(FBAMDServiceConnection *)connection logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _device = device;
  _connection = connection;
  _logger = logger;
  _writeQueue = dispatch_queue_create("com.facebook.fbdevicecontrol.app_launch_commands", DISPATCH_QUEUE_SERIAL);

  return self;
}

#pragma mark Public Methods

- (FBFuture<FBDeviceApplicationProcess *> *)launchApplication:(FBApplicationLaunchConfiguration *)launch remoteAppPath:(NSString *)remoteAppPath
{
  return [[FBGDBClient
    clientForServiceConnection:self.connection queue:self.writeQueue logger:self.logger]
    onQueue:self.writeQueue fmap:^(FBGDBClient *client) {
      FBFuture<NSNumber *> *launchFuture = [FBDeviceApplicationLaunchStrategy
        launchApplication:launch
        remoteAppPath:remoteAppPath
        client:client
        queue:self.writeQueue
        logger:self.logger];
      return [FBDeviceApplicationLaunchStrategy launchApplication:launch device:self.device client:client launchFuture:launchFuture];
    }];
}

#pragma mark Private

+ (FBFuture<NSNumber *> *)launchApplication:(FBApplicationLaunchConfiguration *)launch remoteAppPath:(NSString *)remoteAppPath client:(FBGDBClient *)client queue:(dispatch_queue_t)queue logger:(id<FBControlCoreLogger>)logger
{
  [logger logFormat:@"Launching with remote path %@", remoteAppPath];
  return [[[[[[[client
    noAckMode]
    onQueue:queue fmap:^(id _) {
      NSMutableDictionary<NSString *, NSString *> *environment = [launch.environment mutableCopy];
      environment[@"NSUnbufferedIO"] = @"YES";
      return [client sendEnvironment:environment];
    }]
    onQueue:queue fmap:^(id _) {
      return [client sendArguments:[@[remoteAppPath] arrayByAddingObjectsFromArray:launch.arguments]];
    }]
    onQueue:queue fmap:^(id _) {
      return [client launchSuccess];
    }]
    onQueue:queue fmap:^(id _) {
      return [client processInfo];
    }]
    onQueue:queue doOnResolved:^(id _) {
      // App has launched, tell the debugger to continue so the app actually runs.
      [client sendContinue];
    }]
    timeout:LaunchTimeout waitingFor:@"Timed out waiting for launch to complete"];
}

+ (FBFuture<FBDeviceApplicationProcess *> *)launchApplication:(FBApplicationLaunchConfiguration *)appLaunch device:(FBDevice *)device client:(FBGDBClient *)client launchFuture:(FBFuture<NSNumber *> *)launchFuture
{
  return [[appLaunch.output
    createOutputForTarget:device]
    onQueue:device.workQueue fmap:^(NSArray<FBProcessOutput *> *outputs) {
      return [FBDeviceApplicationProcess processWithDevice:device configuration:appLaunch gdbClient:client stdOut:outputs[0] stdErr:outputs[1] launchFuture:launchFuture];
    }];
}

@end
