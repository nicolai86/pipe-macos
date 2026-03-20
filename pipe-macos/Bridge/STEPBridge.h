//
//  STEPBridge.h
//  pipe-macos
//
//  C++ Bridge header for OpenCASCADE STEP parsing
//  This file defines the Objective-C interface for Swift interoperability
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Cylinder surface parameters extracted from OCCT Geom_Cylinder
@interface CylinderSurfaceData : NSObject

@property (nonatomic, assign) double radius;
@property (nonatomic, assign) float locationX;
@property (nonatomic, assign) float locationY;
@property (nonatomic, assign) float locationZ;
@property (nonatomic, assign) float axisX;
@property (nonatomic, assign) float axisY;
@property (nonatomic, assign) float axisZ;

- (instancetype)initWithRadius:(double)radius
                      locationX:(float)locationX
                      locationY:(float)locationY
                      locationZ:(float)locationZ
                           axisX:(float)axisX
                           axisY:(float)axisY
                           axisZ:(float)axisZ;

@end

/// Plane surface parameters extracted from OCCT Geom_Plane
@interface PlaneSurfaceData : NSObject

@property (nonatomic, assign) float locationX;
@property (nonatomic, assign) float locationY;
@property (nonatomic, assign) float locationZ;
@property (nonatomic, assign) float normalX;
@property (nonatomic, assign) float normalY;
@property (nonatomic, assign) float normalZ;

- (instancetype)initWithLocationX:(float)locationX
                        locationY:(float)locationY
                        locationZ:(float)locationZ
                          normalX:(float)normalX
                          normalY:(float)normalY
                          normalZ:(float)normalZ;

@end

/// Wire boundary data from B-Rep face
@interface WireData : NSObject

@property (nonatomic, strong) NSArray<NSNumber *> *points;  // Flattened [x1,y1,z1,x2,y2,z2,...]
@property (nonatomic, assign) BOOL isInner;  // Inner wire (cutout) vs outer wire (boundary)
@property (nonatomic, assign) int edgeType;  // 0=Line, 1=Circle, 2=BSpline

- (instancetype)initWithPoints:(NSArray<NSNumber *> *)points
                        isInner:(BOOL)isInner
                       edgeType:(int)edgeType;

@end

/// Face data from B-Rep solid
@interface FaceData : NSObject

@property (nonatomic, assign) int surfaceType;  // 0=Plane, 1=Cylinder, 2=Cone, 3=Sphere, 4=Torus, 5=BSpline
@property (nonatomic, strong, nullable) CylinderSurfaceData *cylinderData;
@property (nonatomic, strong, nullable) PlaneSurfaceData *planeData;
@property (nonatomic, strong) NSArray<WireData *> *wires;
@property (nonatomic, assign) double area;

@property (nonatomic, strong, nullable) NSArray<NSNumber *> *vertices;
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *indices;
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *normals;

- (instancetype)initWithSurfaceType:(int)surfaceType
                              wires:(NSArray<WireData *> *)wires
                               area:(double)area;

@end

/// Solid body data from STEP assembly
@interface SolidData : NSObject

@property (nonatomic, assign) int solidId;
@property (nonatomic, strong) NSArray<FaceData *> *faces;

@property (nonatomic, assign) double xMin;
@property (nonatomic, assign) double yMin;
@property (nonatomic, assign) double zMin;
@property (nonatomic, assign) double xMax;
@property (nonatomic, assign) double yMax;
@property (nonatomic, assign) double zMax;

- (instancetype)initWithSolidId:(int)solidId
                          faces:(NSArray<FaceData *> *)faces
                           xMin:(double)xMin yMin:(double)yMin zMin:(double)zMin
                           xMax:(double)xMax yMax:(double)yMax zMax:(double)zMax;

@end

/// Result of STEP file parsing
@interface STEPParseResult : NSObject

@property (nonatomic, strong) NSArray<SolidData *> *solids;
@property (nonatomic, strong, nullable) NSError *error;

- (instancetype)initWithSolids:(NSArray<SolidData *> *)solids;
+ (instancetype)resultWithError:(NSError *)error;

@end

/// Main STEP Bridge class - interfaces with OpenCASCADE
@interface STEPBridge : NSObject

/// Parse STEP file and return B-Rep data
/// @param url File URL of the STEP file
/// @param error Error pointer
/// @return Parse result with solids and faces
+ (nullable STEPParseResult *)parseSTEPFile:(NSURL *)url 
                                      error:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
