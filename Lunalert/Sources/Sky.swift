import AppKit
import CoreLocation
import Foundation
import SwiftUI

// MARK: - Catalog

/// Real stars and constellation lines from the bundled catalog (d3-celestial, BSD-3-Clause; see README).
struct SkyCatalog {
    struct Star { let ra: Double; let dec: Double; let mag: Double; let bv: Double }

    let stars: [Star]
    /// Constellation abbreviation (IAU) → polylines of [raDeg, decDeg].
    let lines: [(id: String, polylines: [[[Double]]])]

    static let shared: SkyCatalog = {
        struct File: Decodable { let stars: [[Double]]; let lines: [String: [[[Double]]]] }
        guard let url = Bundle.main.url(forResource: "sky", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return SkyCatalog(stars: [], lines: []) }
        return SkyCatalog(stars: file.stars.map { Star(ra: $0[0], dec: $0[1], mag: $0[2], bv: $0[3]) },
                          lines: file.lines.map { (id: $0.key, polylines: $0.value) })
    }()
}

// MARK: - Astronomy

/// Low-precision formulas, accurate to a fraction of a degree: plenty for drawing the sky.
enum Astronomy {
    static let rad = Double.pi / 180

    /// Days since J2000.0 (2000-01-01 12:00 TT, taken as UTC here).
    static func daysSinceJ2000(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
    }

    /// Local sidereal time in degrees.
    static func localSiderealTime(_ date: Date, longitude: Double) -> Double {
        let gmst = 280.46061837 + 360.98564736629 * daysSinceJ2000(date)
        return (gmst + longitude).truncatingRemainder(dividingBy: 360)
    }

    /// Altitude and azimuth (degrees; azimuth from north through east) of a point at RA/Dec.
    static func horizontal(ra: Double, dec: Double, latitude: Double, lst: Double) -> (alt: Double, az: Double) {
        let h = (lst - ra) * rad, d = dec * rad, phi = latitude * rad
        let sinAlt = sin(phi) * sin(d) + cos(phi) * cos(d) * cos(h)
        let alt = asin(max(-1, min(1, sinAlt)))
        let az = atan2(-sin(h) * cos(d), cos(phi) * sin(d) - sin(phi) * cos(d) * cos(h))
        return (alt / rad, (az / rad + 360).truncatingRemainder(dividingBy: 360))
    }

    /// Ecliptic longitude/latitude to RA/Dec (degrees).
    static func equatorial(lambda: Double, beta: Double) -> (ra: Double, dec: Double) {
        let e = 23.4393 * rad, l = lambda * rad, b = beta * rad
        let ra = atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
        let dec = asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
        return ((ra / rad + 360).truncatingRemainder(dividingBy: 360), dec / rad)
    }

    static func sun(_ date: Date) -> (ra: Double, dec: Double, lambda: Double) {
        let d = daysSinceJ2000(date)
        let l0 = 280.460 + 0.9856474 * d
        let g = (357.528 + 0.9856003 * d) * rad
        let lambda = l0 + 1.915 * sin(g) + 0.020 * sin(2 * g)
        let eq = equatorial(lambda: lambda, beta: 0)
        return (eq.ra, eq.dec, lambda)
    }

    /// The Moon's position and how much of it is lit (0 new … 1 full).
    static func moon(_ date: Date) -> (ra: Double, dec: Double, illuminated: Double, waxing: Bool) {
        let d = daysSinceJ2000(date)
        let l = 218.316 + 13.176396 * d
        let m = (134.963 + 13.064993 * d) * rad
        let f = (93.272 + 13.229350 * d) * rad
        let lambda = l + 6.289 * sin(m)
        let beta = 5.128 * sin(f)
        let eq = equatorial(lambda: lambda, beta: beta)
        let elongation = (lambda - sun(date).lambda).truncatingRemainder(dividingBy: 360)
        let e = (elongation + 360).truncatingRemainder(dividingBy: 360)
        return (eq.ra, eq.dec, (1 - cos(e * rad)) / 2, e < 180)
    }
}

// MARK: - Where the sky is seen from

