import AppKit
import SwiftUI

/// The eye drop reminder, in the corner of the screen. Unlike a break it stays until you
/// answer it, because a dose isn't over just because time passed.
@MainActor
final class DropsPanelController {
    var onDone: (() -> Void)?
    var onSnooze: (() -> Void)?

    private var panel: NSPanel?
    private var times: [Date] = []

    /// Shows a reminder for `times`, or closes it if `times` is empty.
    /// Returns true when this is a new reminder rather than the one already up.
    @discardableResult
    func update(_ times: [Date]) -> Bool {
        guard times != self.times else { return false }
        self.times = times
        if let panel {
            FloatingPanel.dismiss(panel)
            self.panel = nil
        }
        guard !times.isEmpty else { return false }

        let view = DropsView(text: DropSchedule.summary(of: times, now: Date(), message: Prefs.dropMessage),
                             onDone: { [weak self] in self?.onDone?() },
                             onSnooze: { [weak self] in self?.onSnooze?() })
        panel = FloatingPanel.show(view) { size, frame in
            NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16)
        }
        return true
    }
}

struct DropsView: View {
    let text: String
    let onDone: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Label("Eye drops", systemImage: "drop.fill")
                .font(.headline)

            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Snooze 10m", action: onSnooze)
                Spacer()
                Button("Done", action: onDone)
            }
        }
        .padding(22)
        .frame(width: 300)
    }
}
