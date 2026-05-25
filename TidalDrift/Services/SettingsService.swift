import Foundation
import ServiceManagement
import AppKit

class SettingsService {
    static let shared = SettingsService()
    
    private let settingsKey = "appSettings"
    
    private init() {}
    
    func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }
    
    func saveSettings(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        
        applySettings(settings)
    }
    
    private func applySettings(_ settings: AppSettings) {
        _ = setLaunchAtLogin(settings.launchAtLogin)
        applyTheme(settings.theme)
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(settings.showMenuBarIcon)
        }
    }
    
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                // Failed to set launch at login - requires app to be in Applications folder
                return false
            }
        }
        return false
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    
    func resetToDefaults() {
        saveSettings(.default)
    }

    func applyTheme(_ theme: AppSettings.AppTheme) {
        DispatchQueue.main.async {
            switch theme {
            case .system:
                NSApp.appearance = nil
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }
    
    func exportSettings() -> Data? {
        let settings = loadSettings()
        return try? JSONEncoder().encode(settings)
    }
    
    func importSettings(from data: Data) -> Bool {
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return false
        }
        saveSettings(settings)
        return true
    }
}
