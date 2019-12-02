/**
 * Copyright (c) 2016-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/Foundation.h>

@class FBSingleObjectAllocation;

@interface FBSingleObjectAllocation : NSObject

@property (weak, nonatomic, readonly, nullable) id object;
@property (nonatomic, readonly, nullable) NSArray<NSNumber *> *callStackAddresses;

- (nonnull instancetype)initWithObject:(nullable id)object
                    callStackAddresses:(nullable NSArray<NSNumber *> *)callStackAddresses;

@end

@interface FBAllocationTrackerSummary : NSObject

@property (nonatomic, readonly) NSUInteger allocations;
@property (nonatomic, readonly, nonnull) NSArray<NSValue *> *deallocations;
@property (nonatomic, readonly) NSInteger aliveObjects;
@property (nonatomic, copy, readonly, nonnull) NSString *className;
@property (nonatomic, readonly) NSUInteger instanceSize;
@property (nonatomic, readonly, nonnull) NSArray<FBSingleObjectAllocation *> *allocatedObjectsInfo;

- (nonnull instancetype)initWithAllocations:(NSUInteger)allocations
                              deallocations:(nonnull NSArray<NSValue *> *)deallocations
                               aliveObjects:(NSInteger)aliveObjects
                                  className:(nonnull NSString *)className
                               instanceSize:(NSUInteger)instanceSize
                       allocatedObjectsInfo:(nonnull NSArray<FBSingleObjectAllocation *> *)allocatedObjectsInfo;

@end
