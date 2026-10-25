import Foundation
import Testing
@testable import GSDStore

/// The one switch every harness launch flips. Any `--demo-` argument means the process must
/// not touch what the real app owns: the App Group database and defaults, the keychain session,
/// the share outbox, the widget snapshot, reminders, and Spotlight.
struct HarnessLaunchTests {
    @Test func anyDemoArgumentIsolatesTheLaunch() {
        #expect(HarnessLaunch.isolates(arguments: ["--demo-seed"]))
        #expect(HarnessLaunch.isolates(arguments: ["--demo-home"]))
        #expect(HarnessLaunch.isolates(arguments: ["/Applications/GSD.app/GSD", "--demo-clock", "1789146000"]))
        #expect(HarnessLaunch.isolates(arguments: ["--demo-window", "420x860"]))
    }

    @Test func aNormalLaunchIsNotIsolated() {
        #expect(!HarnessLaunch.isolates(arguments: []))
        #expect(!HarnessLaunch.isolates(arguments: ["/Applications/GSD.app/GSD"]))
        #expect(!HarnessLaunch.isolates(arguments: ["-AppleLanguages", "(en)"]))
        #expect(!HarnessLaunch.isolates(arguments: ["demo-seed"]))
    }

    @Test func theIsolatedDefaultsSuiteIsNotTheAppGroup() {
        #expect(HarnessLaunch.defaultsSuiteName != StoreLocation.appGroupID)
        #expect(HarnessLaunch.defaultsSuiteName.hasPrefix("dev.vinny.gsd."))
    }

    @Test func isolatedDefaultsStartEmptyOnEveryLaunch() {
        let first = HarnessLaunch.makeIsolatedDefaults()
        first.set(true, forKey: "hasOnboarded")
        #expect(first.bool(forKey: "hasOnboarded"))
        let second = HarnessLaunch.makeIsolatedDefaults()
        #expect(!second.bool(forKey: "hasOnboarded"))
    }

    @Test func theScratchDirectoryExistsAndIsNotTheAppGroupContainer() throws {
        let scratch = HarnessLaunch.scratchDirectory
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: scratch.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!scratch.path.contains(StoreLocation.appGroupID))
    }
}
