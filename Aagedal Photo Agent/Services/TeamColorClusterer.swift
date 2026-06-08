import Foundation

/// Clusters sampled jersey colours into the two teams and decides which cluster
/// is home vs away by proximity to the configured kit colours.
///
/// Works in CIELAB so distances are perceptual (two visually-distinct kits are
/// well separated even if their RGB values aren't). The two configured kit
/// colours seed a deterministic k-means (k=2) — no randomness, so results are
/// reproducible — then the resulting centroids are mapped to sides by whichever
/// assignment is closer overall to the kits. The photographer can still flip the
/// mapping; `side(for:)` takes a `flipped` flag for that.
nonisolated struct TeamColorClusterer: Sendable {

    struct ClusterResult: Sendable, Equatable {
        /// Centroid colour assigned to the home side (before any user flip).
        var homeCentroid: ColorRGB
        /// Centroid colour assigned to the away side (before any user flip).
        var awayCentroid: ColorRGB
        /// 0...1 separation confidence: high when the two clusters are far apart
        /// relative to their internal spread. Low ⇒ ask the photographer.
        var confidence: Float
        /// Number of colours that fell into each cluster (home, away).
        var homeCount: Int
        var awayCount: Int
    }

    /// Cluster the sampled colours. Returns nil if there aren't enough colours to
    /// form a meaningful two-way split.
    func cluster(colors: [ColorRGB], homeKit: ColorRGB, awayKit: ColorRGB) -> ClusterResult? {
        let points = colors.map { Lab(srgb: $0) }
        guard points.count >= 2 else { return nil }

        var centroidH = Lab(srgb: homeKit)
        var centroidA = Lab(srgb: awayKit)
        // Degenerate seed (both kits identical) — nudge so assignment can split.
        if centroidH.deltaE(centroidA) < 1 {
            centroidA = Lab(l: centroidA.l + 10, a: centroidA.a, b: centroidA.b)
        }

        var assignH: [Lab] = []
        var assignA: [Lab] = []
        for _ in 0..<12 {
            assignH.removeAll(keepingCapacity: true)
            assignA.removeAll(keepingCapacity: true)
            for p in points {
                if p.deltaE(centroidH) <= p.deltaE(centroidA) {
                    assignH.append(p)
                } else {
                    assignA.append(p)
                }
            }
            // Re-seed an empty cluster to the point farthest from the other
            // centroid so it doesn't collapse to one cluster.
            if assignH.isEmpty, let far = points.max(by: { $0.deltaE(centroidA) < $1.deltaE(centroidA) }) {
                assignH = [far]
            }
            if assignA.isEmpty, let far = points.max(by: { $0.deltaE(centroidH) < $1.deltaE(centroidH) }) {
                assignA = [far]
            }
            let newH = Lab.mean(assignH) ?? centroidH
            let newA = Lab.mean(assignA) ?? centroidA
            let moved = newH.deltaE(centroidH) + newA.deltaE(centroidA)
            centroidH = newH
            centroidA = newA
            if moved < 0.5 { break }
        }

        // Map centroids to sides by the lower-cost assignment to the kit colours.
        let kitH = Lab(srgb: homeKit)
        let kitA = Lab(srgb: awayKit)
        let costDirect = centroidH.deltaE(kitH) + centroidA.deltaE(kitA)
        let costSwapped = centroidH.deltaE(kitA) + centroidA.deltaE(kitH)
        let swap = costSwapped < costDirect
        let finalHome = swap ? centroidA : centroidH
        let finalAway = swap ? centroidH : centroidA
        let homeMembers = swap ? assignA : assignH
        let awayMembers = swap ? assignH : assignA

        let separation = finalHome.deltaE(finalAway)
        let spread = (Lab.meanSpread(homeMembers, around: finalHome)
                      + Lab.meanSpread(awayMembers, around: finalAway)) / 2
        let confidence = separation <= 0 ? 0 : Float(separation / (separation + spread + 1))

        return ClusterResult(
            homeCentroid: finalHome.srgb,
            awayCentroid: finalAway.srgb,
            confidence: min(1, max(0, confidence)),
            homeCount: homeMembers.count,
            awayCount: awayMembers.count
        )
    }

    /// Assign a single colour to a side using the clustered centroids. `flipped`
    /// swaps the mapping (the photographer's confirm/flip control).
    func side(for color: ColorRGB, in result: ClusterResult, flipped: Bool) -> TeamSide {
        let p = Lab(srgb: color)
        let dHome = p.deltaE(Lab(srgb: result.homeCentroid))
        let dAway = p.deltaE(Lab(srgb: result.awayCentroid))
        let nearer: TeamSide = dHome <= dAway ? .home : .away
        if !flipped { return nearer }
        return nearer == .home ? .away : .home
    }
}

/// Minimal CIELAB colour for perceptual distance. D65 white point.
nonisolated private struct Lab {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l; self.a = a; self.b = b
    }

    init(srgb: ColorRGB) {
        // sRGB (0...1) → linear
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(srgb.r), g = lin(srgb.g), bl = lin(srgb.b)
        // linear RGB → XYZ (D65)
        let x = (r * 0.4124 + g * 0.3576 + bl * 0.1805) / 0.95047
        let y = (r * 0.2126 + g * 0.7152 + bl * 0.0722) / 1.0
        let z = (r * 0.0193 + g * 0.1192 + bl * 0.9505) / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let fx = f(x), fy = f(y), fz = f(z)
        self.l = (116 * fy) - 16
        self.a = 500 * (fx - fy)
        self.b = 200 * (fy - fz)
    }

    /// Approximate sRGB back-conversion, for surfacing centroid colours in the UI.
    var srgb: ColorRGB {
        let fy = (l + 16) / 116
        let fx = a / 500 + fy
        let fz = fy - b / 200
        func inv(_ t: Double) -> Double {
            let t3 = t * t * t
            return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787
        }
        let x = inv(fx) * 0.95047
        let y = inv(fy) * 1.0
        let z = inv(fz) * 1.08883
        let r =  x *  3.2406 + y * -1.5372 + z * -0.4986
        let g =  x * -0.9689 + y *  1.8758 + z *  0.0415
        let bl = x *  0.0557 + y * -0.2040 + z *  1.0570
        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
            return min(1, max(0, v))
        }
        return ColorRGB(r: gamma(r), g: gamma(g), b: gamma(bl))
    }

    func deltaE(_ other: Lab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    static func mean(_ points: [Lab]) -> Lab? {
        guard !points.isEmpty else { return nil }
        let n = Double(points.count)
        return Lab(
            l: points.reduce(0) { $0 + $1.l } / n,
            a: points.reduce(0) { $0 + $1.a } / n,
            b: points.reduce(0) { $0 + $1.b } / n
        )
    }

    static func meanSpread(_ points: [Lab], around center: Lab) -> Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.deltaE(center) } / Double(points.count)
    }
}
