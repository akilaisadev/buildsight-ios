import SwiftUI

/// The app logo on a white rounded tile, the same framing as the app icon. Used on the sign-in screen.
struct BrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Color.white
                Image("BrandLogo").resizable().scaledToFit().scaleEffect(1.18)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

/// Launch animation: the logo springs in, ripples pulse out from it, a light sweeps across
/// its shape, the name rises in letter by letter and a progress bar fills. Always on a white
/// canvas (the logo's black ribbon needs it), matching the launch background and the icon.
/// With Reduce Motion on it shows the finished frame.
struct LaunchBuildingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appear = false
    @State private var ripple = false
    @State private var ripple2 = false
    @State private var shine: CGFloat = -1
    @State private var letters = false
    @State private var progress: CGFloat = 0
    @State private var float = false

    private let name = Array("BuildSight")
    private let ink = Color(hex: 0x1C1C1E)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 30) {
                ZStack {
                    ripples
                    logo
                }
                .frame(width: 230, height: 230)

                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(Array(name.enumerated()), id: \.offset) { index, letter in
                            Text(String(letter))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(index < 5 ? ink : Theme.accent)
                                .opacity(letters ? 1 : 0)
                                .offset(y: letters ? 0 : 16)
                                .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(Double(index) * 0.04), value: letters)
                        }
                    }
                    Text("A clearer view of every site.")
                        .font(.subheadline).foregroundStyle(Color(hex: 0x6B6B70))
                        .opacity(letters ? 1 : 0)
                        .animation(.easeOut(duration: 0.5).delay(0.5), value: letters)
                }

                Capsule().fill(Color.black.opacity(0.08))
                    .frame(width: 150, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [Theme.accent, Color(hex: 0xFF8A3D)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 150 * progress, height: 5)
                    }
                    .opacity(appear ? 1 : 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading BuildSight")
        .onAppear(perform: start)
    }

    private var logo: some View {
        Image("BrandLogo").resizable().scaledToFit()
            .frame(width: 200, height: 200)
            .overlay {
                // A soft diagonal band of light, clipped to the logo's own shape.
                LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70).rotationEffect(.degrees(20)).offset(x: shine * 150)
                    .mask { Image("BrandLogo").resizable().scaledToFit() }
            }
            .scaleEffect(appear ? 1 : 0.5)
            .rotation3DEffect(.degrees(appear ? 0 : -30), axis: (x: 0, y: 1, z: 0))
            .blur(radius: appear ? 0 : 14)
            .opacity(appear ? 1 : 0)
            .offset(y: float ? -5 : 5)
            .shadow(color: Theme.accent.opacity(0.25), radius: 24, y: 12)
    }

    private var ripples: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.45), lineWidth: 2)
                .scaleEffect(ripple ? 1.15 : 0.45).opacity(ripple ? 0 : 0.9)
            Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 1.5)
                .scaleEffect(ripple2 ? 1.15 : 0.45).opacity(ripple2 ? 0 : 0.9)
        }
        .frame(width: 230, height: 230)
    }

    private func start() {
        if reduceMotion {
            appear = true; letters = true; progress = 1
            return
        }
        withAnimation(.spring(response: 0.85, dampingFraction: 0.62)) { appear = true }
        withAnimation(.easeOut(duration: 1.2).delay(0.25)) { ripple = true }
        withAnimation(.easeOut(duration: 1.2).delay(0.6)) { ripple2 = true }
        withAnimation(.easeInOut(duration: 0.9).delay(0.8)) { shine = 1 }
        withAnimation(.easeOut(duration: 0.1).delay(0.7)) { letters = true }
        withAnimation(.linear(duration: 2.2).delay(0.3)) { progress = 1 }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(1.0)) { float = true }
    }
}
