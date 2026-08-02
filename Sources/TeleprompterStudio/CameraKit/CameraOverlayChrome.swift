import CoreMotion
import Observation
import SwiftUI

/// Rule-of-thirds grid overlay.
struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            let cols = 3, rows = 3
            var path = Path()
            for i in 1..<cols {
                let x = size.width * CGFloat(i) / CGFloat(cols)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for i in 1..<rows {
                let y = size.height * CGFloat(i) / CGFloat(rows)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Simple bubble-level using CoreMotion's gravity vector, showing roll angle.
@MainActor
@Observable
final class LevelMonitor {
    private let motionManager = CMMotionManager()
    private(set) var rollDegrees: Double = 0
    private(set) var isLevel: Bool = false

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll * 180 / .pi
            self.rollDegrees = roll
            self.isLevel = abs(roll) < 1.0
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}

struct LevelIndicator: View {
    let monitor: LevelMonitor

    var body: some View {
        Rectangle()
            .fill(monitor.isLevel ? Theme.success : Color.white.opacity(0.6))
            .frame(width: 60, height: 2)
            .rotationEffect(.degrees(-monitor.rollDegrees))
            .animation(.easeOut(duration: 0.15), value: monitor.rollDegrees)
    }
}

/// Momentary reticle shown at the tap-to-focus point.
struct FocusReticle: View {
    let point: CGPoint
    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 1

    var body: some View {
        Rectangle()
            .stroke(Theme.accent, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(point)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { scale = 1.0 }
                withAnimation(.easeIn(duration: 0.4).delay(0.6)) { opacity = 0 }
            }
            .allowsHitTesting(false)
    }
}
