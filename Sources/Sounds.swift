import AppKit

/// Moments the app makes a sound. Each one can use a different sound.
enum SoundEvent: String, CaseIterable, Identifiable {
    case breakStart, breakEnd, drops

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakStart: return "Break starts"
        case .breakEnd: return "Break ends"
        case .drops: return "Eye drops"
        }
    }

    fileprivate var defaultSoundID: String {
        switch self {
        case .breakStart: return "system:Purr"
        case .breakEnd: return "system:Glass"
        case .drops: return "system:Hero"
        }
    }
}

struct Sound: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL

    var isCustom: Bool { id.hasPrefix("custom:") }
}

/// The macOS system sounds plus any you've added. Added sounds are copies kept in
/// ~/Library/Application Support/EyeBreak/Sounds, so the originals can move or go away.
@MainActor
final class SoundLibrary: ObservableObject {
    static let shared = SoundLibrary()

    @Published private(set) var systemSounds: [Sound] = []
    @Published private(set) var customSounds: [Sound] = []

    private var player: NSSound?

    private let folder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EyeBreak/Sounds", isDirectory: true)

    private init() {
        systemSounds = Self.sounds(in: URL(fileURLWithPath: "/System/Library/Sounds"), prefix: "system")
        reloadCustomSounds()
    }

    // MARK: - Playing

    func play(_ event: SoundEvent) {
        guard Prefs.soundEnabled, let sound = sound(withID: selectionID(for: event)) else { return }
        preview(sound)
    }

    /// Plays regardless of the sound setting, so you can try sounds with it off.
    func preview(_ sound: Sound) {
        stop()
        player = NSSound(contentsOf: sound.url, byReference: true)
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - Choosing

    /// The chosen sound, or the default if it was never set or has since been removed.
    func selectionID(for event: SoundEvent) -> String {
        if let id = Prefs.soundID(for: event.rawValue), sound(withID: id) != nil { return id }
        return event.defaultSoundID
    }

    func select(_ id: String, for event: SoundEvent) {
        objectWillChange.send()
        Prefs.setSoundID(id, for: event.rawValue)
    }

    private func sound(withID id: String) -> Sound? {
        (customSounds + systemSounds).first { $0.id == id }
    }

    // MARK: - Managing

    /// Copies audio files into the library. Returns the names of files it couldn't add.
    func add(_ urls: [URL]) -> [String] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rejected: [String] = []
        for url in urls {
            do {
                guard NSSound(contentsOf: url, byReference: true) != nil else {
                    rejected.append(url.lastPathComponent)
                    continue
                }
                try FileManager.default.copyItem(at: url, to: unusedDestination(for: url))
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        reloadCustomSounds()
        return rejected
    }

    /// Moves a custom sound to the Trash. Events using it go back to their default.
    func remove(_ sound: Sound) throws {
        stop()
        try FileManager.default.trashItem(at: sound.url, resultingItemURL: nil)
        reloadCustomSounds()
    }

    private func reloadCustomSounds() {
        customSounds = Self.sounds(in: folder, prefix: "custom")
    }

    /// "Rain.mp3", or "Rain 2.mp3" if that's taken.
    private func unusedDestination(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(url.pathExtension)
            number += 1
        }
        return destination
    }

    private static func sounds(in folder: URL, prefix: String) -> [Sound] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files
            .map { Sound(id: "\(prefix):\(prefix == "system" ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent)",
                         name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
