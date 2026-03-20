//
//  STEPBridgeWrapper.m
//  pipe-macos
//
//  Pure Objective-C wrapper for Swift interoperability
//

#import "STEPBridgeWrapper.h"
#import "STEPBridge.h"

@implementation STEPBridgeWrapper

+ (nullable NSString *)parseSTEPToJSON:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    STEPParseResult *result = [STEPBridge parseSTEPFile:url error:error];
    if (!result) return nil;
    
    NSMutableArray *solidsJSON = [NSMutableArray array];
    
    for (SolidData *solid in result.solids) {
        NSMutableDictionary *solidDict = [NSMutableDictionary dictionary];
        solidDict[@"solidId"] = @(solid.solidId);
        solidDict[@"boundingBox"] = @{ @"xMin": @(solid.xMin), @"yMin": @(solid.yMin), @"zMin": @(solid.zMin), @"xMax": @(solid.xMax), @"yMax": @(solid.yMax), @"zMax": @(solid.zMax) };
        
        // --- ADD PCA EXPORT TO JSON ---
        solidDict[@"pca"] = @{
            @"centerX": @(solid.pcaCenterX), @"centerY": @(solid.pcaCenterY), @"centerZ": @(solid.pcaCenterZ),
            @"axis1X": @(solid.pcaAxis1X), @"axis1Y": @(solid.pcaAxis1Y), @"axis1Z": @(solid.pcaAxis1Z),
            @"axis2X": @(solid.pcaAxis2X), @"axis2Y": @(solid.pcaAxis2Y), @"axis2Z": @(solid.pcaAxis2Z),
            @"axis3X": @(solid.pcaAxis3X), @"axis3Y": @(solid.pcaAxis3Y), @"axis3Z": @(solid.pcaAxis3Z)
        };
        
        NSMutableArray *facesJSON = [NSMutableArray array];
        for (FaceData *face in solid.faces) {
            NSMutableDictionary *faceDict = [NSMutableDictionary dictionary];
            faceDict[@"faceID"] = @(face.faceID);
            faceDict[@"surface_type"] = [self surfaceTypeToString:face.surfaceType];
            
            if (face.cylinderData) {
                faceDict[@"cylinder"] = @{ @"radius": @(face.cylinderData.radius), @"locationX": @(face.cylinderData.locationX), @"locationY": @(face.cylinderData.locationY), @"locationZ": @(face.cylinderData.locationZ), @"axisX": @(face.cylinderData.axisX), @"axisY": @(face.cylinderData.axisY), @"axisZ": @(face.cylinderData.axisZ) };
            }
            if (face.planeData) {
                faceDict[@"plane"] = @{
                    @"normalX": @(face.planeData.normalX), @"normalY": @(face.planeData.normalY), @"normalZ": @(face.planeData.normalZ),
                    @"locationX": @(face.planeData.locationX), @"locationY": @(face.planeData.locationY), @"locationZ": @(face.planeData.locationZ)
                };
            }
            
            NSMutableArray *wiresJSON = [NSMutableArray array];
            for (WireData *wire in face.wires) {
                NSMutableArray *edgesJSON = [NSMutableArray array];
                for (EdgeData *edge in wire.edges) {
                    [edgesJSON addObject:@{
                        @"edgeID": @(edge.edgeID), @"curveType": @(edge.curveType),
                        @"adjacentFaceIDs": edge.adjacentFaceIDs, @"points": edge.points
                    }];
                }
                [wiresJSON addObject:@{ @"wireID": @(wire.wireID), @"isInner": @(wire.isInner), @"edges": edgesJSON }];
            }
            faceDict[@"wires"] = wiresJSON;
            
            if (face.vertices.count > 0) faceDict[@"vertices"] = face.vertices;
            if (face.indices.count > 0) faceDict[@"indices"] = face.indices;
            if (face.normals.count > 0) faceDict[@"normals"] = face.normals;
            
            [facesJSON addObject:faceDict];
        }
        solidDict[@"faces"] = facesJSON;
        [solidsJSON addObject:solidDict];
    }
    
    NSDictionary *resultDict = @{@"solids": solidsJSON};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:error];
    return jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
}

+ (NSString *)surfaceTypeToString:(int)type {
    switch (type) {
        case 0: return @"PLANE"; case 1: return @"CYLINDER"; case 2: return @"CONE";
        case 3: return @"SPHERE"; case 4: return @"TORUS"; default: return @"UNKNOWN";
    }
}

@end
