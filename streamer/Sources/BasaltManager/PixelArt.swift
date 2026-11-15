import SwiftUI

struct PixelBitmap {
    let rows: [String]

    init(_ rows: [String]) {
        precondition(!rows.isEmpty && rows.allSatisfy { $0.count == rows[0].count })
        self.rows = rows
    }

    func path(in rect: CGRect) -> Path {
        let cell = CGSize(width: rect.width / CGFloat(rows[0].count),
                          height: rect.height / CGFloat(rows.count))
        return Path { path in
            for (y, row) in rows.enumerated() {
                for (x, pixel) in row.enumerated() where pixel == "#" {
                    path.addRect(CGRect(
                        x: rect.minX + CGFloat(x) * cell.width,
                        y: rect.minY + CGFloat(y) * cell.height,
                        width: cell.width, height: cell.height))
                }
            }
        }
    }
}

enum PixelGlyph: CaseIterable {
    case library, steam, stream, headset, bottles, setup, settings, diagnostics
    case learning
    case dot, check, play, sun
    case warning, minus

    var bitmap: PixelBitmap {
        switch self {
        case .library:
            return PixelBitmap([
                "............", "............", "...#....#...", "..########..",
                ".##########.", "##.######.##", "#...####.#.#", "##.######.##",
                "############", "###......###", ".#........#.", "............"
            ])
        case .steam:
            return PixelBitmap([
                ".....##.....", ".....##.....", ".....##.....", ".....##.....",
                "..########..", "...######...", "....####....", ".....##.....",
                "#..........#", "#..........#", "############", "............"
            ])
        case .stream:
            return PixelBitmap([
                "............", "..#......#..", ".#..#..#..#.", "#..#....#..#",
                "#.#..##..#.#", "#.#.####.#.#", "#.#.####.#.#", "#.#..##..#.#",
                "#..#....#..#", ".#..#..#..#.", "..#......#..", "............"
            ])
        case .headset:
            return PixelBitmap([
                "....####....", "...#....#...", "..#......#..", ".##########.",
                "############", "##..####..##", "#....##....#", "#....##....#",
                "##..####..##", "############", ".####..####.", "............"
            ])
        case .bottles:
            return PixelBitmap([
                ".....##.....", "...##..##...", ".##......##.", "#..##..##..#",
                "#....##....#", "#.....#....#", "#.....#....#", "#.....#....#",
                "#.....#....#", ".##...#..##.", "...##.#.##..", ".....##....."
            ])
        case .setup:
            return PixelBitmap([
                ".###..#####.", ".#.#........", ".###..####..", "............",
                ".....#......", "#...#.#####.", ".#.#........", "..#...####..",
                "............", ".###..#####.", ".#.#........", ".###..####.."
            ])
        case .settings:
            return PixelBitmap([
                ".....##.....", "..#.####.#..", ".##########.", "..###..###..",
                ".###....###.", "####....####", "####....####", ".###....###.",
                "..###..###..", ".##########.", "..#.####.#..", ".....##....."
            ])
        case .diagnostics:
            return PixelBitmap([
                "............", "......#.....", "......#.....", ".....###....",
                ".....#.#....", "####.#.#.###", "...###.#.#..", "....#..###..",
                "........#...", "........#...", "............", "............"
            ])
        case .learning:
            // An open book.
            return PixelBitmap([
                "............", ".####..####.", "#....##....#", "#.##.##.##.#",
                "#....##....#", "#.##.##.##.#", "#....##....#", "#.##.##.##.#",
                "#....##....#", "############", ".....##.....", "............"
            ])
        case .dot:
            return PixelBitmap([".##.", "####", "####", ".##."])
        case .check:
            return PixelBitmap([
                "........", ".......#", "......##", "#....##.",
                "##..##..", ".####...", "..##....", "........"
            ])
        case .warning:
            return PixelBitmap([
                "...##...", "...##...", "...##...", "...##...",
                "...##...", "........", "...##...", "...##..."
            ])
        case .minus:
            return PixelBitmap([
                "........", "........", "........", ".######.",
                ".######.", "........", "........", "........"
            ])
        case .play:
            return PixelBitmap([
                "##......", "####....", "######..", "########",
                "########", "######..", "####....", "##......"
            ])
        case .sun:
            return PixelBitmap([
                "..####..", ".######.", "########", "########",
                "########", "########", ".######.", "..####.."
            ])
        }
    }
}

