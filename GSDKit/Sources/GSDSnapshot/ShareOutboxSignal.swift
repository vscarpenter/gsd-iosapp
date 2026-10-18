import Foundation

/// Cross-process "a capture was written" push so a *running* app drains the share
/// outbox immediately, instead of waiting for the next cold launch.
///
/// Why this exists: the Share Extension runs in the *sending* app's context and never
/// brings GSD forward, so the app's `scenePhase → .active` drain only fires when the
/// user next opens it. On Mac Catalyst (and iPad multitasking) the app is often still
/// running when a share lands, yet Catalyst's `scenePhase` does not reliably re-fire
/// `.active` on re-focus — so captures sat in the outbox until a manual relaunch. The
/// Darwin notify center is the one app↔extension push that works identically on iOS
/// and Catalyst (and isn't a wasteful poll).
///
/// Limits: a suspended iOS app runs no code, so this cannot wake a backgrounded phone;
/// the handler fires once the app resumes, alongside the `.active` drain. Between
/// shares and the next open, `BackgroundRefresh` is what drains and syncs (§9.4).
///
/// Foundation-only / GRDB-free, like the rest of the app↔extension contract here.
public enum ShareOutboxSignal {
    /// Shared constant name; both processes must use the exact same string. Kept as a
    /// `String` (Sendable) — a `static let CFString` trips Swift 6's global-safety check.
    private static let name = "dev.vinny.gsd.share-outbox.didWrite"

    /// Posted by the writer (the Share Extension) after a successful outbox write.
    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Registers `handler` (run on the main actor) to fire whenever a capture is
    /// posted. Call once, at app launch. The C callback captures nothing — it only
    /// hops to the main actor and invokes the stored handler.
    @MainActor public static func observe(_ handler: @escaping @MainActor () -> Void) {
        mainActorHandler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                _Concurrency.Task { @MainActor in ShareOutboxSignal.mainActorHandler?() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    @MainActor private static var mainActorHandler: (@MainActor () -> Void)?
}
