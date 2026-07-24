import Foundation

public enum AppPreferenceKey {
    public static let autoStart = "startRemoteControlOnLaunch"
    public static let launchAtLogin = "launchCodexRemoteAtLogin"
    public static let customCodexPath = CodexLocator.overrideKey
    public static let refreshInterval = "refreshInterval"
}

public enum AppPreferenceDefault {
    public static let autoStart = true
    public static let launchAtLogin = true
    public static let refreshInterval = 15.0
}
