//
//  STEPBridge.mm
//  pipe-macos
//
//  Objective-C++ implementation for OpenCASCADE STEP parsing
//  This bridge allows Swift code to use OCCT's B-Rep functionality
//

#import "STEPBridge.h"

// OpenCASCADE headers
#include <STEPControl_Reader.hxx>
#include <STEPControl_ActorRead.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopExp_Explorer.hxx>
#include <BRep_Tool.hxx>
#include <BRepTools.hxx>
#include <Geom_Surface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_SphericalSurface.hxx>
#include <Geom_ToroidalSurface.hxx>
#include <Geom_Plane.hxx>
#include <Geom_Circle.hxx>
#include <Geom_BSplineCurve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <GProp_GProps.hxx>
#include <BRepGProp.hxx>
#include <TopoDS.hxx>
#include <TCollection_AsciiString.hxx>
#include <Message_ProgressRange.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <gp_Pln.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Cone.hxx>
#include <gp_Sphere.hxx>
#include <gp_Torus.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <Poly_Triangulation.hxx>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>

@implementation CylinderSurfaceData

- (instancetype)initWithRadius:(double)radius
                      locationX:(float)locationX
                      locationY:(float)locationY
                      locationZ:(float)locationZ
                           axisX:(float)axisX
                           axisY:(float)axisY
                           axisZ:(float)axisZ {
    self = [super init];
    if (self) {
        _radius = radius;
        _locationX = locationX;
        _locationY = locationY;
        _locationZ = locationZ;
        _axisX = axisX;
        _axisY = axisY;
        _axisZ = axisZ;
    }
    return self;
}

@end

@implementation PlaneSurfaceData

- (instancetype)initWithLocationX:(float)locationX
                        locationY:(float)locationY
                        locationZ:(float)locationZ
                          normalX:(float)normalX
                          normalY:(float)normalY
                          normalZ:(float)normalZ {
    self = [super init];
    if (self) {
        _locationX = locationX;
        _locationY = locationY;
        _locationZ = locationZ;
        _normalX = normalX;
        _normalY = normalY;
        _normalZ = normalZ;
    }
    return self;
}

@end

@implementation WireData

- (instancetype)initWithPoints:(NSArray<NSNumber *> *)points
                        isInner:(BOOL)isInner
                       edgeType:(int)edgeType {
    self = [super init];
    if (self) {
        _points = points;
        _isInner = isInner;
        _edgeType = edgeType;
    }
    return self;
}

@end

@implementation FaceData

- (instancetype)initWithSurfaceType:(int)surfaceType
                              wires:(NSArray<WireData *> *)wires
                               area:(double)area {
    self = [super init];
    if (self) {
        _surfaceType = surfaceType;
        _wires = wires;
        _area = area;
    }
    return self;
}

@end

@implementation SolidData

- (instancetype)initWithSolidId:(int)solidId
                          faces:(NSArray<FaceData *> *)faces
                           xMin:(double)xMin yMin:(double)yMin zMin:(double)zMin
                           xMax:(double)xMax yMax:(double)yMax zMax:(double)zMax {
    self = [super init];
    if (self) {
        _solidId = solidId;
        _faces = faces;
        _xMin = xMin;
        _yMin = yMin;
        _zMin = zMin;
        _xMax = xMax;
        _yMax = yMax;
        _zMax = zMax;
    }
    return self;
}

@end

@implementation STEPParseResult

- (instancetype)initWithSolids:(NSArray<SolidData *> *)solids {
    self = [super init];
    if (self) {
        _solids = solids;
    }
    return self;
}

+ (instancetype)resultWithError:(NSError *)error {
    STEPParseResult *result = [[STEPParseResult alloc] init];
    result.error = error;
    return result;
}

@end

@implementation STEPBridge

// Helper function to convert OCCT gp_Pnt to NSArray
static NSArray<NSNumber*>* pointToArray(const gp_Pnt& point) {
    return @[@(point.X()), @(point.Y()), @(point.Z())];
}

