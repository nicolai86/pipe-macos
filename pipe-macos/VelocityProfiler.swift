import Foundation

// MARK: - Velocity Profiler

/// Computes per-segment feedrates using jerk-limited S-curve velocity profiling.
///
/// Pipeline:
///   1. Build trajectory segments — extract delta XYZAm and map per-axis
///      acceleration/jerk limits into path-space equivalents
///   2. Compute junction velocity limits at direction changes
///   3. Forward pass — accelerate from rest, capped at junction limits
///   4. Backward pass — decelerate to rest, respecting same limits
///   5. Resolve final feedrate per segment from the forward/backward envelope
struct VelocityProfiler {
    let settings: GCodeSettings

    // MARK: - Public API

    func profile(machinePoints: [MachinePoint]) -> [TrajectorySegment] {
        guard machinePoints.count > 1 else { return [] }
        var segments = buildSegments(machinePoints: machinePoints)
        let junctionVelocities = computeJunctionVelocities(segments: segments, pointCount: machinePoints.count)
        let vFwd = forwardPass(segments: segments, junctionVelocities: junctionVelocities)
        let vFinal = backwardPass(segments: segments, forwardVelocities: vFwd)
        return resolveFeedrates(segments: &segments, finalVelocities: vFinal)
    }

    // MARK: - Segment Building

    private func buildSegments(machinePoints: [MachinePoint]) -> [TrajectorySegment] {
        let aMaxX = settings.maxAccelX * 3600.0
        let aMaxY = settings.maxAccelY * 3600.0
        let aMaxZ = settings.maxAccelZ * 3600.0
        let aMaxA = settings.maxAccelA * 3600.0
        let jMaxX = settings.maxJerkX * 216000.0
        let jMaxY = settings.maxJerkY * 216000.0
        let jMaxZ = settings.maxJerkZ * 216000.0
        let jMaxA = settings.maxJerkA * 216000.0

        var segments: [TrajectorySegment] = []
        segments.reserveCapacity(machinePoints.count - 1)

        for i in 1..<machinePoints.count {
            let prev = machinePoints[i - 1]
            let curr = machinePoints[i]
            let dS = max(1e-6, sqrt(
                pow(curr.matX - prev.matX, 2)
                + pow(curr.matU - prev.matU, 2)
                + pow(curr.matV - prev.matV, 2)
            ))
            let dXm = curr.Xm - prev.Xm
            let dYm = curr.Ym - prev.Ym
            let dZm = curr.Zm - prev.Zm
            let dAm = curr.Am - prev.Am
            let dMachine = sqrt(dXm * dXm + dYm * dYm + dZm * dZm + dAm * dAm)
            let aPath = min(
                abs(dXm) > 1e-6 ? aMaxX * dS / abs(dXm) : .greatestFiniteMagnitude,
                abs(dYm) > 1e-6 ? aMaxY * dS / abs(dYm) : .greatestFiniteMagnitude,
                abs(dZm) > 1e-6 ? aMaxZ * dS / abs(dZm) : .greatestFiniteMagnitude,
                abs(dAm) > 1e-6 ? aMaxA * dS / abs(dAm) : .greatestFiniteMagnitude
            )
            let jPath = min(
                abs(dXm) > 1e-6 ? jMaxX * dS / abs(dXm) : .greatestFiniteMagnitude,
                abs(dYm) > 1e-6 ? jMaxY * dS / abs(dYm) : .greatestFiniteMagnitude,
                abs(dZm) > 1e-6 ? jMaxZ * dS / abs(dZm) : .greatestFiniteMagnitude,
                abs(dAm) > 1e-6 ? jMaxA * dS / abs(dAm) : .greatestFiniteMagnitude
            )
            segments.append(TrajectorySegment(
                dS: dS, dMachine: dMachine,
                dXm: dXm, dYm: dYm, dZm: dZm, dAm: dAm,
                aPath: aPath, jPath: jPath
            ))
        }
        return segments
    }

    // MARK: - Junction Velocities