/// The observer: from the Mac's time zone by default (no permission needed), or Location Services if chosen.
@MainActor
final class SkyLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SkyLocation()

    @Published private(set) var latitude: Double
    @Published private(set) var longitude: Double
    @Published private(set) var source: String
    @AppStorage("skyPreciseLocation") var precise = false {
        didSet { precise ? requestPrecise() : useTimeZone() }
    }

    private let manager = CLLocationManager()

    override private init() {
        let zone = SkyLocation.timeZoneCoordinate()
        latitude = zone.lat
        longitude = zone.lon
        source = zone.name
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if precise { requestPrecise() }
    }

    private func useTimeZone() {
        let zone = SkyLocation.timeZoneCoordinate()
        latitude = zone.lat
        longitude = zone.lon
        source = zone.name
    }

    private func requestPrecise() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: source = "\(SkyLocation.timeZoneCoordinate().name) (Location Services is off)"
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.precise { self.requestPrecise() } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in
            guard self.precise else { return }
            self.latitude = c.latitude
            self.longitude = c.longitude
            self.source = String(format: "%.1f°, %.1f° (Location Services)", c.latitude, c.longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// The reference city for the Mac's time zone, from the system's zone table; local, no network.
    static func timeZoneCoordinate(_ zone: TimeZone = .current) -> (lat: Double, lon: Double, name: String) {
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        for path in ["/usr/share/zoneinfo/zone.tab", "/usr/share/zoneinfo/zone1970.tab"] {
            guard let table = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in table.split(separator: "\n") where !line.hasPrefix("#") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 3, cols[2] == zone.identifier, let c = parseISO6709(String(cols[1])) else { continue }
                return (c.lat, c.lon, "\(city) (from your time zone)")
            }
        }
        return (30, Double(zone.secondsFromGMT()) / 240, "\(city) (approximate)")
    }

    /// "+314650+0351326" → (31.78, 35.22)
    static func parseISO6709(_ s: String) -> (lat: Double, lon: Double)? {
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func value(_ part: Substring, degreeDigits: Int) -> Double? {
            let sign: Double = part.first == "-" ? -1 : 1
            let digits = part.dropFirst()
            guard digits.count >= degreeDigits + 2,
                  let deg = Double(digits.prefix(degreeDigits)),
                  let min = Double(digits.dropFirst(degreeDigits).prefix(2)) else { return nil }
            let sec = Double(digits.dropFirst(degreeDigits + 2).prefix(2)) ?? 0
            return sign * (deg + min / 60 + sec / 3600)
        }
        guard let lat = value(s[..<split], degreeDigits: 2), let lon = value(s[split...], degreeDigits: 3) else { return nil }
        return (lat, lon)
    }
}

// MARK: - Projection

/// One sky for the whole screen: looking up toward the south (north below the equator), the horizon near the
/// bottom of the screen and the zenith above its middle. Every window shows the part of it behind the window.
struct SkyProjection {
    /// The screen's size.
    let size: CGSize
    let latitude: Double
    var centerAz: Double { latitude >= 0 ? 180 : 0 }
    /// Where the horizon sits, measured up from the bottom of the screen.
    let horizonInset: CGFloat = 60
    /// Horizontal field of view across the whole screen, degrees.
    let fieldOfView = 180.0

    private var scale: CGFloat { (size.width / 2) / CGFloat(2 * tan(fieldOfView / 2 * Astronomy.rad / 2)) }

    /// The altitude at the centre of the view that puts the horizon `horizonInset` above the bottom edge.
    var centerAlt: Double {
        let below = max(0, size.height / 2 - horizonInset)
        return min(80, 2 * atan(Double(below / scale) / 2) / Astronomy.rad)
    }

    /// Stereographic projection; nil for points behind the viewer.
    func point(alt: Double, az: Double) -> CGPoint? {
        let a = alt * Astronomy.rad, a0 = centerAlt * Astronomy.rad
        let dAz = (az - centerAz) * Astronomy.rad
        let cosC = sin(a0) * sin(a) + cos(a0) * cos(a) * cos(dAz)
        guard cosC > -0.3 else { return nil }
        let k = 2 / (1 + cosC)
        let x = k * cos(a) * sin(dAz)
        let y = k * (cos(a0) * sin(a) - sin(a0) * cos(a) * cos(dAz))
        // Facing south, east is on the left: east has dAz < 0, so it must land left of centre.
        return CGPoint(x: size.width / 2 + CGFloat(x) * scale, y: size.height / 2 - CGFloat(y) * scale)
    }
}

// MARK: - Drawing

/// Everything placed for one minute: recomputed only when the minute, place or size changes.
struct SkyFrame {
    struct Point { let p: CGPoint; let mag: Double; let color: Color; let fade: Double }
    let stars: [Point]
    let segments: [(CGPoint, CGPoint)]
    /// The same segments, kept per constellation for hovering in stargaze mode.
    let constellations: [(id: String, segments: [(CGPoint, CGPoint)])]
    let horizon: [CGPoint]
    let moon: (p: CGPoint, illuminated: Double, waxing: Bool, sunAngle: Double)?
    let sunAlt: Double
    let cardinal: [(String, CGPoint)]

    @MainActor static func make(date: Date, latitude: Double, longitude: Double, size: CGSize) -> SkyFrame {
        let lst = Astronomy.localSiderealTime(date, longitude: longitude)
        let projection = SkyProjection(size: size, latitude: latitude)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)

        func place(_ ra: Double, _ dec: Double) -> (CGPoint, Double)? {
            let h = Astronomy.horizontal(ra: ra, dec: dec, latitude: latitude, lst: lst)
            guard h.alt > -2, let p = projection.point(alt: h.alt, az: h.az), bounds.contains(p) else { return nil }
            return (p, h.alt)
        }

