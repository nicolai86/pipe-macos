//
//  STEPBridgeWrapper.h
//  pipe-macos
//
//  Pure Objective-C wrapper for Swift interoperability
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift-accessible wrapper for STEP bridge
@interface STEPBridgeWrapper : NSObject

/// Parse STEP file and return JSON string
+ (nullable NSString *)parseSTEPToJSON:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
