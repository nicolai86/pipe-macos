//
//  STEPBridge.mm
//  pipe-macos
//

#import "STEPBridge.h"
#include <STEPControl_Reader.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Edge.hxx>
#include <TopExp_Explorer.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <BRep_Tool.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <GCPnts_UniformDeflection.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <Geom_Surface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_Plane.hxx>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <Poly_Triangulation.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>

@implementation CylinderSurfaceData
- (instancetype)initWithRadius:(double)radius locationX:(float)locationX locationY:(float)locationY locationZ:(float)locationZ axisX:(float)axisX axisY:(float)axisY axisZ:(float)axisZ {
    if (self = [super init]) {
        _radius = radius; _locationX = locationX; _locationY = locationY; _locationZ = locationZ;
        _axisX = axisX; _axisY = axisY; _axisZ = axisZ;
    }
    return self;
}
@end

@implementation PlaneSurfaceData
- (instancetype)initWithLocationX:(float)locationX locationY:(float)locationY locationZ:(float)locationZ normalX:(float)normalX normalY:(float)normalY normalZ:(float)normalZ {
    if (self = [super init]) {
        _locationX = locationX; _locationY = locationY; _locationZ = locationZ;
        _normalX = normalX; _normalY = normalY; _normalZ = normalZ;
    }
    return self;
}
@end

@implementation EdgeData
- (instancetype)initWithEdgeID:(int)edgeID curveType:(int)curveType adjacentFaces:(NSArray<NSNumber *> *)adjFaces points:(NSArray<NSDictionary *> *)points {
    if (self = [super init]) { _edgeID = edgeID; _curveType = curveType; _adjacentFaceIDs = adjFaces; _points = points; }
    return self;
}
@end

@implementation WireData
- (instancetype)initWithWireID:(int)wireID isInner:(BOOL)isInner edges:(NSArray<EdgeData *> *)edges {
    if (self = [super init]) { _wireID = wireID; _isInner = isInner; _edges = edges; }
    return self;
}
@end

@implementation FaceData
- (instancetype)initWithFaceID:(int)faceID type:(int)type cyl:(nullable CylinderSurfaceData *)cyl plane:(nullable PlaneSurfaceData *)plane wires:(NSArray<WireData *> *)wires verts:(NSArray *)verts idxs:(NSArray *)idxs norms:(NSArray *)norms area:(double)area {
    if (self = [super init]) {
        _faceID = faceID; _surfaceType = type; _cylinderData = cyl; _planeData = plane; _wires = wires; _vertices = verts; _indices = idxs; _normals = norms; _area = area;
    }
    return self;
}
@end

@implementation SolidData
- (instancetype)initWithSolidId:(int)solidId faces:(NSArray<FaceData *> *)faces xMin:(double)xMin yMin:(double)yMin zMin:(double)zMin xMax:(double)xMax yMax:(double)yMax zMax:(double)zMax pcaCX:(double)pcaCX pcaCY:(double)pcaCY pcaCZ:(double)pcaCZ ax1X:(double)ax1X ax1Y:(double)ax1Y ax1Z:(double)ax1Z ax2X:(double)ax2X ax2Y:(double)ax2Y ax2Z:(double)ax2Z ax3X:(double)ax3X ax3Y:(double)ax3Y ax3Z:(double)ax3Z {
    if (self = [super init]) {
        _solidId = solidId; _faces = faces; _xMin = xMin; _yMin = yMin; _zMin = zMin; _xMax = xMax; _yMax = yMax; _zMax = zMax;
        _pcaCenterX = pcaCX; _pcaCenterY = pcaCY; _pcaCenterZ = pcaCZ;
        _pcaAxis1X = ax1X; _pcaAxis1Y = ax1Y; _pcaAxis1Z = ax1Z;
        _pcaAxis2X = ax2X; _pcaAxis2Y = ax2Y; _pcaAxis2Z = ax2Z;
        _pcaAxis3X = ax3X; _pcaAxis3Y = ax3Y; _pcaAxis3Z = ax3Z;
    }
    return self;
}
@end

@implementation STEPParseResult
- (instancetype)initWithSolids:(NSArray<SolidData *> *)solids {
    if (self = [super init]) { _solids = solids; }
    return self;
}
+ (instancetype)resultWithError:(NSError *)error {
    STEPParseResult *res = [[STEPParseResult alloc] init];
    res.error = error; return res;
}
@end