        let catalog = SkyCatalog.shared
        let stars = catalog.stars.compactMap { s -> Point? in
            guard let (p, alt) = place(s.ra, s.dec) else { return nil }
            // Stars dim toward the horizon, as through thicker air, so the sky ends softly with no edge.
            return Point(p: p, mag: s.mag, color: starColor(bv: s.bv), fade: max(0, min(1, (alt + 2) / 14)))
        }
        var constellations: [(id: String, segments: [(CGPoint, CGPoint)])] = []
        for constellation in catalog.lines {
            var segs: [(CGPoint, CGPoint)] = []
            for line in constellation.polylines {
                for pair in zip(line, line.dropFirst()) {
                    if let a = place(pair.0[0], pair.0[1]), let b = place(pair.1[0], pair.1[1]) { segs.append((a.0, b.0)) }
                }
            }
            if !segs.isEmpty { constellations.append((constellation.id, segs)) }
        }
        let segments = constellations.flatMap(\.segments)
        let horizon = stride(from: projection.centerAz - 120, through: projection.centerAz + 120, by: 3)
            .compactMap { projection.point(alt: 0, az: $0) }
        let sun = Astronomy.sun(date)
        let sunH = Astronomy.horizontal(ra: sun.ra, dec: sun.dec, latitude: latitude, lst: lst)
        var moonInfo: (CGPoint, Double, Bool, Double)?
        let m = Astronomy.moon(date)
        if let (mp, _) = place(m.ra, m.dec) {
            // Which way the lit side faces: toward the Sun as projected on this view.
            let sp = projection.point(alt: sunH.alt, az: sunH.az) ?? CGPoint(x: size.width / 2, y: size.height * 2)
            moonInfo = (mp, m.illuminated, m.waxing, atan2(sp.y - mp.y, sp.x - mp.x))
        }
        let south = projection.centerAz
        let cardinal = [(south == 180 ? "S" : "N", south), ("E", 90.0), ("W", 270.0), (south == 180 ? "SE" : "NE", south == 180 ? 135 : 45),
                        (south == 180 ? "SW" : "NW", south == 180 ? 225 : 315)]
            .compactMap { label, az -> (String, CGPoint)? in
                guard let p = projection.point(alt: 0, az: az), p.x > 12, p.x < size.width - 12 else { return nil }
                return (label, p)
            }
        return SkyFrame(stars: stars, segments: segments, constellations: constellations, horizon: horizon, moon: moonInfo, sunAlt: sunH.alt, cardinal: cardinal)
    }

    /// Star colour from its B-V colour index: blue-white for hot stars, amber for cool ones.
    static func starColor(bv: Double) -> Color {
        switch bv {
        case ..<0.0: return Color(red: 0.74, green: 0.83, blue: 1.0)
        case ..<0.3: return Color(red: 0.88, green: 0.92, blue: 1.0)
        case ..<0.6: return Color(red: 1.0, green: 0.98, blue: 0.95)
        case ..<1.0: return Color(red: 1.0, green: 0.92, blue: 0.78)
        case ..<1.4: return Color(red: 1.0, green: 0.84, blue: 0.64)
        default: return Color(red: 1.0, green: 0.76, blue: 0.56)
        }
    }
}

