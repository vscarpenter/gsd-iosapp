import Foundation
import Testing
import GSDModel
@testable import GSDSync

/// C4-4 at contract 3: what the backfill copies onto a local row that's about to win.
struct SyncBackfillTests {
    private let savedOnWeb = Date(timeIntervalSince1970: 1_792_490_400)       // 2026-10-20
    private let editedHere = Date(timeIntervalSince1970: 1_792_576_800)       // 2026-10-21

    private func local(completed: Bool = false, timeEntries: [TimeEntry] = []) -> Task {
        Task(id: "a", title: "Edited on the old build", urgent: true, important: true, completed: completed,
             createdAt: savedOnWeb, updatedAt: editedHere, timeEntries: timeEntries)
    }

    private var remote: Task {
        Task(id: "a", title: "Read later", urgent: false, important: true,
             createdAt: savedOnWeb, updatedAt: savedOnWeb, savedAt: savedOnWeb)
    }

    @Test func aRowAnOlderBuildStoredTakesTheServersSavedAtAndKeepsEverythingElse() throws {
        let filled = try #require(SyncBackfill.fillingUnreadFields(of: local(), from: remote, storedVersion: 2))
        var expected = local()
        expected.savedAt = savedOnWeb
        #expect(filled == expected)                                    // stamp, title, and flags stay local
    }

    @Test func aMissingVersionReadsAsOlderThanSaved() {
        #expect(SyncBackfill.fillingUnreadFields(of: local(), from: remote, storedVersion: 0)?.savedAt == savedOnWeb)
    }

    @Test func aRowPulledUnderContractThreeKeepsItsReturn() {
        #expect(SyncBackfill.fillingUnreadFields(of: local(), from: remote, storedVersion: 3) == nil)
    }

    @Test func nothingToCopyWhenTheServerHasNoPlacement() {
        var unsaved = remote
        unsaved.savedAt = nil
        #expect(SyncBackfill.fillingUnreadFields(of: local(), from: unsaved, storedVersion: 2) == nil)
    }

    @Test func aRowThatAlreadyHasAPlacementKeepsIt() {
        var saved = local()
        saved.savedAt = editedHere
        #expect(SyncBackfill.fillingUnreadFields(of: saved, from: remote, storedVersion: 2) == nil)
    }

    @Test func aCompletedRowIsNotSaved() {
        #expect(SyncBackfill.fillingUnreadFields(of: local(completed: true), from: remote, storedVersion: 2) == nil)
    }

    @Test func aRowWithARunningTimerIsNotSaved() {
        let running = TimeEntry(id: "e1", startedAt: editedHere)
        #expect(SyncBackfill.fillingUnreadFields(of: local(timeEntries: [running]), from: remote, storedVersion: 2) == nil)
    }
}