struct PixelIcon: View {
    let glyph: PixelGlyph
    var size: CGFloat = TB.Size.navIcon
    var color: Color = TB.iconIdle

    var body: some View {
        glyph.bitmap.path(in: CGRect(x: 0, y: 0, width: size, height: size))
            .fill(color, style: FillStyle(antialiased: false))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct HeroSunset: View {
    @Environment(\.colorSchemeContrast) private var contrast

    private static let hills = [
        1, 1, 2, 2, 3, 3, 4, 5, 5, 6, 6, 7, 7, 6, 6, 5, 4, 4, 3, 3,
        3, 4, 4, 5, 6, 7, 8, 8, 9, 8, 8, 7, 6, 5, 5, 4, 4, 4, 5, 5,
        6, 6, 7, 7, 7, 6, 6, 5, 5, 6, 7, 8, 8, 7, 6, 5, 4, 3, 2, 2
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if contrast != .increased {
                ZStack(alignment: .topLeading) {
                    PixelGlyph.sun.bitmap.path(in: CGRect(x: 240, y: 12, width: 48, height: 48))
                        .fill(TB.heroSun, style: FillStyle(antialiased: false))
                    Path { path in
                        for (x, height) in Self.hills.enumerated() {
                            path.addRect(CGRect(x: x * 6, y: (14 - height) * 6,
                                                width: 6, height: height * 6))
                        }
                    }
                    .fill(TB.heroHills, style: FillStyle(antialiased: false))
                }
                .frame(width: 360, height: 84)
                .opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PixelSparkline: View {
    let samples: [Double]
    let reference: Double
    var waitingText: String? = nil

    var body: some View {
        GeometryReader { geometry in
            let values = Array(samples.suffix(24)).map { $0.isFinite ? max(0, $0) : 0 }
            let maximum = max(reference.isFinite ? reference : 0, values.max() ?? 0)
            let ceiling = maximum > 0 ? maximum : 1
            ZStack {
                Path { path in
                    let unit = CGSize(width: geometry.size.width / 72, height: geometry.size.height / 26)
                    if values.isEmpty {
                        for x in stride(from: 0, to: 72, by: 3) {
                            path.addRect(CGRect(x: CGFloat(x) * unit.width, y: 25 * unit.height,
                                                width: unit.width, height: unit.height))
                        }
                    } else {
                        for (index, value) in values.enumerated() {
                            let height = value / ceiling * 26
                            path.addRect(CGRect(x: CGFloat(index * 3) * unit.width,
                                                y: (26 - height) * unit.height,
                                                width: 2 * unit.width, height: height * unit.height))
                        }
                    }
                }
                .fill(values.isEmpty ? TB.textSecondary : TB.lavaText,
                      style: FillStyle(antialiased: false))
                .accessibilityHidden(true)
                if values.isEmpty, let waitingText {
                    Text(waitingText)
                        .font(TB.Typography.caption)
                        .foregroundStyle(TB.textSecondary)
                        .lineLimit(1)
                        .help(waitingText)
                }
            }
        }
        .frame(height: 26)
    }
}

private struct PixelBlink: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.8)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.8)
                content.opacity(step.isMultiple(of: 2) ? 1 : 0.3)
                    .transaction { $0.animation = nil }
            }
        } else {
            content
        }
    }
}

extension View {
    func tbBlink(_ enabled: Bool = true) -> some View {
        modifier(PixelBlink(enabled: enabled))
    }
}