/// The real sky over the observer, right now. The whole screen's sky is painted once a minute into one image;
/// each window shows its part of it. In the app that's a Core Animation layer that only slides when a window
/// moves, so dragging costs nothing; offscreen renders (snapshots) use plain SwiftUI so they can be captured.
struct RealSky: View {
    @ObservedObject private var location = SkyLocation.shared
    @ObservedObject private var model = SkyModel.shared
    @Environment(\.skyViewport) private var fixedViewport
    @Environment(\.skyRole) private var role
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skyDate) private var fixedDate
    @AppStorage("animatedSky") private var animatedSky = true
    @AppStorage("constellationLines") private var constellationLines = true
    @State private var liveScreen: CGSize?

    var body: some View {
        TimelineView(.everyMinute) { minute in
            let date = fixedDate ?? minute.date
            let screen = fixedViewport?.screen ?? liveScreen ?? NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
            let frame = model.frame(date: date, latitude: location.latitude, longitude: location.longitude, size: screen)
            let night = scheme == .dark
            if let fixed = fixedViewport {
                let image = model.image(frame: frame, screen: screen, night: night, lines: constellationLines,
                                        dim: model.stargazing, brightCores: true)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        if let image {
                            Image(decorative: image, scale: SkyModel.imageScale)
                                .offset(x: -fixed.origin.x, y: -fixed.origin.y)
                        }
                        if let id = model.hovered, let c = frame.constellations.first(where: { $0.id == id }) {
                            Canvas { ctx, _ in
                                ctx.translateBy(x: -fixed.origin.x, y: -fixed.origin.y)
                                SkyPainter.paintHighlight(c.segments, night: night, in: &ctx)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
                }
            } else {
                let twinkle = animatedSky && !reduceMotion
                SkyLayer(image: model.image(frame: frame, screen: screen, night: night, lines: constellationLines,
                                            dim: model.stargazing, brightCores: !twinkle),
                         frame: frame, frameKey: model.frameKeyValue, screen: screen,
                         hovered: model.hovered, twinkle: twinkle, night: night, role: role) { size in
                    if size != liveScreen { liveScreen = size }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Drawing for the sky image and the hover highlight, in screen coordinates (top-left origin).
@MainActor
enum SkyPainter {
    static func image(frame: SkyFrame, screen: CGSize, night: Bool, lines: Bool, dim: Bool, brightCores: Bool,
                      scale: CGFloat) -> CGImage? {
        let content = Canvas { ctx, _ in
            paint(frame, screen: screen, night: night, lines: lines, dim: dim, brightCores: brightCores, in: &ctx)
        }
        .frame(width: screen.width, height: screen.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    static func ink(night: Bool) -> Color { night ? .white : Color(red: 0.25, green: 0.33, blue: 0.5) }

    static func paint(_ frame: SkyFrame, screen: CGSize, night: Bool, lines: Bool, dim: Bool, brightCores: Bool,
                      in ctx: inout GraphicsContext) {
        let ink = ink(night: night)
        // The glow toward the horizon, warmer in twilight; it steps back in Stargaze.
        let base = night ? Color(red: 0.17, green: 0.24, blue: 0.37) : Color(red: 0.79, green: 0.86, blue: 0.96)
        let strength = max(0, min(1, (frame.sunAlt + 18) / 18))
        ctx.fill(Path(CGRect(origin: .zero, size: screen)), with: .linearGradient(
            Gradient(colors: [.clear, base.opacity((night ? 0.32 + 0.2 * strength : 0.6) * (dim ? 0.25 : 1))]),
            startPoint: CGPoint(x: 0, y: screen.height * 0.35), endPoint: CGPoint(x: 0, y: screen.height)))
        if lines {
            var path = Path()
            for (a, b) in frame.segments { path.move(to: a); path.addLine(to: b) }
            ctx.stroke(path, with: .color(ink.opacity(night ? 0.065 : 0.10)), lineWidth: 0.6)
        }
        for star in frame.stars where star.mag >= 2.6 {
            let r = max(0.45, 1.95 - 0.28 * star.mag)
            let opacity = max(0.18, min(0.95, 1.15 - 0.14 * star.mag))
            ctx.fill(Path(ellipseIn: CGRect(x: star.p.x - r, y: star.p.y - r, width: r * 2, height: r * 2)),
                     with: .color(night ? star.color.opacity(opacity * star.fade) : ink.opacity(opacity * 0.5 * star.fade)))
        }
        for star in frame.stars where star.mag < 2.6 {
            let r = brightRadius(star.mag)
            if night {
                var glow = ctx
                glow.addFilter(.blur(radius: r * 1.6))
                glow.fill(Path(ellipseIn: CGRect(x: star.p.x - r * 1.6, y: star.p.y - r * 1.6, width: r * 3.2, height: r * 3.2)),
                          with: .color(star.color.opacity(0.35 * star.fade)))
            }
            if brightCores {
                ctx.fill(Path(ellipseIn: CGRect(x: star.p.x - r, y: star.p.y - r, width: r * 2, height: r * 2)),
                         with: .color(night ? star.color.opacity(star.fade) : ink.opacity(0.55 * star.fade)))
            }
        }
        if let moon = frame.moon { paintMoon(moon, in: &ctx) }
    }

    static func brightRadius(_ mag: Double) -> CGFloat { max(1.0, 2.2 - 0.32 * mag) }

    /// The hovered constellation: its lines lit and its stars brightened, with a soft glow.
    static func paintHighlight(_ segments: [(CGPoint, CGPoint)], night: Bool, in ctx: inout GraphicsContext) {
        let ink: Color = night ? Color(red: 0.8, green: 0.88, blue: 1) : Color(red: 0.18, green: 0.3, blue: 0.6)
        var path = Path()
        for (a, b) in segments { path.move(to: a); path.addLine(to: b) }
        var glow = ctx
        glow.addFilter(.blur(radius: 4))
        glow.stroke(path, with: .color(ink.opacity(0.5)), lineWidth: 2.5)
        ctx.stroke(path, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        for point in vertices(segments) {
            ctx.fill(Path(ellipseIn: CGRect(x: point.x - 1.8, y: point.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white))
        }
    }

    static func vertices(_ segments: [(CGPoint, CGPoint)]) -> [CGPoint] {
        var seen = Set<String>()
        return segments.flatMap { [$0.0, $0.1] }.filter { seen.insert("\(Int($0.x)):\(Int($0.y))").inserted }
    }

    static func paintMoon(_ moon: (p: CGPoint, illuminated: Double, waxing: Bool, sunAngle: Double), in ctx: inout GraphicsContext) {
        let r: CGFloat = 7
        let rect = CGRect(x: moon.p.x - r, y: moon.p.y - r, width: r * 2, height: r * 2)
        var glow = ctx
        glow.addFilter(.blur(radius: 9))
        glow.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)),
                  with: .color(Color(red: 0.85, green: 0.9, blue: 1).opacity(0.25 + 0.35 * moon.illuminated)))
        ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.25, green: 0.28, blue: 0.35).opacity(0.9)))
        var lit = ctx
        lit.translateBy(x: moon.p.x, y: moon.p.y)
        lit.rotate(by: .radians(moon.sunAngle))
        let k = moon.illuminated
        var half = Path()
        half.addArc(center: .zero, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        let w = r * CGFloat(abs(1 - 2 * k))
        let terminator = Path(ellipseIn: CGRect(x: -w, y: -r, width: w * 2, height: r * 2))
        let light = Color(red: 0.94, green: 0.95, blue: 0.98)
        let dark = Color(red: 0.25, green: 0.28, blue: 0.35)
        lit.fill(half, with: .color(light))
        // Gibbous: the terminator bulges into the dark half. Crescent: it eats into the lit half.
        lit.fill(terminator, with: .color(k >= 0.5 ? light : dark))
    }
}

/// The live sky: a layer-backed view holding the screen's sky image, twinkle and highlight layers. Moving the
/// window slides the layer (on every display refresh while dragging); nothing is redrawn.
struct SkyLayer: NSViewRepresentable {
    let image: CGImage?
    let frame: SkyFrame
    let frameKey: String
    let screen: CGSize
    let hovered: String?
    let twinkle: Bool
    let night: Bool
    let role: SkyRole
    let onScreenChange: (CGSize) -> Void

    func makeNSView(context: Context) -> SkyLayerView {
        let view = SkyLayerView(role: role)
        view.onScreenChange = onScreenChange
        return view
    }

    func updateNSView(_ view: SkyLayerView, context: Context) {
        view.onScreenChange = onScreenChange
        view.update(image: image, frame: frame, frameKey: frameKey, screen: screen, hovered: hovered,
                    twinkle: twinkle, night: night)
    }
}

final class SkyLayerView: NSView {
    var onScreenChange: ((CGSize) -> Void)?
    private let role: SkyRole
    private let container = CALayer()
    private let imageLayer = CALayer()
    private let twinkleLayer = CALayer()
    private let highlightLines = CAShapeLayer()
    private let highlightDots = CAShapeLayer()
    private var screen = CGSize.zero
    private var origin = CGPoint.zero
    private var parallax = CGSize.zero
    private var builtTwinkleKey: String?
    private var shownHighlight: String?
    private var observers: [NSObjectProtocol] = []
    private var parallaxSubscription: Any?
    private var link: CADisplayLink?
    private var quietTicks = 0

    init(role: SkyRole) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        container.anchorPoint = .zero
        for sub in [imageLayer, twinkleLayer, highlightLines, highlightDots] as [CALayer] {
            sub.anchorPoint = .zero
            container.addSublayer(sub)
        }
        imageLayer.contentsGravity = .resize
        for shape in [highlightLines, highlightDots] {
            shape.opacity = 0
            shape.shadowOffset = .zero
            shape.shadowRadius = 4
            shape.shadowOpacity = 0.9
        }
        highlightLines.fillColor = nil
        highlightLines.lineWidth = 1.1
        highlightLines.lineCap = .round
        highlightDots.fillColor = NSColor.white.cgColor
        layer?.addSublayer(container)
        if role == .panel {
            parallaxSubscription = Parallax.shared.$offset.sink { [weak self] offset in
                self?.parallax = offset
                self?.reposition(animated: true)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: CGImage?, frame: SkyFrame, frameKey: String, screen: CGSize, hovered: String?, twinkle: Bool, night: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if imageLayer.contents as! CGImage? !== image { imageLayer.contents = image }
        if self.screen != screen {
            self.screen = screen
            container.bounds = CGRect(origin: .zero, size: screen)
            for sub in [imageLayer, twinkleLayer, highlightLines, highlightDots] as [CALayer] { sub.frame = container.bounds }
        }
        let twinkleKey = "\(frameKey)|\(twinkle)|\(night)"
        if twinkleKey != builtTwinkleKey {
            builtTwinkleKey = twinkleKey
            buildTwinkle(frame: frame, twinkle: twinkle, night: night)
        }
        CATransaction.commit()
        if hovered != shownHighlight {
            shownHighlight = hovered
            showHighlight(hovered.flatMap { id in frame.constellations.first { $0.id == id } }?.segments, night: night)
        }
        reposition(animated: false)
    }

    /// Screen point (top-left origin) to container coordinates (bottom-left origin).
    private func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: screen.height - p.y) }

    private func buildTwinkle(frame: SkyFrame, twinkle: Bool, night: Bool) {
        twinkleLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard twinkle else { return }
        let ink = NSColor(SkyPainter.ink(night: night)).cgColor
        let now = CACurrentMediaTime()
        for (i, star) in frame.stars.enumerated() where star.mag < 2.6 {
            let r = SkyPainter.brightRadius(star.mag)
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            dot.cornerRadius = r
            dot.position = flip(star.p)
            dot.backgroundColor = night ? NSColor(star.color).cgColor : ink.copy(alpha: 0.55)
            let base = Float(star.fade)
            dot.opacity = base
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = base
            pulse.toValue = base * 0.62
            pulse.duration = 1.4 + Double((i * 37) % 19) / 10
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = now - Double((i * 53) % 31) / 10
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "twinkle")
            twinkleLayer.addSublayer(dot)
        }
    }

    private func showHighlight(_ segments: [(CGPoint, CGPoint)]?, night: Bool) {
        let ink = night ? NSColor(red: 0.8, green: 0.88, blue: 1, alpha: 1) : NSColor(red: 0.18, green: 0.3, blue: 0.6, alpha: 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        if let segments {
            CATransaction.setDisableActions(true)
            let lines = CGMutablePath()
            for (a, b) in segments { lines.move(to: flip(a)); lines.addLine(to: flip(b)) }
            let dots = CGMutablePath()
            for p in SkyPainter.vertices(segments) {
                let q = flip(p)
                dots.addEllipse(in: CGRect(x: q.x - 1.8, y: q.y - 1.8, width: 3.6, height: 3.6))
            }
            highlightLines.path = lines
            highlightDots.path = dots
            highlightLines.strokeColor = ink.withAlphaComponent(0.9).cgColor
            highlightLines.shadowColor = ink.cgColor
            highlightDots.shadowColor = ink.cgColor
            CATransaction.setDisableActions(false)
        }
        let target: Float = segments == nil ? 0 : 1
        for shape in [highlightLines, highlightDots] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.presentation()?.opacity ?? shape.opacity
            fade.toValue = target
            fade.duration = 0.28
            shape.add(fade, forKey: "fade")
            shape.opacity = target
        }
        CATransaction.commit()
    }

    // MARK: Following the window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { stopFollowing(); return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willMoveNotification, object: window, queue: .main) { [weak self] _ in
            self?.startFollowing()
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.reposition(animated: false)
            })
        }
        reposition(animated: false)
    }

    override func layout() {
        super.layout()
        reposition(animated: false)
    }

    /// While the window is dragged, follow it on every display refresh.
    private func startFollowing() {
        quietTicks = 0
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopFollowing() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        reposition(animated: false)
        quietTicks = NSEvent.pressedMouseButtons == 0 ? quietTicks + 1 : 0
        if quietTicks > 20 { stopFollowing() }
    }

    private func reposition(animated: Bool) {
        guard let window, let screenFrame = (window.screen ?? NSScreen.main)?.frame else { return }
        if screenFrame.size != screen { onScreenChange?(screenFrame.size) }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        origin = CGPoint(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY)
        if role == .panel { MainActor.assumeIsolated { SkyModel.shared.panelOrigin = origin } }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        container.position = CGPoint(x: -origin.x + parallax.width,
                                     y: bounds.height - screen.height + origin.y - parallax.height)
        CATransaction.commit()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        link?.invalidate()
    }
}