// Helper function to sample a wire into points
static NSArray<NSNumber*>* sampleWire(const TopoDS_Wire& wire, int numPoints = 36) {
    NSMutableArray<NSNumber*> *points = [NSMutableArray array];
    
    TopLoc_Location location;
    Handle(Geom_Curve) curve;
    double first, last;
    
    // Get the first edge from the wire
    TopExp_Explorer edgeExp(wire, TopAbs_EDGE);
    if (edgeExp.More()) {
        TopoDS_Edge edge = TopoDS::Edge(edgeExp.Current());
        curve = BRep_Tool::Curve(edge, location, first, last);
        
        if (!curve.IsNull()) {
            // Sample the curve
            double step = (last - first) / numPoints;
            for (int i = 0; i <= numPoints; i++) {
                double param = first + i * step;
                gp_Pnt point;
                curve->D0(param, point);
                [points addObject:@(point.X())];
                [points addObject:@(point.Y())];
                [points addObject:@(point.Z())];
            }
        }
    }
    
    return points;
}

// Helper to get edge type from wire
static int getWireEdgeType(const TopoDS_Wire& wire) {
    // 0=Line, 1=Circle, 2=BSpline
    TopExp_Explorer edgeExp(wire, TopAbs_EDGE);
    if (edgeExp.More()) {
        TopoDS_Edge edge = TopoDS::Edge(edgeExp.Current());
        TopLoc_Location location;
        double first, last;
        Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, location, first, last);
        
        if (!curve.IsNull()) {
            if (curve->IsKind(STANDARD_TYPE(Geom_Circle))) {
                return 1;  // Circle
            } else if (curve->IsKind(STANDARD_TYPE(Geom_BSplineCurve))) {
                return 2;  // BSpline
            }
        }
    }
    return 0;  // Line (default)
}

// Helper to calculate face area
static double calculateFaceArea(const TopoDS_Face& face) {
    GProp_GProps props;
    BRepGProp::SurfaceProperties(face, props);
    return props.Mass();  // Mass = area for surface properties
}

