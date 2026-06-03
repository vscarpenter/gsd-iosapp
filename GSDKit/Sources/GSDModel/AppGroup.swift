import Foundation

/// The App Group container shared by the app and its extensions (widgets in Phase 6a).
/// This is the single source of truth for the identifier; it MUST match the
/// `com.apple.security.application-groups` entitlement in every target.
public enum AppGroup {
    public static let id = "group.dev.vinny.gsd"
}
