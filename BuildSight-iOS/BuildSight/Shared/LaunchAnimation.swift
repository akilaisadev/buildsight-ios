import SwiftUI

/// One architectural mark for the icon, launch screen and sign-in screen.
struct BrandMark: View {
    var reveal: CGFloat = 1
    var illuminated = true

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x2B3440), Color(hex: 0x10161D)], startPoint: .topLeading, endPoint: .bottomTrailing))

                building(in: side)
                    .mask {
                        Rectangle()
                            .frame(width: side, height: side * reveal)
                            .offset(y: side * (1 - reveal) / 2)
                    }

                if reveal > 0 && reveal < 1 {
                    Rectangle().fill(Theme.accent)
                        .frame(width: side * 0.57, height: max(2, side * 0.013))
                        .shadow(color: Theme.accent.opacity(0.8), radius: side * 0.035)
                        .position(x: side * 0.52, y: side * (0.81 - 0.60 * reveal))
                }
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }

    private func building(in side: CGFloat) -> some View {
        ZStack {
            Path { path in
                path.move(to: point(0.25, 0.29, side))
                path.addLine(to: point(0.39, 0.20, side))
                path.addLine(to: point(0.80, 0.20, side))
                path.addLine(to: point(0.66, 0.29, side))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [Theme.accent, Color(hex: 0xFF9B45)], startPoint: .leading, endPoint: .trailing))

            Path { path in
                path.move(to: point(0.66, 0.29, side))
                path.addLine(to: point(0.80, 0.20, side))
                path.addLine(to: point(0.80, 0.72, side))
                path.addLine(to: point(0.66, 0.81, side))
                path.closeSubpath()
            }
            .fill(Color(hex: 0x26343E))

            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: 0x495A66), Color(hex: 0x273640)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: side * 0.41, height: side * 0.52)
                .position(x: side * 0.455, y: side * 0.55)

            ForEach(0..<4, id: \.self) { floor in
                let y = side * (0.355 + CGFloat(floor) * 0.137)
                Path { path in
                    path.move(to: CGPoint(x: side * 0.25, y: y))
                    path.addLine(to: CGPoint(x: side * 0.66, y: y))
                    path.addLine(to: CGPoint(x: side * 0.80, y: y - side * 0.09))
                }
                .stroke(Color(hex: 0xE7EDF0), style: StrokeStyle(lineWidth: side * 0.018, lineCap: .square, lineJoin: .miter))
            }

            ForEach(0..<3, id: \.self) { row in
                ForEach(0..<3, id: \.self) { column in
                    let isLit = illuminated && ((row == 0 && column == 2) || (row == 2 && column == 0))
                    RoundedRectangle(cornerRadius: side * 0.006, style: .continuous)
                        .fill(isLit ? Theme.accent : Color(hex: 0x15232D))
                        .frame(width: side * 0.068, height: side * 0.075)
                        .position(x: side * (0.325 + CGFloat(column) * 0.113), y: side * (0.407 + CGFloat(row) * 0.137))
                }
            }

            Path { path in
                path.move(to: point(0.25, 0.29, side))
                path.addLine(to: point(0.25, 0.81, side))
                path.addLine(to: point(0.66, 0.81, side))
                path.addLine(to: point(0.80, 0.72, side))
            }
            .stroke(Color(hex: 0xE7EDF0), style: StrokeStyle(lineWidth: side * 0.013, lineCap: .square, lineJoin: .miter))
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGPoint {
        CGPoint(x: x * side, y: y * side)
    }
}

struct LaunchBuildingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0
    @State private var illuminated = false
    @State private var showTitle = false

    var body: some View {
        ZStack {
            Color(hex: 0x10161D).ignoresSafeArea()
            VStack(spacing: 24) {
                BrandMark(reveal: reveal, illuminated: illuminated)
                    .frame(width: 124, height: 124)
                    .shadow(color: Color.black.opacity(0.22), radius: 26, y: 12)
                VStack(spacing: 5) {
                    Text("BuildSight").font(.system(size: 31, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("A clearer view of every site.").font(.subheadline).foregroundStyle(Color(hex: 0xAEB8C2))
                }
                .opacity(showTitle ? 1 : 0)
                .offset(y: showTitle ? 0 : 8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading BuildSight")
        .onAppear {
            if reduceMotion { reveal = 1; illuminated = true; showTitle = true }
            else {
                withAnimation(.easeOut(duration: 0.85)) { reveal = 1 }
                withAnimation(.easeOut(duration: 0.35).delay(0.48)) { showTitle = true }
                withAnimation(.easeInOut(duration: 0.28).delay(0.67)) { illuminated = true }
            }
        }
    }
}
