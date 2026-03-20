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
    if (!result) {
        return nil;
    }
    
    NSMutableArray *solidsJSON = [NSMutableArray array];
    
    for (SolidData *solid in result.solids) {
        NSMutableDictionary *solidDict = [NSMutableDictionary dictionary];
        solidDict[@"solidId"] = @(solid.solidId);
        
        solidDict[@"boundingBox"] = @{
            @"xMin": @(solid.xMin), @"yMin": @(solid.yMin), @"zMin": @(solid.zMin),
            @"xMax": @(solid.xMax), @"yMax": @(solid.yMax), @"zMax": @(solid.zMax)
        };
        
        NSMutableArray *facesJSON = [NSMutableArray array];
        for (FaceData *face in solid.faces) {
            NSMutableDictionary *faceDict = [NSMutableDictionary dictionary];
            faceDict[@"surface_type"] = [self surfaceTypeToString:face.surfaceType];
            faceDict[@"area"] = @(face.area);
            
            if (face.cylinderData) {
                faceDict[@"cylinder"] = @{
                    @"radius": @(face.cylinderData.radius),
                    @"location": @[
                        @(face.cylinderData.locationX),
                        @(face.cylinderData.locationY),
                        @(face.cylinderData.locationZ)
                    ],
                    @"axis": @[
                        @(face.cylinderData.axisX),
                        @(face.cylinderData.axisY),
                        @(face.cylinderData.axisZ)
                    ]
                };
            }
            
            if (face.wires) {
                NSMutableArray *wiresJSON = [NSMutableArray array];
                for (WireData *wire in face.wires) {
                    [wiresJSON addObject:@{
                        @"points": wire.points,
                        @"isInner": @(wire.isInner),
                        @"edgeType": @(wire.edgeType)
                    }];
                }
                faceDict[@"wires"] = wiresJSON;
            }
            
            if (face.vertices && face.vertices.count > 0) {
                faceDict[@"vertices"] = face.vertices;
                faceDict[@"indices"] = face.indices;
                if (face.normals && face.normals.count > 0) {
                    faceDict[@"normals"] = face.normals;
                }
            }
            
            [facesJSON addObject:faceDict];
        }
        
        solidDict[@"faces"] = facesJSON;
        [solidsJSON addObject:solidDict];
    }
    
    NSDictionary *resultDict = @{@"solids": solidsJSON};
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:&jsonError];
    
    if (jsonError) {
        if (error) {
            *error = jsonError;
        }
        return nil;
    }
    
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (NSString *)surfaceTypeToString:(int)type {
    switch (type) {
        case 0: return @"PLANE";
        case 1: return @"CYLINDER";
        case 2: return @"CONE";
        case 3: return @"SPHERE";
        case 4: return @"TORUS";
        default: return @"BSPLINE";
    }
}

@end