    private func computeJunctionVelocities(segments: [TrajectorySegment], pointCount: Int) -> [CGFloat] {
        let aMaxX = settings.maxAccelX * 3600.0
        let aMaxY = settings.maxAccelY * 3600.0
        let aMaxZ = settings.maxAccelZ * 3600.0
        let aMaxA = settings.maxAccelA * 3600.0

        var vJunction = [CGFloat](repeating: settings.feedRate, count: pointCount)
        guard segments.count > 1 else { return vJunction }

        for i in 1..<segments.count {
            let prev = segments[i - 1]
            let curr = segments[i]
            let dS_avg = (prev.dS + curr.dS) / 2.0
            if dS_avg < 1e-6 { continue }
            let drX = abs(curr.dXm / curr.dS - prev.dXm / prev.dS)
            let drY = abs(curr.dYm / curr.dS - prev.dYm / prev.dS)
            let drZ = abs(curr.dZm / curr.dS - prev.dZm / prev.dS)
            let drA = abs(curr.dAm / curr.dS - prev.dAm / prev.dS)
            vJunction[i] = min(settings.feedRate, min(
                drX > 1e-6 ? sqrt(aMaxX * dS_avg / drX) : .greatestFiniteMagnitude,
                drY > 1e-6 ? sqrt(aMaxY * dS_avg / drY) : .greatestFiniteMagnitude,
                drZ > 1e-6 ? sqrt(aMaxZ * dS_avg / drZ) : .greatestFiniteMagnitude,
                drA > 1e-6 ? sqrt(aMaxA * dS_avg / drA) : .greatestFiniteMagnitude
            ))
        }
        return vJunction
    }

    // MARK: - S-Curve Velocity Profiling

    /// Estimates the maximum reachable velocity v1 after travelling distance s from v0,
    /// subject to acceleration limit a and jerk limit j (S-curve profile).
    ///
    /// WHY: Trapezoidal acceleration causes infinite jerk at ramp transitions → mechanical
    /// resonance. S-curve limits mm/s³ (jerk) to smooth these transitions, especially
    /// critical for the A-axis chuck which has the highest rotational inertia.
    private static func solveMaxV(v0: CGFloat, s: CGFloat, a: CGFloat, j: CGFloat) -> CGFloat {
        if s < 1e-6 { return v0 }
        // Case 1: reaches a_max — solve quadratic: j·v1² + a²·v1 + (a²·v0 − j·v0² − 2·s·a·j) = 0
        let b = a * a
        let c = a * a * v0 - j * v0 * v0 - 2.0 * s * a * j
        let disc = b * b - 4.0 * j * c
        if disc < 0 { return v0 + sqrt(2.0 * a * s) }  // Fallback to trapezoidal
        let v1_quad = (-b + sqrt(disc)) / (2.0 * j)
        // Case 2: doesn't reach a_max — approximate then refine
        var v1 = v0 + sqrt(2.0 * min(a, sqrt(j * (v1_quad - v0 + 1.0))) * s)
        for _ in 0..<3 {
            let dv = max(0, v1 - v0)
            let t = 2.0 * sqrt(dv / j)
            let s_req = (v0 + v1) / 2.0 * t
            v1 = v1 * (s / max(s_req, 1e-6))
        }
        return max(v0, min(v1_quad, v1))
    }

    private func forwardPass(segments: [TrajectorySegment], junctionVelocities: [CGFloat]) -> [CGFloat] {
        var vFwd = [CGFloat](repeating: 0.0, count: segments.count + 1)
        vFwd[0] = 0
        for i in 0..<segments.count {
            let seg = segments[i]
            vFwd[i + 1] = min(
                junctionVelocities[i + 1],
                VelocityProfiler.solveMaxV(v0: vFwd[i], s: seg.dS, a: seg.aPath, j: seg.jPath)
            )
        }
        return vFwd
    }

    private func backwardPass(segments: [TrajectorySegment], forwardVelocities: [CGFloat]) -> [CGFloat] {
        var vFinal = [CGFloat](repeating: 0.0, count: segments.count + 1)
        vFinal[segments.count] = 0
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let seg = segments[i]
            vFinal[i] = min(
                forwardVelocities[i],
                VelocityProfiler.solveMaxV(v0: vFinal[i + 1], s: seg.dS, a: seg.aPath, j: seg.jPath)
            )
        }
        return vFinal
    }

    private func resolveFeedrates(
        segments: inout [TrajectorySegment],
        finalVelocities: [CGFloat]
    ) -> [TrajectorySegment] {
        for i in 0..<segments.count {
            if settings.useSimCNC {
                // SimCNC expects feedrate in machine-space distance per unit time.
                // Convert surface-space velocity to machine-space feedrate.
                let vSafe = max((finalVelocities[i] + finalVelocities[i + 1]) / 2.0, 1.0)
                segments[i].finalF = min(
                    segments[i].dMachine / (segments[i].dS / vSafe),
                    settings.rapidRate
                )
            } else {
                segments[i].finalF = max(
                    min((finalVelocities[i] + finalVelocities[i + 1]) / 2.0, settings.feedRate),
                    1.0
                )
            }
        }
        return segments
    }
}
