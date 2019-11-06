/**
 * Copyright (c) 2016-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBAllocationTrackerSummary.h"

@implementation FBSingleObjectAllocation : NSObject

- (nonnull instancetype)initWithObjectPointer:(nonnull NSValue *)objectPointer
                           callStackAddresses:(nullable NSArray<NSNumber *> *)callStackAddresses
{
  if ((self = [super init])) {
    _objectPointer = objectPointer;
    _callStackAddresses = callStackAddresses;
  }

  return self;
}

@end

@implementation FBAllocationTrackerSummary

- (nonnull instancetype)initWithAllocations:(NSUInteger)allocations
                              deallocations:(nonnull NSArray<NSNumber *> *)deallocations
                               aliveObjects:(NSInteger)aliveObjects
                                  className:(nonnull NSString *)className
                               instanceSize:(NSUInteger)instanceSize
                       allocatedObjectsInfo:(nonnull NSArray<FBSingleObjectAllocation *> *)allocatedObjectsInfo;
{
  if ((self = [super init])) {
    _allocations = allocations;
    _deallocations = deallocations;
    _aliveObjects = aliveObjects;
    _className = className;
    _instanceSize = instanceSize;
    _allocatedObjectsInfo = allocatedObjectsInfo;
  }

  return self;
}

-(NSString *)description
{
  return [NSString stringWithFormat:@"%@: allocations=%@ deallocations=%@ alive=%@ size=%@", _className, @(_allocations), @(_deallocations.count), @(_aliveObjects), @(_instanceSize)];
}

@end