private struct SkyDateKey: EnvironmentKey { static let defaultValue: Date? = nil }

extension EnvironmentValues {
    /// A fixed moment for the sky, used by snapshot renders.
    var skyDate: Date? {
        get { self[SkyDateKey.self] }
        set { self[SkyDateKey.self] = newValue }
    }
}

// MARK: - Moon phase

/// Tonight's real Moon phase, for the empty and welcome states.
struct MoonPhaseView: View {
    var size: CGFloat = 44
    @Environment(\.skyDate) private var fixedDate

    var body: some View {
        let moon = Astronomy.moon(fixedDate ?? Date())
        let phase = MoonPhaseView.name(illuminated: moon.illuminated, waxing: moon.waxing)
        VStack(spacing: 6) {
            MoonDisc(illuminated: moon.illuminated, waxing: moon.waxing)
                .frame(width: size, height: size)
                .shadow(color: Color(red: 0.8, green: 0.87, blue: 1).opacity(0.35 + 0.3 * moon.illuminated), radius: 14)
            Text("\(phase.name) · \(Int((moon.illuminated * 100).rounded()))% lit")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tonight's Moon: \(phase.name)")
    }

    static func name(illuminated k: Double, waxing: Bool) -> (name: String, symbol: String) {
        switch k {
        case ..<0.03: return ("New moon", "moonphase.new.moon")
        case ..<0.40: return waxing ? ("Waxing crescent", "moonphase.waxing.crescent") : ("Waning crescent", "moonphase.waning.crescent")
        case ..<0.60: return waxing ? ("First quarter", "moonphase.first.quarter") : ("Last quarter", "moonphase.last.quarter")
        case ..<0.97: return waxing ? ("Waxing gibbous", "moonphase.waxing.gibbous") : ("Waning gibbous", "moonphase.waning.gibbous")
        default: return ("Full moon", "moonphase.full.moon")
        }
    }
}

/// A Moon drawn from its illuminated fraction: lit on the right while waxing, on the left while waning
/// (as seen from the northern hemisphere).
struct MoonDisc: View {
    let illuminated: Double
    let waxing: Bool

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let light = Color(red: 0.95, green: 0.96, blue: 0.99)
            let dark = Color(red: 0.22, green: 0.25, blue: 0.32)
            ctx.fill(disc, with: .color(dark))
            var lit = ctx
            lit.clip(to: disc)
            lit.translateBy(x: c.x, y: c.y)
            if !waxing { lit.scaleBy(x: -1, y: 1) }
            var half = Path()
            half.addArc(center: .zero, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            half.closeSubpath()
            lit.fill(half, with: .color(light))
            let w = r * CGFloat(abs(1 - 2 * illuminated))
            let terminator = Path(ellipseIn: CGRect(x: -w, y: -r, width: w * 2, height: r * 2))
            lit.fill(terminator, with: .color(illuminated >= 0.5 ? light : dark))
            ctx.stroke(disc, with: .color(.white.opacity(0.25)), lineWidth: 0.75)
        }
    }
}

