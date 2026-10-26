import Foundation

/// Interface language. Code comments and the log are English only; everything shown in the window
/// comes in both languages via `tr`. Default — the macOS language, then whatever the user picked.
enum UILanguage: String, CaseIterable, Identifiable {
    case english = "en", russian = "ru"
    var id: String { rawValue }
    var name: String { self == .russian ? "Русский" : "English" }

    static let key = "uiLanguage"
    static var current: UILanguage = {
        if let s = UserDefaults.standard.string(forKey: key), let l = UILanguage(rawValue: s) { return l }
        return Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .russian : .english
    }()
}

/// Interface string in the current language.
func tr(_ en: String, _ ru: String) -> String { UILanguage.current == .russian ? ru : en }

/// A message kept in both languages and rendered in whichever one is current —
/// so the status line follows a language switch right away.
struct Loc: Equatable {
    let en: String
    let ru: String
    init(_ en: String, _ ru: String) { self.en = en; self.ru = ru }
    var text: String { tr(en, ru) }
}
