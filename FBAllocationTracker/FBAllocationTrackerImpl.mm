/**
 * Copyright (c) 2016-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBAllocationTrackerImpl.h"

#import <objc/runtime.h>
#import <unordered_map>
#import <unordered_set>
#import <vector>

#import "FBAllocationTrackerDefines.h"
#import "FBAllocationTrackerHelpers.h"
#import "FBAllocationTrackerSummary.h"
#import "NSObject+FBAllocationTracker.h"

#if _INTERNAL_FBAT_ENABLED

typedef NS_ENUM(NSUInteger, FBMethodType) {
  FBInstanceMethod,
  FBClassMethod,
};

namespace {
  // Private
  using TrackerMap =
  std::unordered_map<
  __unsafe_unretained Class,
  NSMutableArray<NSObject *> *, // \c FBSingleObjectAllocation or \c NSValue
  FB::AllocationTracker::ClassHashFunctor,
  FB::AllocationTracker::ClassEqualFunctor>;

  // Pointers to avoid static deallocation fiasco
  static auto *_allocations = new TrackerMap();
  static auto *_deallocations = new TrackerMap();
  static bool _trackingInProgress = false;
  static auto *_lock = (new std::mutex);

  // Private interface
  static bool _didCopyOriginalMethods = false;

  static FB::AllocationTracker::GenerationManager *_generationManager = nil;

  void replaceSelectorWithSelector(Class aCls,
                                   SEL selector,
                                   SEL replacementSelector,
                                   FBMethodType methodType) {

    Method replacementSelectorMethod = (methodType == FBClassMethod
                                        ? class_getClassMethod(aCls, replacementSelector)
                                        : class_getInstanceMethod(aCls, replacementSelector));

    Class classEntityToEdit = aCls;
    if (methodType == FBClassMethod) {
      // Get meta-class
      classEntityToEdit = object_getClass(aCls);
    }
    class_replaceMethod(classEntityToEdit,
                        selector,
                        method_getImplementation(replacementSelectorMethod),
                        method_getTypeEncoding(replacementSelectorMethod));
  }

  void prepareOriginalMethods(void) {
    if (_didCopyOriginalMethods) {
      return;
    }

    // prepareOriginalMethods called from turnOn/Off which is synced by
    // _lock, this is thread-safe
    _didCopyOriginalMethods = true;

    replaceSelectorWithSelector([NSObject class],
                                @selector(fb_originalAllocWithZone:),
                                @selector(allocWithZone:),
                                FBClassMethod);

    replaceSelectorWithSelector([NSObject class],
                                @selector(fb_originalDealloc),
                                sel_registerName("dealloc"),
                                FBInstanceMethod);
  }

  void turnOnTracking(void) {
    prepareOriginalMethods();

    replaceSelectorWithSelector([NSObject class],
                                @selector(allocWithZone:),
                                @selector(fb_newAllocWithZone:),
                                FBClassMethod);

    replaceSelectorWithSelector([NSObject class],
                                sel_registerName("dealloc"),
                                @selector(fb_newDealloc),
                                FBInstanceMethod);
  }

  void turnOffTracking(void) {
    prepareOriginalMethods();

    replaceSelectorWithSelector([NSObject class],
                                @selector(allocWithZone:),
                                @selector(fb_originalAllocWithZone:),
                                FBClassMethod);

    replaceSelectorWithSelector([NSObject class],
                                sel_registerName("dealloc"),
                                @selector(fb_originalDealloc),
                                FBInstanceMethod);
  }
}

namespace FB { namespace AllocationTracker {

  void beginTracking() {
    std::lock_guard<std::mutex> l(*_lock);

    if (_trackingInProgress) {
      return;
    }

    _trackingInProgress = true;

    turnOnTracking();
  }

  void endTracking() {
    std::lock_guard<std::mutex> l(*_lock);

    if (!_trackingInProgress) {
      return;
    }

    _trackingInProgress = false;

    _allocations->clear();
    _deallocations->clear();

    turnOffTracking();
  }

  bool isTracking() {
    std::lock_guard<std::mutex> l(*_lock);
    bool isTracking = _trackingInProgress;
    return isTracking;
  }

  static bool _shouldTrackClass(Class aCls) {
    if (aCls == Nil || aCls == NSException.class ||
        aCls == NSClassFromString(@"_NSCallStackArray")) {
      return false;
    }

    static NSArray<Class> *blacklistedClasses = @[
      // We want to omit some classes for performance reasons
      (Class _Nonnull)NSClassFromString(@"NSTaggedPointerStringCStringContainer"),
      // Tracking allocations for the following classes would cause an infinite loop or a deadlock
      // because of the objects created to in \c incrementAllocations.
      (Class _Nonnull)NSClassFromString(@"__NSSingleEntryDictionaryI"),
      (Class _Nonnull)NSClassFromString(@"__NSArrayM"),
      (Class _Nonnull)NSClassFromString(@"__NSArrayI"),
      (Class _Nonnull)NSClassFromString(@"NSConcreteValue"),
      (Class _Nonnull)NSClassFromString(@"NSAutoreleasePool"),
      (Class _Nonnull)NSClassFromString(@"NSATSGlyphStorage"), // Cannot form weak ref upon allocation
      (Class _Nonnull)NSClassFromString(@"_CTNativeGlyphStorage"), // Cannot form weak ref upon allocation
#if TARGET_OS_SIMULATOR
      (Class _Nonnull)NSClassFromString(@"FigFCRCALayerOutputNodeLayer"), // Cannot form weak ref upon allocation
#endif
      (Class _Nonnull)NSClassFromString(@"SVGLayer"), // Cannot form weak ref upon allocation
      (Class _Nonnull)NSClassFromString(@"CAShapeLayer"), // Cannot form weak ref upon allocation
      FBSingleObjectAllocation.class
    ];

    if ([blacklistedClasses containsObject:aCls]) {
      return false;
    }

    return true;
  }

  void incrementAllocations(__unsafe_unretained id obj) {
    Class aCls = [obj class];

    if (!_shouldTrackClass(aCls)) {
      return;
    }

    auto addresses = [NSThread callStackReturnAddresses];

    std::lock_guard<std::mutex> l(*_lock);

    if (_trackingInProgress) {
      if ((*_allocations).find(aCls) == (*_allocations).end()) {
        (*_allocations)[aCls] = [NSMutableArray array];
      }
      auto singleObjectAllocation = [[FBSingleObjectAllocation alloc] initWithObject:obj
                                                                  callStackAddresses:addresses];
      [(*_allocations)[aCls] addObject:singleObjectAllocation];
    }

    if (_generationManager) {
      _generationManager->addObject(obj);
    }
  }

  void incrementDeallocations(__unsafe_unretained id obj) {
    Class aCls = [obj class];

    if (!_shouldTrackClass(aCls)) {
      return;
    }

    std::lock_guard<std::mutex> l(*_lock);

    if (_trackingInProgress) {
      if ((*_deallocations).find(aCls) == (*_deallocations).end()) {
        (*_deallocations)[aCls] = [NSMutableArray array];
      }
      [(*_deallocations)[aCls] addObject:[NSValue valueWithNonretainedObject:obj]];
    }

    if (_generationManager) {
      _generationManager->removeObject(obj);
    }
  }

  AllocationSummary allocationTrackerSummary() {
    TrackerMap allocationsUntilNow = {};
    TrackerMap deallocationsUntilNow = {};

    {
      std::lock_guard<std::mutex> l(*_lock);

      for (auto pair : *_allocations) {
        allocationsUntilNow[pair.first] = [pair.second mutableCopy];
      }
      for (auto pair : *_deallocations) {
        deallocationsUntilNow[pair.first] = [pair.second mutableCopy];
      }
    }

    std::unordered_set<
    __unsafe_unretained Class,
    FB::AllocationTracker::ClassHashFunctor,
    FB::AllocationTracker::ClassEqualFunctor> keys;

    for (const auto &kv: allocationsUntilNow) {
      keys.insert(kv.first);
    }

    for (const auto &kv: deallocationsUntilNow) {
      keys.insert(kv.first);
    }

    AllocationSummary summary;

    for (Class aCls: keys) {
      // Non-zero instances are the only interesting ones
      if (allocationsUntilNow[aCls].count - deallocationsUntilNow[aCls].count <= 0) {
        continue;
      }

      NSMutableArray<NSValue *> *deallocations = [NSMutableArray new];
      for (NSValue *objectPointer in deallocationsUntilNow[aCls]) {
        [deallocations addObject:objectPointer];
      }

      SingleClassSummary singleSummary = {
        .allocatedObjectsInfo = (NSMutableArray<FBSingleObjectAllocation *> *)allocationsUntilNow[aCls],
        .deallocatedObjectsPointers = [deallocations copy],
        .instanceSize = class_getInstanceSize(aCls)
      };

      summary[aCls] = singleSummary;
    }

    return summary;
  }

  void enableGenerations() {
    std::lock_guard<std::mutex> l(*_lock);

    if (_generationManager) {
      return;
    }

    _generationManager = new GenerationManager();
  }

  void disableGenerations(void) {
    std::lock_guard<std::mutex> l(*_lock);

    delete _generationManager;
    _generationManager = nil;
  }

  void markGeneration(void) {
    std::lock_guard<std::mutex> l(*_lock);
    if (_generationManager) {
      _generationManager->markGeneration();
    }
  }

  FullGenerationSummary generationSummary() {
    std::lock_guard<std::mutex> l(*_lock);

    if (_generationManager) {
      return _generationManager->summary();
    }
    return FullGenerationSummary {};
  }

  static bool _shouldOmitClass(Class aCls) {
    // Trying to retain NSAutoreleasePool/NSCFTimer is going to end up with crash.
    NSString *className = NSStringFromClass(aCls);
    if ([className isEqualToString:@"NSAutoreleasePool"] ||
        [className isEqualToString:@"NSCFTimer"]) {
      return true;
    }

    return false;
  }

  std::vector<__weak id> instancesOfClassForGeneration(__unsafe_unretained Class aCls,
                                                NSInteger generationIndex) {
    if (_shouldOmitClass(aCls)) {
      return std::vector<__weak id> {};
    }

    std::lock_guard<std::mutex> l(*_lock);
    if (_generationManager) {
      return _generationManager->instancesOfClassInGeneration(aCls, generationIndex);
    }
    return std::vector<__weak id> {};
  }

  NSArray *instancesOfClasses(NSArray *classes) {
    if (!_generationManager) {
      return nil;
    }

    NSMutableArray *instances = [NSMutableArray new];

    for (Class aCls in classes) {
      if (_shouldOmitClass(aCls)) {
        continue;
      }

      std::vector<__weak id> instancesFromGeneration;

      {
        std::lock_guard<std::mutex> l(*_lock);
        instancesFromGeneration = _generationManager->instancesOfClassInLastGeneration(aCls);
      }

      for (const auto &obj: instancesFromGeneration) {
        id retainedObject = obj;
        if (retainedObject) {
          [instances addObject:retainedObject];
        }
      }
    }

    return instances;
  }

  std::vector<__unsafe_unretained Class> trackedClasses() {
    std::lock_guard<std::mutex> l(*_lock);
    std::vector<__unsafe_unretained Class> trackedClasses;

    // Some first approximation for number of classes
    trackedClasses.reserve(2048);

    if (!_trackingInProgress) {
      return trackedClasses;
    }

    for (const auto &mapValue: *_allocations) {
      trackedClasses.push_back(mapValue.first);
    }

    return trackedClasses;
  }
} }

#endif // _INTERNAL_FBAT_ENABLED