// MARK: - Stargaze mode

/// Stargaze mode: the UI steps aside and constellations can be explored by pointing at them.
@MainActor
final class SkyModel: ObservableObject {
    static let shared = SkyModel()

    /// Stargaze doubles as Do Not Disturb: while it's on, no banners are posted. It survives closing the
    /// panel and quitting, and ends with a click on the sky or from the menu-bar item's right-click menu.
    @Published var stargazing = UserDefaults.standard.bool(forKey: "stargazing") {
        didSet { UserDefaults.standard.set(stargazing, forKey: "stargazing") }
    }
    @Published var hovered: String?
    /// Where the panel's sky sits on the screen, for turning pointer positions into sky positions.
    var panelOrigin: CGPoint = .zero
    /// The sky as last drawn, for hit-testing the pointer.
    private(set) var frame: SkyFrame?
    private var frameKey: String?

    /// The sky for this minute, place and size; reused until one of them changes, so hovering stays cheap.
    static let imageScale: CGFloat = 2
    private var imageKey: String?
    private var cachedImage: CGImage?
    var frameKeyValue: String { frameKey ?? "" }

    /// The screen's sky painted once for this minute and these settings.
    func image(frame: SkyFrame, screen: CGSize, night: Bool, lines: Bool, dim: Bool, brightCores: Bool) -> CGImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? SkyModel.imageScale
        let key = "\(frameKey ?? "")|\(night)|\(lines)|\(dim)|\(brightCores)|\(scale)"
        if key == imageKey, let cachedImage { return cachedImage }
        cachedImage = SkyPainter.image(frame: frame, screen: screen, night: night, lines: lines, dim: dim,
                                       brightCores: brightCores, scale: scale)
        imageKey = key
        return cachedImage
    }

    func frame(date: Date, latitude: Double, longitude: Double, size: CGSize) -> SkyFrame {
        let key = "\(Int(date.timeIntervalSince1970 / 60))|\(latitude)|\(longitude)|\(Int(size.width))x\(Int(size.height))"
        if key == frameKey, let frame { return frame }
        let made = SkyFrame.make(date: date, latitude: latitude, longitude: longitude, size: size)
        frame = made
        frameKey = key
        return made
    }

    /// The constellation whose lines pass closest to the point, if any are within reach.
    func constellation(at point: CGPoint, reach: CGFloat = 22) -> String? {
        guard let frame else { return nil }
        var best: (id: String, distance: CGFloat)?
        for constellation in frame.constellations {
            for (a, b) in constellation.segments {
                let d = SkyModel.distance(point, a, b)
                if d < reach, d < (best?.distance ?? .infinity) { best = (constellation.id, d) }
            }
        }
        return best?.id
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    func leave() {
        hovered = nil
        stargazing = false
    }
}

