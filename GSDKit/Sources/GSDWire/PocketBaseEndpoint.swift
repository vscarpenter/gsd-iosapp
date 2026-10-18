import Foundation

/// The owner's live backend. One constant so the app (`AuthConfig.live`) and the Share Extension
/// (`DirectTaskPush`) can never disagree about where the server is.
public enum PocketBaseEndpoint {
    public static let liveBaseURL = "https://api.vinny.io"
}
