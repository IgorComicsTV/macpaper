import Foundation
import MacPaperCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("Falha: \(message)\n".utf8))
        exit(1)
    }
}

let a = URL(fileURLWithPath: "/a.mp4")
let b = URL(fileURLWithPath: "/b.mov")
let c = URL(fileURLWithPath: "/c.m4v")
require(MediaCatalog.next(in: [a, b, c], after: c, order: .sequential) == a, "sequência deve reiniciar")
require(MediaCatalog.next(in: [a, b], after: a, order: .random, randomIndex: { _ in 0 }) == b, "aleatório não deve repetir")
require(TimerPreset.clamped(1) == 60, "timer mínimo")
require(TimerPreset.clamped(999_999) == 604_800, "timer máximo")
let synchronized = WallpaperGroupConfiguration(name: "Grupo", displayIDs: ["a", "b"], layoutMode: .mirrored)
require(synchronized.displayIDs.count == 2 && synchronized.layoutMode == .mirrored, "grupo sincronizado")

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let disk = ConfigurationDiskStore(fileURL: root.appendingPathComponent("config.json"))
let expected = MacPaperConfiguration(displays: ["7": DisplayConfiguration(displayName: "Teste", folderPath: "/tmp")])
try disk.save(expected)
require(disk.load() == expected, "persistência JSON")
try? FileManager.default.removeItem(at: root)
print("Verificações do MacPaper concluídas com sucesso.")