/// The 88 constellations by their IAU abbreviations.
enum ConstellationNames {
    static let all: [String: String] = [
        "And": "Andromeda", "Ant": "Antlia", "Aps": "Apus", "Aqr": "Aquarius", "Aql": "Aquila", "Ara": "Ara",
        "Ari": "Aries", "Aur": "Auriga", "Boo": "Boötes", "Cae": "Caelum", "Cam": "Camelopardalis", "Cnc": "Cancer",
        "CVn": "Canes Venatici", "CMa": "Canis Major", "CMi": "Canis Minor", "Cap": "Capricornus", "Car": "Carina",
        "Cas": "Cassiopeia", "Cen": "Centaurus", "Cep": "Cepheus", "Cet": "Cetus", "Cha": "Chamaeleon", "Cir": "Circinus",
        "Col": "Columba", "Com": "Coma Berenices", "CrA": "Corona Australis", "CrB": "Corona Borealis", "Crv": "Corvus",
        "Crt": "Crater", "Cru": "Crux", "Cyg": "Cygnus", "Del": "Delphinus", "Dor": "Dorado", "Dra": "Draco",
        "Equ": "Equuleus", "Eri": "Eridanus", "For": "Fornax", "Gem": "Gemini", "Gru": "Grus", "Her": "Hercules",
        "Hor": "Horologium", "Hya": "Hydra", "Hyi": "Hydrus", "Ind": "Indus", "Lac": "Lacerta", "Leo": "Leo",
        "LMi": "Leo Minor", "Lep": "Lepus", "Lib": "Libra", "Lup": "Lupus", "Lyn": "Lynx", "Lyr": "Lyra",
        "Men": "Mensa", "Mic": "Microscopium", "Mon": "Monoceros", "Mus": "Musca", "Nor": "Norma", "Oct": "Octans",
        "Oph": "Ophiuchus", "Ori": "Orion", "Pav": "Pavo", "Peg": "Pegasus", "Per": "Perseus", "Phe": "Phoenix",
        "Pic": "Pictor", "Psc": "Pisces", "PsA": "Piscis Austrinus", "Pup": "Puppis", "Pyx": "Pyxis",
        "Ret": "Reticulum", "Sge": "Sagitta", "Sgr": "Sagittarius", "Sco": "Scorpius", "Scl": "Sculptor",
        "Sct": "Scutum", "Ser": "Serpens", "Sex": "Sextans", "Tau": "Taurus", "Tel": "Telescopium",
        "Tri": "Triangulum", "TrA": "Triangulum Australe", "Tuc": "Tucana", "UMa": "Ursa Major",
        "UMi": "Ursa Minor", "Vel": "Vela", "Vir": "Virgo", "Vol": "Volans", "Vul": "Vulpecula",
    ]
}

