import SwiftUI

/// Launch animation: a building goes up floor by floor while a crane sets each one,
/// the windows light up, a flag goes on top and the brand fades in. Adapts to Light
/// and Dark (night) appearance, and respects Reduce Motion (shows the finished scene).
struct LaunchBuildingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let floorCount = 5
    private let floorHeight: CGFloat = 24
    private let floorGap: CGFloat = 5
    private let groundY: CGFloat = 232
    private let buildingX: CGFloat = 112
    private let buildingWidth: CGFloat = 112
    private let craneX: CGFloat = 206
    private let craneTopY: CGFloat = 34

    @State private var ground: CGFloat = 0
    @State private var mast: CGFloat = 0
    @State private var jib = false
    @State private var placed = [Bool](repeating: false, count: LaunchBuildingView.floorCount)
    @State private var lit = [Bool](repeating: false, count: LaunchBuildingView.floorCount)
    @State private var flag = false
    @State private var sway = false
    @State private var brand = false

    private var floorColor: Color { Color(light: 0xB9B9C0, dark: 0x3A3A3C) }
    private var windowLit: Color { Color(light: 0x6E9BC9, dark: 0xFFC857) }     // night: warm lit windows
    private var windowOff: Color { Color(light: 0x9C9CA3, dark: 0x2A2A2D) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 26) {
                scene.frame(width: 280, height: 270)
                VStack(spacing: 6) {
                    Text("BuildSight").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                    Text("Capture the site. Know the story.").font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                .opacity(brand ? 1 : 0)
                .offset(y: brand ? 0 : 14)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading BuildSight")
        .onAppear(perform: start)
    }

    private var scene: some View {
        ZStack {
            // Ground line draws in from the left.
            Path { p in p.move(to: CGPoint(x: 0, y: groundY)); p.addLine(to: CGPoint(x: 280, y: groundY)) }
                .trim(from: 0, to: ground)
                .stroke(Theme.text.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Floors: each one drops in from above and settles with a spring.
            ForEach(0..<Self.floorCount, id: \.self) { i in
                let top = groundY - CGFloat(i + 1) * (floorHeight + floorGap)
                VStack(spacing: 6) {
                    HStack(spacing: 9) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(lit[i] ? windowLit : windowOff).frame(width: 13, height: 11)
                        }
                    }
                }
                .frame(width: buildingWidth, height: floorHeight)
                .background(floorColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .position(x: buildingX, y: top + floorHeight / 2)
                .offset(y: placed[i] ? 0 : -190)
                .opacity(placed[i] ? 1 : 0)
            }

            // Flag on the roof.
            let roofY = groundY - CGFloat(Self.floorCount) * (floorHeight + floorGap)
            Path { p in
                p.move(to: CGPoint(x: buildingX, y: roofY))
                p.addLine(to: CGPoint(x: buildingX, y: roofY - 38))
            }
            .stroke(Theme.text.opacity(0.6), lineWidth: 2)
            Path { p in
                p.move(to: CGPoint(x: buildingX, y: roofY - 38))
                p.addLine(to: CGPoint(x: buildingX + 26, y: roofY - 31))
                p.addLine(to: CGPoint(x: buildingX, y: roofY - 24))
                p.closeSubpath()
            }
            .fill(Theme.accent)
            .opacity(flag ? 1 : 0)
            .offset(y: flag ? 0 : 8)

            // Crane: mast rises, then the jib swings in and the hook sways.
            Rectangle().fill(Theme.text.opacity(0.55))
                .frame(width: 7, height: groundY - craneTopY)
                .position(x: craneX, y: (groundY + craneTopY) / 2)
                .scaleEffect(y: mast, anchor: .bottom)
            Rectangle().fill(Theme.text.opacity(0.55))
                .frame(width: 150, height: 7)
                .position(x: craneX - 40, y: craneTopY)
                .scaleEffect(x: jib ? 1 : 0.2, anchor: .trailing)
                .opacity(jib ? 1 : 0)
            Rectangle().fill(Theme.text.opacity(0.5))
                .frame(width: 1.5, height: 46)
                .position(x: craneX - 90, y: craneTopY + 23)
                .offset(x: sway ? 3 : -3)
                .opacity(jib ? 1 : 0)
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                .frame(width: 10, height: 8)
                .position(x: craneX - 90, y: craneTopY + 48)
                .offset(x: sway ? 3 : -3)
                .opacity(jib ? 1 : 0)
        }
    }

    private func start() {
        if reduceMotion {
            ground = 1; mast = 1; jib = true; flag = true; brand = true
            for i in 0..<Self.floorCount { placed[i] = true; lit[i] = true }
            return
        }
        withAnimation(.easeOut(duration: 0.6)) { ground = 1 }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.3)) { mast = 1 }
        withAnimation(.easeOut(duration: 0.45).delay(0.9)) { jib = true }
        for i in 0..<Self.floorCount {
            let t = 1.3 + Double(i) * 0.5
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(t)) { placed[i] = true }
            withAnimation(.easeOut(duration: 0.25).delay(t + 0.3)) { lit[i] = true }
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.45).delay(4.0)) { flag = true }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(1.5)) { sway = true }
        withAnimation(.easeOut(duration: 0.7).delay(4.1)) { brand = true }
    }
}
