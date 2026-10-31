import Testing
import Foundation
@testable import GSDSync
@testable import GSDWire

/// B-08: route-first account erasure with a bounded client-side fallback. Ports Android
/// `AccountDeleter.kt` and web `lib/sync/pb-account-deletion.ts`.
struct AccountDeleterTests {
    final class Probe: @unchecked Sendable {
        var routeError: Error?
        var passes: [AccountDeleter.ErasePass] = []
        var userRecordError: Error?
        private(set) var routeCalls = 0
        private(set) var passCalls = 0
        private(set) var userRecordCalls = 0

        func makeDeleter() -> AccountDeleter {
            AccountDeleter(
                deleteViaRoute: { self.routeCalls += 1; if let e = self.routeError { throw e } },
                erasePass: { self.passCalls += 1; return self.passes.isEmpty ? .empty : self.passes.removeFirst() },
                deleteUserRecord: { self.userRecordCalls += 1; if let e = self.userRecordError { throw e } })
        }
    }
    private let notFound = PocketBaseError.http(status: 404, body: "")

    @Test func routeSuccessDeletesWithoutTouchingTheFallback() async {
        let p = Probe()
        let outcome = await p.makeDeleter().delete()
        #expect(outcome == .deleted)
        #expect(p.passCalls == 0 && p.userRecordCalls == 0)
    }

    @Test func nonNotFoundRouteFailureStopsWithNothingChanged() async {
        let p = Probe(); p.routeError = PocketBaseError.http(status: 500, body: "")
        let outcome = await p.makeDeleter().delete()
        #expect(outcome == .failed(remoteTasksErased: false))
        #expect(p.passCalls == 0 && p.userRecordCalls == 0)
    }

    @Test func networkFailureOnRouteIsNotAbsentRoute() async {
        let p = Probe(); p.routeError = PocketBaseError.network("offline")
        #expect(await p.makeDeleter().delete() == .failed(remoteTasksErased: false))
        #expect(p.passCalls == 0)
    }

    @Test func routeAuthRejectionReportsSessionExpired() async {
        let p = Probe(); p.routeError = PocketBaseError.pocketBase(status: 401, message: "x")
        #expect(await p.makeDeleter().delete() == .sessionExpired)
        #expect(p.passCalls == 0)
    }

    @Test func notFoundFallsBackAndDeletesUserOnlyAfterAnEmptyPass() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.erased, .empty]
        #expect(await p.makeDeleter().delete() == .deleted)
        #expect(p.passCalls == 2 && p.userRecordCalls == 1)
    }

    @Test func fallbackStopsAfterThreePassesWithoutDeletingTheUser() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.erased, .erased, .erased, .empty]
        #expect(await p.makeDeleter().delete() == .failed(remoteTasksErased: true))
        #expect(p.passCalls == 3 && p.userRecordCalls == 0)
    }

    @Test func firstPassFailureReportsNothingErased() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.failed(authRejected: false)]
        #expect(await p.makeDeleter().delete() == .failed(remoteTasksErased: false))
        #expect(p.userRecordCalls == 0)
    }

    @Test func laterPassFailureReportsPartialErase() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.erased, .failed(authRejected: false)]
        #expect(await p.makeDeleter().delete() == .failed(remoteTasksErased: true))
    }

    @Test func passAuthRejectionReportsSessionExpired() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.failed(authRejected: true)]
        #expect(await p.makeDeleter().delete() == .sessionExpired)
    }

    @Test func userRecordFailureAfterEmptyListingIsRetryable() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.empty]
        p.userRecordError = PocketBaseError.http(status: 500, body: "")
        #expect(await p.makeDeleter().delete() == .failed(remoteTasksErased: false))
    }

    @Test func userRecordFailureAfterErasingReportsPartial() async {
        let p = Probe(); p.routeError = notFound; p.passes = [.erased, .empty]
        p.userRecordError = PocketBaseError.network("x")
        #expect(await p.makeDeleter().delete() == .failed(remoteTasksErased: true))
    }
}
