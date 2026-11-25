import SwiftUI
import AppKit

final class CompanionState: ObservableObject {
    enum Mode { case sleeping, ready, listening, working, problem }
    @Published var mode: Mode = .sleeping
    var drag: ((CGSize, Bool) -> Void)?

}

struct SpiritShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        p.move(to: point(0.08, 0.67))
        p.addCurve(to: point(0.18, 0.23), control1: point(0.02, 0.48), control2: point(0.07, 0.31))
        p.addCurve(to: point(0.53, 0.10), control1: point(0.27, 0.12), control2: point(0.42, 0.08))
        p.addCurve(to: point(0.85, 0.28), control1: point(0.72, 0.08), control2: point(0.82, 0.17))
        p.addCurve(to: point(0.92, 0.71), control1: point(0.94, 0.39), control2: point(0.98, 0.61))
        p.addCurve(to: point(0.75, 0.89), control1: point(0.89, 0.83), control2: point(0.82, 0.94))
        p.addCurve(to: point(0.57, 0.86), control1: point(0.69, 0.85), control2: point(0.65, 0.82))
        p.addCurve(to: point(0.37, 0.90), control1: point(0.49, 0.94), control2: point(0.43, 0.95))
        p.addCurve(to: point(0.08, 0.67), control1: point(0.25, 0.85), control2: point(0.13, 0.86))
        p.closeSubpath()
        return p
    }
}

struct CompanionView: View {
    @ObservedObject var state: CompanionState
    @State private var breathe = false
    @State private var blink = false
    private let ink = Color(red: 0.18, green: 0.23, blue: 0.23)
    private let mint = Color(red: 0.52, green: 0.80, blue: 0.68)
    private var listening: Bool { state.mode == .listening }

    var body: some View {
        VStack(spacing: 0) {
            Text("随叫，随到。")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(ink.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(red: 0.99, green: 0.98, blue: 0.94).opacity(0.96), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.65), lineWidth: 1))
                .padding(.top, 8)

            ZStack {
                Ellipse().fill(.black.opacity(0.12)).frame(width: breathe ? 106 : 90, height: 12)
                    .blur(radius: 7).offset(y: 83)
                ZStack {
                    SpiritShape()
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.99, blue: 0.94), Color(red: 0.90, green: 0.87, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(SpiritShape().stroke(.white.opacity(0.90), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.14), radius: 13, x: 4, y: 12)
                    Ellipse().fill(.white.opacity(0.6)).frame(width: 55, height: 15).blur(radius: 5).rotationEffect(.degrees(-28)).offset(x: -36, y: -52)
                    HStack(spacing: 32) {
                        eye
                        eye
                    }.offset(y: -4)
                    HStack(spacing: 64) {
                        Ellipse().fill(Color(red: 0.96, green: 0.66, blue: 0.58).opacity(0.38)).frame(width: 23, height: 10)
                        Ellipse().fill(Color(red: 0.96, green: 0.66, blue: 0.58).opacity(0.38)).frame(width: 23, height: 10)
                    }.blur(radius: 3).offset(y: 15)
                    if listening {
                        HStack(alignment: .center, spacing: 4) {
                            ForEach(0..<5) { i in
                                Capsule().fill(ink.opacity(0.65)).frame(width: 3, height: breathe ? CGFloat([9, 19, 13, 23, 10][i]) : CGFloat([16, 8, 21, 10, 17][i]))
                            }
                        }.offset(y: 31)
                    } else {
                        Path { p in
                            p.move(to: CGPoint(x: 85, y: 108))
                            p.addQuadCurve(to: CGPoint(x: 99, y: 108), control: CGPoint(x: 92, y: 118))
                        }.stroke(ink.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    Circle().fill(listening ? mint : .white.opacity(0.7)).frame(width: 9, height: 9)
                        .shadow(color: mint.opacity(listening ? 0.7 : 0), radius: 9).offset(x: 59, y: -52)
                }
                .frame(width: 184, height: 190)
                .scaleEffect(x: breathe ? 1.015 : 0.995, y: breathe ? 1.025 : 0.985, anchor: .bottom)
                .offset(y: breathe ? -4 : 1)
            }
            .frame(width: 230, height: 205)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { state.drag?($0.translation, false) }
                .onEnded { state.drag?($0.translation, true) })
            .help("拖动小精灵，换一个位置")

        }
        .frame(width: 250, height: 270, alignment: .top)
        .onAppear { withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { breathe = true } }
        .onReceive(Timer.publish(every: 4.7, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.easeInOut(duration: 0.08)) { blink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { withAnimation { blink = false } }
        }
    }

    private var eye: some View {
        Capsule().fill(ink).frame(width: 12, height: blink ? 3 : (listening ? 19 : 16))
            .overlay(alignment: .topLeading) {
                if !blink { Circle().fill(.white.opacity(0.8)).frame(width: 3, height: 3).offset(x: 3, y: 3) }
            }
    }
}

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
