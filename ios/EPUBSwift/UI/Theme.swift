import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Palette {
    static let indigo = Color(hex: 0x635BFF)
    static let violet = Color(hex: 0x8B3FEA)
    static let rose = Color(hex: 0xE11D48)
    static let gold = Color(hex: 0xFBBF24)
    static let gradient = LinearGradient(colors: [Color(hex: 0x4F46E5), Color(hex: 0x6D4DF2), Color(hex: 0x8B3FEA)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// "system", "light" or "dark".
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