/// Covers the panel while stargazing: points at constellations, shows the name, and returns on a click.
struct StargazeOverlay: View {
    @ObservedObject private var sky = SkyModel.shared
    @State private var hintVisible = true

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    let id = sky.constellation(at: Parallax.shared.skyPoint(fromPanel: point))
                    if id != sky.hovered { sky.hovered = id }
                case .ended:
                    sky.hovered = nil
                }
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.45)) { sky.leave() } }
            .overlay(alignment: .topLeading) {
                if let id = sky.hovered, let name = ConstellationNames.all[id] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .foregroundStyle(Theme.starlight)
                    }
                    .padding(.top, 20)
                    .padding(.leading, Spacing.gutter + 4)
                    .id(id)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                Text("Alerts are off · point at a constellation · click anywhere to return")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.bottom, 18)
                    .opacity(hintVisible ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.3), value: sky.hovered)
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.8)) { hintVisible = false }
            }
            .accessibilityElement()
            .accessibilityLabel("Stargazing, alerts off. Click to return.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { sky.leave() }
    }
}

// MARK: - Parallax

/// The sky drifts a few points against the pointer, as if seen through a window. Kept apart from SkyModel
/// so pointer movement never redraws the stars, only moves them.
@MainActor
final class Parallax: ObservableObject {
    static let shared = Parallax()
    /// How far the sky layer extends past the panel on each side, so drifting never shows an edge.
    static let bleed: CGFloat = 0
    static let reach: CGFloat = 5

    @Published private(set) var offset: CGSize = .zero

    func track(_ point: CGPoint?, in size: CGSize) {
        guard let point, size.width > 0, size.height > 0 else { offset = .zero; return }
        let nx = (point.x / size.width - 0.5) * 2, ny = (point.y / size.height - 0.5) * 2
        offset = CGSize(width: -nx * Parallax.reach, height: -ny * Parallax.reach * 0.6)
    }

    /// A point in the panel, in the sky layer's own coordinates.
    func skyPoint(fromPanel p: CGPoint) -> CGPoint {
        let origin = SkyModel.shared.panelOrigin
        return CGPoint(x: p.x + Parallax.bleed - offset.width + origin.x, y: p.y + Parallax.bleed - offset.height + origin.y)
    }
}

/// The panel's background. Parallax is applied inside the sky layer itself, which is larger than the panel
/// (it spans the screen), so drifting never shows an edge.
struct ParallaxSky: View {
    var body: some View { SpaceBackground() }
}

// MARK: - Where a window sits on its screen

/// A window's slice of the screen-wide sky: the screen's size and where the sky view's top-left corner is on it.
struct SkyViewport: Equatable {
    var screen: CGSize
    var origin: CGPoint

    /// Before the window reports its position: centred on the main screen.
    @MainActor static func guess(for size: CGSize) -> SkyViewport {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        return SkyViewport(screen: screen, origin: CGPoint(x: (screen.width - size.width) / 2, y: 40))
    }
}

enum SkyRole { case panel, other }

private struct SkyViewportKey: EnvironmentKey { static let defaultValue: SkyViewport? = nil }
private struct SkyRoleKey: EnvironmentKey { static let defaultValue: SkyRole = .other }

extension EnvironmentValues {
    /// A fixed viewport for snapshot renders.
    var skyViewport: SkyViewport? {
        get { self[SkyViewportKey.self] }
        set { self[SkyViewportKey.self] = newValue }
    }

    var skyRole: SkyRole {
        get { self[SkyRoleKey.self] }
        set { self[SkyRoleKey.self] = newValue }
    }
}

/// Reports where this view is on its screen, live while the window moves or resizes.
struct SkyViewportReader: NSViewRepresentable {
    let onChange: (SkyViewport) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((SkyViewport) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: SkyViewport?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func report() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            let viewport = SkyViewport(screen: screen.frame.size,
                                       origin: CGPoint(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY))
            guard viewport != last else { return }
            last = viewport
            DispatchQueue.main.async { [onChange] in onChange?(viewport) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
