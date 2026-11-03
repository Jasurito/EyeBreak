import AppKit
import SwiftUI

/// Shows the floating "look away" popup and runs its countdown.
@MainActor
final class BreakPanelController: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?
    private var model: BreakModel?
    private var endsAt = Date()
    private var completion: ((BreakOutcome) -> Void)?

    func show(seconds: Int, completion: @escaping (BreakOutcome) -> Void) {
        close()
        self.completion = completion
        endsAt = Date().addingTimeInterval(TimeInterval(seconds))

        let model = BreakModel(total: seconds)
        self.model = model
        let view = BreakView(model: model,
                             onSkip: { [weak self] in self?.finish(.skipped) },
                             onSnooze: { [weak self] in self?.finish(.snoozed) })
        // Centered, slightly above the middle of the screen.
        panel = FloatingPanel.show(view) { size, frame in
            NSPoint(x: frame.midX - size.width / 2,
                    y: frame.midY - size.height / 2 + frame.height * 0.1)
        }

        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        let left = max(0, Int(ceil(endsAt.timeIntervalSinceNow)))
        if model?.secondsLeft != left { model?.secondsLeft = left }
        if left == 0 { finish(.completed) }
    }

    private func finish(_ outcome: BreakOutcome) {
        guard let completion else { return }
        self.completion = nil
        close()
        completion(outcome)
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        model = nil
        if let panel {
            FloatingPanel.dismiss(panel)
            self.panel = nil
        }
    }
}

@MainActor
final class BreakModel: ObservableObject {
    let total: Int
    @Published var secondsLeft: Int

    init(total: Int) {
        self.total = total
        self.secondsLeft = total
    }
}

struct BreakView: View {
    @ObservedObject var model: BreakModel
    let onSkip: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Label("Eye break", systemImage: "eye")
                .font(.headline)

            VStack(spacing: 4) {
                Text("Look at something ~6 m (20 ft) away")
                Text("Blink slowly a few times")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(model.secondsLeft) / CGFloat(max(model.total, 1)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: model.secondsLeft)
                Text(String(format: "%d:%02d", model.secondsLeft / 60, model.secondsLeft % 60))
                    .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
            }
            .frame(width: 96, height: 96)

            HStack {
                Button("Skip", action: onSkip)
                Spacer()
                Button("Snooze 5m", action: onSnooze)
            }
        }
        .padding(22)
        .frame(width: 300)
    }
}
