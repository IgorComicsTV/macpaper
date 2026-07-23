import Foundation

public enum PlaylistOrder: String, Codable, CaseIterable, Sendable {
    case sequential
    case random

    public var title: String {
        switch self {
        case .sequential: return "Sequencial"
        case .random: return "Aleatória"
        }
    }
}

public enum WallpaperLayoutMode: String, Codable, CaseIterable, Sendable {
    case individual
    case mirrored
    case spanned

    public var title: String {
        switch self {
        case .individual: return "Individual"
        case .mirrored: return "Espelhado"
        case .spanned: return "Estendido"
        }
    }
}

public enum VideoContentMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch

    public var title: String {
        switch self {
        case .fill: return "Preencher"
        case .fit: return "Ajustar"
        case .stretch: return "Esticar"
        }
    }
}

public enum ForegroundBehavior: String, Codable, CaseIterable, Sendable {
    case continuePlaying
    case pauseOccupiedDisplays

    public var title: String {
        switch self {
        case .continuePlaying: return "Continuar reproduzindo"
        case .pauseOccupiedDisplays: return "Pausar no monitor ocupado"
        }
    }
}

public struct DisplayConfiguration: Codable, Equatable, Sendable {
    public var displayName: String
    public var folderPath: String?
    public var order: PlaylistOrder
    public var interval: TimeInterval
    public var currentFile: String?
    public var isPaused: Bool

    public init(
        displayName: String,
        folderPath: String? = nil,
        order: PlaylistOrder = .random,
        interval: TimeInterval = 3_600,
        currentFile: String? = nil,
        isPaused: Bool = false
    ) {
        self.displayName = displayName
        self.folderPath = folderPath
        self.order = order
        self.interval = interval
        self.currentFile = currentFile
        self.isPaused = isPaused
    }
}

public struct WallpaperGroupConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var displayIDs: [String]
    public var folderPath: String?
    public var order: PlaylistOrder
    public var interval: TimeInterval
    public var currentFile: String?
    public var isPaused: Bool
    public var layoutMode: WallpaperLayoutMode
    public var contentMode: VideoContentMode

    public init(
        id: String = UUID().uuidString,
        name: String,
        displayIDs: [String],
        folderPath: String? = nil,
        order: PlaylistOrder = .random,
        interval: TimeInterval = 3_600,
        currentFile: String? = nil,
        isPaused: Bool = false,
        layoutMode: WallpaperLayoutMode = .individual,
        contentMode: VideoContentMode = .fill
    ) {
        self.id = id
        self.name = name
        self.displayIDs = displayIDs
        self.folderPath = folderPath
        self.order = order
        self.interval = interval
        self.currentFile = currentFile
        self.isPaused = isPaused
        self.layoutMode = layoutMode
        self.contentMode = contentMode
    }
}

public struct MacPaperConfiguration: Codable, Equatable, Sendable {
    // Mantido durante a migração das versões 1.x.
    public var displays: [String: DisplayConfiguration]
    public var groups: [WallpaperGroupConfiguration]
    public var libraryFolders: [String]
    public var foregroundBehavior: ForegroundBehavior
    public var globallyPaused: Bool

    public init(
        displays: [String: DisplayConfiguration] = [:],
        groups: [WallpaperGroupConfiguration] = [],
        libraryFolders: [String] = [],
        foregroundBehavior: ForegroundBehavior = .pauseOccupiedDisplays,
        globallyPaused: Bool = false
    ) {
        self.displays = displays
        self.groups = groups
        self.libraryFolders = libraryFolders
        self.foregroundBehavior = foregroundBehavior
        self.globallyPaused = globallyPaused
    }

    private enum CodingKeys: String, CodingKey {
        case displays, groups, libraryFolders, foregroundBehavior, globallyPaused
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displays = try values.decodeIfPresent([String: DisplayConfiguration].self, forKey: .displays) ?? [:]
        groups = try values.decodeIfPresent([WallpaperGroupConfiguration].self, forKey: .groups) ?? []
        libraryFolders = try values.decodeIfPresent([String].self, forKey: .libraryFolders) ?? []
        foregroundBehavior = try values.decodeIfPresent(ForegroundBehavior.self, forKey: .foregroundBehavior)
            ?? .pauseOccupiedDisplays
        globallyPaused = try values.decodeIfPresent(Bool.self, forKey: .globallyPaused) ?? false
    }
}

public enum TimerPreset {
    public static let values: [TimeInterval] = [900, 1_800, 3_600, 7_200, 21_600, 43_200, 86_400]
    public static let minimum: TimeInterval = 60
    public static let maximum: TimeInterval = 604_800

    public static func clamped(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimum), maximum)
    }

    public static func label(for seconds: TimeInterval) -> String {
        switch Int(seconds) {
        case 900: return "15 min"
        case 1_800: return "30 min"
        case 3_600: return "1 hora"
        case 7_200: return "2 horas"
        case 21_600: return "6 horas"
        case 43_200: return "12 horas"
        case 86_400: return "24 horas"
        default:
            if seconds < 3_600 { return "\(Int(seconds / 60)) min" }
            return String(format: "%.1f horas", seconds / 3_600)
        }
    }
}
