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

@interface EdgeData : NSObject
@property (nonatomic, assign) int edgeID;
@property (nonatomic, assign) int curveType; // 0=Line, 1=Circle, 2=Other
@property (nonatomic, strong) NSArray<NSNumber *> *adjacentFaceIDs;
@property (nonatomic, strong) NSArray<NSDictionary *> *points; // {x, y, z}
- (instancetype)initWithEdgeID:(int)edgeID curveType:(int)curveType adjacentFaces:(NSArray<NSNumber *> *)adjFaces points:(NSArray<NSDictionary *> *)points;
@end

/// Wire boundary data from B-Rep face
@interface WireData : NSObject
@property (nonatomic, assign) int wireID;
@property (nonatomic, assign) BOOL isInner;
@property (nonatomic, strong) NSArray<EdgeData *> *edges;
- (instancetype)initWithWireID:(int)wireID isInner:(BOOL)isInner edges:(NSArray<EdgeData *> *)edges;
@end

/// Face data from B-Rep solid
@interface FaceData : NSObject
@property (nonatomic, assign) int faceID;
@property (nonatomic, assign) int surfaceType;
@property (nonatomic, strong, nullable) CylinderSurfaceData *cylinderData;
@property (nonatomic, strong, nullable) PlaneSurfaceData *planeData;
@property (nonatomic, strong) NSArray<WireData *> *wires;
@property (nonatomic, strong) NSArray<NSDictionary *> *vertices; // For mesh visualization
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *indices;
@property (nonatomic, strong) NSArray<NSDictionary *> *normals;
@property (nonatomic, assign) double area;
- (instancetype)initWithFaceID:(int)faceID type:(int)type cyl:(nullable CylinderSurfaceData *)cyl plane:(nullable PlaneSurfaceData *)plane wires:(NSArray<WireData *> *)wires verts:(NSArray *)verts idxs:(NSArray *)idxs norms:(NSArray *)norms area:(double)area;
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