+ (nullable STEPParseResult *)parseSTEPFile:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    @try {
        if (!url) {
            if (error) {
                *error = [NSError errorWithDomain:@"STEPBridge"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Nil URL provided"}];
            }
            return nil;
        }
        
        // Convert NSURL to OCCT file path
        NSString *filePath = [url path];
        
        NSLog(@"[STEPBridge] Reading STEP file: %@", filePath);
        
        // Verify file exists
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSLog(@"[STEPBridge] ERROR: File does not exist at path");
            if (error) {
                *error = [NSError errorWithDomain:@"STEPBridge"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"File not found"}];
            }
            return nil;
        }
        
        TCollection_AsciiString stepPath([filePath UTF8String]);
        
        NSLog(@"[STEPBridge] Creating STEP reader...");
        
        // Create STEP reader
        STEPControl_Reader reader;
        
        NSLog(@"[STEPBridge] Reading STEP file...");
        
        // Read the STEP file
        IFSelect_ReturnStatus status = reader.ReadFile(stepPath.ToCString());

        if (status != IFSelect_RetDone) {
            NSLog(@"[STEPBridge] ERROR: Failed to read STEP file, status=%d", (int)status);
            if (error) {
                *error = [NSError errorWithDomain:@"STEPBridge"
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to read STEP file (status=%d)", (int)status]}];
                return [STEPParseResult resultWithError:*error];
            }
            return nil;
        }

        NSLog(@"[STEPBridge] ✅ File read successfully");
        
        // Transfer roots to shapes
        Standard_Integer nbRoots = reader.NbRootsForTransfer();
        
        NSLog(@"[STEPBridge] Found %d root(s) for transfer", (int)nbRoots);
        
        if (nbRoots <= 0) {
            NSLog(@"[STEPBridge] ERROR: No roots found");
            if (error) {
                *error = [NSError errorWithDomain:@"STEPBridge"
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"No roots found in STEP file"}];
                return [STEPParseResult resultWithError:*error];
            }
            return nil;
        }
        
        NSLog(@"[STEPBridge] Transferring roots...");
        
        // Transfer all roots
        reader.TransferRoots();
        
        Standard_Integer nbShapes = reader.NbShapes();
        
        NSLog(@"[STEPBridge] Transferred %d shape(s)", (int)nbShapes);
        
        if (nbShapes == 0) {
            NSLog(@"[STEPBridge] ERROR: No shapes transferred");
            if (error) {
                *error = [NSError errorWithDomain:@"STEPBridge"
                                             code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"No shapes transferred from STEP file"}];
                return [STEPParseResult resultWithError:*error];
            }
            return nil;
        }
    
    NSMutableArray<SolidData*> *solids = [NSMutableArray array];
    int solidId = 0;
    
    NSLog(@"[STEPBridge] Extracting solids from shapes...");
    
    // Iterate through all shapes
    for (Standard_Integer i = 1; i <= nbShapes; i++) {
        TopoDS_Shape shape = reader.Shape(i);
        
        BRepMesh_IncrementalMesh mesher(shape, 0.1);
        
        NSLog(@"[STEPBridge] Shape %d type: %d", (int)i, (int)shape.ShapeType());
        
        // Extract solids from the shape (may be compound)
        TopExp_Explorer solidExp(shape, TopAbs_SOLID);
        
        int solidCount = 0;
        while (solidExp.More()) {
            solidCount++;
            TopoDS_Solid solid = TopoDS::Solid(solidExp.Current());
            
            // Calculate Bounding Box
            Bnd_Box boundingBox;
            BRepBndLib::Add(solid, boundingBox);
            Standard_Real xMin, yMin, zMin, xMax, yMax, zMax;
            boundingBox.Get(xMin, yMin, zMin, xMax, yMax, zMax);
            NSMutableArray<FaceData*> *faces = [NSMutableArray array];
            
            // Iterate through faces of the solid
            TopExp_Explorer faceExp(solid, TopAbs_FACE);
            while (faceExp.More()) {
                TopoDS_Face face = TopoDS::Face(faceExp.Current());
                
                // Get surface type
                TopLoc_Location location;
                Handle(Geom_Surface) surface = BRep_Tool::Surface(face, location);
                
                int surfaceType = 0;  // 0=Plane, 1=Cylinder, 2=Cone, 3=Sphere, 4=Torus, 5=BSpline
                CylinderSurfaceData *cylinderData = nil;
                PlaneSurfaceData *planeData = nil;
                
                if (!surface.IsNull()) {
                    if (surface->IsKind(STANDARD_TYPE(Geom_Plane))) {
                        surfaceType = 0;
                        Handle(Geom_Plane) plane = Handle(Geom_Plane)::DownCast(surface);
                        if (!plane.IsNull()) {
                            gp_Pln pln = plane->Pln();
                            gp_Pnt pLocation = pln.Location();
                            gp_Dir normal = pln.Position().Direction();
                            
                            planeData = [[PlaneSurfaceData alloc] 
                                initWithLocationX:pLocation.X()
                                locationY:pLocation.Y()
                                locationZ:pLocation.Z()
                                  normalX:normal.X()
                                  normalY:normal.Y()
                                  normalZ:normal.Z()];
                        }
                    } else if (surface->IsKind(STANDARD_TYPE(Geom_CylindricalSurface))) {
                        surfaceType = 1;
                        Handle(Geom_CylindricalSurface) cylinder = Handle(Geom_CylindricalSurface)::DownCast(surface);
                        if (!cylinder.IsNull()) {
                            gp_Cylinder cyl = cylinder->Cylinder();
                            double radius = cyl.Radius();
                            gp_Ax3 position = cyl.Position();
                            gp_Pnt pLocation = position.Location();
                            gp_Dir direction = position.Direction();

                            cylinderData = [[CylinderSurfaceData alloc]
                                initWithRadius:radius
                                locationX:pLocation.X()
                                locationY:pLocation.Y()
                                locationZ:pLocation.Z()
                                     axisX:direction.X()
                                     axisY:direction.Y()
                                     axisZ:direction.Z()];
                        }
                    } else if (surface->IsKind(STANDARD_TYPE(Geom_ConicalSurface))) {
                        surfaceType = 2;
                    } else if (surface->IsKind(STANDARD_TYPE(Geom_SphericalSurface))) {
                        surfaceType = 3;
                    } else if (surface->IsKind(STANDARD_TYPE(Geom_ToroidalSurface))) {
                        surfaceType = 4;
                    } else {
                        surfaceType = 5;  // Free-form (BSpline)
                    }
                }
                
                // Get wires from face
                NSMutableArray<WireData*> *wires = [NSMutableArray array];
                bool isFirstWire = true;
                
                TopExp_Explorer wireExp(face, TopAbs_WIRE);
                while (wireExp.More()) {
                    TopoDS_Wire wire = TopoDS::Wire(wireExp.Current());
                    
                    // Sample wire points
                    NSArray<NSNumber*> *points = sampleWire(wire, 36);
                    int edgeType = getWireEdgeType(wire);
                    
                    // First wire is outer boundary, rest are inner (cutouts)
                    bool isInner = !isFirstWire;
                    isFirstWire = false;
                    
                    WireData *wireData = [[WireData alloc] initWithPoints:points
                                                                   isInner:isInner
                                                                  edgeType:edgeType];
                    [wires addObject:wireData];
                    
                    wireExp.Next();
                }
                
                // Calculate face area
                double area = calculateFaceArea(face);
                
                NSMutableArray<NSNumber*> *meshVerts = [NSMutableArray array];
                NSMutableArray<NSNumber*> *meshIndices = [NSMutableArray array];
                NSMutableArray<NSNumber*> *meshNormals = [NSMutableArray array];
                
                TopLoc_Location loc;
                Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
                
                if (!tri.IsNull()) {
                    const gp_Trsf& trsf = loc.Transformation();
                    
                    // 1. Extract Vertices
                    for (int n = 1; n <= tri->NbNodes(); n++) {
                        gp_Pnt p = tri->Node(n);
                        p.Transform(trsf);
                        [meshVerts addObject:@(p.X())];
                        [meshVerts addObject:@(p.Y())];
                        [meshVerts addObject:@(p.Z())];
                    }
                    
                    // 2. Extract Indices (OCCT is 1-based, we convert to 0-based for Swift)
                    for (int t = 1; t <= tri->NbTriangles(); t++) {
                        Poly_Triangle triangle = tri->Triangle(t);
                        Standard_Integer n1, n2, n3;
                        triangle.Get(n1, n2, n3);
                        
                        // Handle face orientation properly
                        if (face.Orientation() == TopAbs_REVERSED) {
                            [meshIndices addObject:@(n1 - 1)];
                            [meshIndices addObject:@(n3 - 1)];
                            [meshIndices addObject:@(n2 - 1)];
                        } else {
                            [meshIndices addObject:@(n1 - 1)];
                            [meshIndices addObject:@(n2 - 1)];
                            [meshIndices addObject:@(n3 - 1)];
                        }
                    }
                    
                    // 3. Extract Normals (Available in OCCT 7.6+)
                    if (tri->HasNormals()) {
                        for (int n = 1; n <= tri->NbNodes(); n++) {
                            gp_Dir dir = tri->Normal(n);
                            if (face.Orientation() == TopAbs_REVERSED) { dir.Reverse(); }
                            gp_Vec v(dir);
                            v.Transform(trsf); // Rotate normal according to location
                            [meshNormals addObject:@(v.X())];
                            [meshNormals addObject:@(v.Y())];
                            [meshNormals addObject:@(v.Z())];
                        }
                    }
                }
                
                FaceData *faceData = [[FaceData alloc] initWithSurfaceType:surfaceType
                                                                     wires:wires
                                                                      area:area];
                faceData.cylinderData = cylinderData;
                faceData.planeData = planeData;
                
                // ATTACH MESH DATA TO FACEDATA
                faceData.vertices = meshVerts;
                faceData.indices = meshIndices;
                faceData.normals = meshNormals;
                
                [faces addObject:faceData];
                
                faceExp.Next();
            }
            
            NSLog(@"[STEPBridge]   Solid %d has %lu face(s)", solidId, (unsigned long)faces.count);
            
            SolidData *solidData = [[SolidData alloc] initWithSolidId:solidId
                                                    faces:faces
                                                     xMin:xMin yMin:yMin zMin:zMin
                                                     xMax:xMax yMax:yMax zMax:zMax];
            [solids addObject:solidData];
            solidId++;
            
            solidExp.Next();
        }
        
        if (solidCount == 0) {
            NSLog(@"[STEPBridge]   Shape %d contains no solids", (int)i);
        }
    }
    
    NSLog(@"[STEPBridge] Extracted %lu solid(s) total", (unsigned long)solids.count);
    
    if (solids.count == 0) {
        NSLog(@"[STEPBridge] ERROR: No solid bodies found");
        if (error) {
            *error = [NSError errorWithDomain:@"STEPBridge"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"No solid bodies found in STEP file"}];
        }
        return [STEPParseResult resultWithError:*error];
    }

    NSLog(@"[STEPBridge] ✅ Parse complete, returning result");
    
    return [[STEPParseResult alloc] initWithSolids:solids];
    
    } @catch (NSException *exception) {
        NSLog(@"[STEPBridge] EXCEPTION: %@", exception.reason);
        if (error) {
            *error = [NSError errorWithDomain:@"STEPBridge"
                                         code:999
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"C++ exception: %@", exception.reason]}];
        }
        return nil;
    }
}

@end