@implementation STEPBridge

+ (nullable STEPParseResult *)parseSTEPFile:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    @try {
        STEPControl_Reader reader;
        IFSelect_ReturnStatus stat = reader.ReadFile([url.path UTF8String]);
        if (stat != IFSelect_RetDone) { return nil; }
        
        reader.TransferRoots();
        TopoDS_Shape shape = reader.OneShape();
        
        BRepMesh_IncrementalMesh mesher(shape, 0.1);
        
        NSMutableArray *solids = [NSMutableArray array];
        int solidId = 0;
        
        TopExp_Explorer solidExp(shape, TopAbs_SOLID);
        while (solidExp.More()) {
            TopoDS_Solid solid = TopoDS::Solid(solidExp.Current());
            
            // --- PCA TENSOR COMPUTATION ---
            double pcaCX = 0, pcaCY = 0, pcaCZ = 0;
            double ax1X = 1, ax1Y = 0, ax1Z = 0;
            double ax2X = 0, ax2Y = 1, ax2Z = 0;
            double ax3X = 0, ax3Y = 0, ax3Z = 1;
            
            GProp_GProps props;
            BRepGProp::VolumeProperties(solid, props);
            if (props.Mass() < 1e-6) { BRepGProp::SurfaceProperties(solid, props); }
            
            if (props.Mass() >= 1e-6) {
                gp_Pnt center = props.CentreOfMass();
                pcaCX = center.X(); pcaCY = center.Y(); pcaCZ = center.Z();
                
                GProp_PrincipalProps pProps = props.PrincipalProperties();
                gp_Dir a1 = pProps.FirstAxisOfInertia();
                gp_Dir a2 = pProps.SecondAxisOfInertia();
                gp_Dir a3 = pProps.ThirdAxisOfInertia(); // Extrusion axis is min inertia
                
                ax1X = a1.X(); ax1Y = a1.Y(); ax1Z = a1.Z();
                ax2X = a2.X(); ax2Y = a2.Y(); ax2Z = a2.Z();
                ax3X = a3.X(); ax3Y = a3.Y(); ax3Z = a3.Z();
            }
            // ------------------------------
            
            TopTools_IndexedMapOfShape faceMap;
            TopExp::MapShapes(solid, TopAbs_FACE, faceMap);
            
            TopTools_IndexedMapOfShape edgeMap;
            TopExp::MapShapes(solid, TopAbs_EDGE, edgeMap);
            
            TopTools_IndexedDataMapOfShapeListOfShape edgeToFaces;
            TopExp::MapShapesAndAncestors(solid, TopAbs_EDGE, TopAbs_FACE, edgeToFaces);
            
            NSMutableArray *facesArray = [NSMutableArray array];
            
            for (int fIndex = 1; fIndex <= faceMap.Extent(); fIndex++) {
                TopoDS_Face face = TopoDS::Face(faceMap.FindKey(fIndex));
                
                int surfaceType = 5;
                CylinderSurfaceData *cylData = nil;
                PlaneSurfaceData *planeData = nil;
                
                TopLoc_Location loc;
                Handle(Geom_Surface) surf = BRep_Tool::Surface(face, loc);
                if (!surf.IsNull()) {
                    if (surf->IsKind(STANDARD_TYPE(Geom_CylindricalSurface))) {
                        surfaceType = 1;
                        Handle(Geom_CylindricalSurface) cyl = Handle(Geom_CylindricalSurface)::DownCast(surf);
                        gp_Cylinder cylinder = cyl->Cylinder();
                        cylData = [[CylinderSurfaceData alloc] initWithRadius:cylinder.Radius() locationX:cylinder.Location().X() locationY:cylinder.Location().Y() locationZ:cylinder.Location().Z() axisX:cylinder.Axis().Direction().X() axisY:cylinder.Axis().Direction().Y() axisZ:cylinder.Axis().Direction().Z()];
                    } else if (surf->IsKind(STANDARD_TYPE(Geom_Plane))) {
                        surfaceType = 0;
                        Handle(Geom_Plane) pln = Handle(Geom_Plane)::DownCast(surf);
                        gp_Pln plane = pln->Pln();
                        planeData = [[PlaneSurfaceData alloc] initWithLocationX:plane.Location().X() locationY:plane.Location().Y() locationZ:plane.Location().Z() normalX:plane.Axis().Direction().X() normalY:plane.Axis().Direction().Y() normalZ:plane.Axis().Direction().Z()];
                    }
                }
                
                NSMutableArray *wiresArray = [NSMutableArray array];
                int wireID = 0;
                
                TopExp_Explorer wireExp(face, TopAbs_WIRE);
                while (wireExp.More()) {
                    TopoDS_Wire wire = TopoDS::Wire(wireExp.Current());
                    BOOL isInner = (wire.Orientation() != face.Orientation());
                    NSMutableArray *edgesArray = [NSMutableArray array];
                    BRepTools_WireExplorer edgeExplorer(wire);
                    
                    while (edgeExplorer.More()) {
                        TopoDS_Edge edge = edgeExplorer.Current();
                        int eID = edgeMap.FindIndex(edge);
                        
                        NSMutableArray *edgePoints = [NSMutableArray array];
                        BRepAdaptor_Curve curve(edge);
                        GCPnts_UniformDeflection defl(curve, 0.1);
                        
                        if (defl.IsDone()) {
                            if (edge.Orientation() == TopAbs_FORWARD) {
                                for (int i = 1; i <= defl.NbPoints(); ++i) {
                                    gp_Pnt p = defl.Value(i);
                                    [edgePoints addObject:@{@"x": @(p.X()), @"y": @(p.Y()), @"z": @(p.Z())}];
                                }
                            } else {
                                for (int i = defl.NbPoints(); i >= 1; --i) {
                                    gp_Pnt p = defl.Value(i);
                                    [edgePoints addObject:@{@"x": @(p.X()), @"y": @(p.Y()), @"z": @(p.Z())}];
                                }
                            }
                        }
                        
                        NSMutableArray *adjFaceIDs = [NSMutableArray array];
                        const TopTools_ListOfShape& faceList = edgeToFaces.FindFromKey(edge);
                        for (TopTools_ListIteratorOfListOfShape it(faceList); it.More(); it.Next()) {
                            [adjFaceIDs addObject:@(faceMap.FindIndex(it.Value()))];
                        }
                        
                        [edgesArray addObject:[[EdgeData alloc] initWithEdgeID:eID curveType:curve.GetType() adjacentFaces:adjFaceIDs points:edgePoints]];
                        edgeExplorer.Next();
                    }
                    [wiresArray addObject:[[WireData alloc] initWithWireID:wireID isInner:isInner edges:edgesArray]];
                    wireID++;
                    wireExp.Next();
                }
                
                NSMutableArray *verts = [NSMutableArray array];
                NSMutableArray *idxs = [NSMutableArray array];
                
                Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, loc);
                if (!triangulation.IsNull()) {
                    for (int i = 1; i <= triangulation->NbNodes(); ++i) {
                        gp_Pnt p = triangulation->Node(i);
                        p.Transform(loc.Transformation());
                        [verts addObject:@{@"x": @(p.X()), @"y": @(p.Y()), @"z": @(p.Z())}];
                    }
                    for (int i = 1; i <= triangulation->NbTriangles(); ++i) {
                        int n1, n2, n3;
                        triangulation->Triangle(i).Get(n1, n2, n3);
                        [idxs addObject:@[@(n1 - 1), @(n2 - 1), @(n3 - 1)]];
                    }
                }
                
                [facesArray addObject:[[FaceData alloc] initWithFaceID:fIndex type:surfaceType cyl:cylData plane:planeData wires:wiresArray verts:verts idxs:idxs norms:@[] area:0.0]];
            }
            
            Bnd_Box bbox;
            BRepBndLib::Add(solid, bbox);
            double xmin, ymin, zmin, xmax, ymax, zmax;
            bbox.Get(xmin, ymin, zmin, xmax, ymax, zmax);
            
            [solids addObject:[[SolidData alloc] initWithSolidId:solidId faces:facesArray xMin:xmin yMin:ymin zMin:zmin xMax:xmax yMax:ymax zMax:zmax pcaCX:pcaCX pcaCY:pcaCY pcaCZ:pcaCZ ax1X:ax1X ax1Y:ax1Y ax1Z:ax1Z ax2X:ax2X ax2Y:ax2Y ax2Z:ax2Z ax3X:ax3X ax3Y:ax3Y ax3Z:ax3Z]];
            solidId++;
            solidExp.Next();
        }
        return [[STEPParseResult alloc] initWithSolids:solids];
    } @catch (NSException *exception) {
        return nil;
    }
}
@end
