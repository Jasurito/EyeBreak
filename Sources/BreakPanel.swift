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
        let hosting = FirstMouseHostingView(rootView: BreakView(
            model: model,
            onSkip: { [weak self] in self?.finish(.skipped) },
            onSnooze: { [weak self] in self?.finish(.snoozed) }))
        let size = hosting.fittingSize

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 18)
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)

        let panel = BreakPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.contentView = background
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.setFrameOrigin(Self.origin(for: size))

        // Don't steal focus from whatever you're typing in.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel

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
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Centered, slightly above the middle of the screen the mouse is on.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(x: frame.midX - size.width / 2,
                       y: frame.midY - size.height / 2 + frame.height * 0.1)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class BreakPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets the buttons respond to the first click even though the panel isn't focused.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
