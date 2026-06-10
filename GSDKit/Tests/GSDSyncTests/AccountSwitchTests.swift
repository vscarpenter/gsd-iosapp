import Testing
@testable import GSDSync

struct AccountSwitchTests {
    @Test func firstEverSignInProceeds() {
        #expect(AccountSwitch.evaluate(lastOwnerId: nil, newOwnerId: "u1",
                                       hasLocalActiveTasks: true) == .proceed)
    }
    @Test func sameAccountProceeds() {
        #expect(AccountSwitch.evaluate(lastOwnerId: "u1", newOwnerId: "u1",
                                       hasLocalActiveTasks: true) == .proceed)
    }
    @Test func differentAccountWithNoLocalTasksProceeds() {
        #expect(AccountSwitch.evaluate(lastOwnerId: "u1", newOwnerId: "u2",
                                       hasLocalActiveTasks: false) == .proceed)
    }
    @Test func differentAccountWithLocalTasksPrompts() {
        #expect(AccountSwitch.evaluate(lastOwnerId: "u1", newOwnerId: "u2",
                                       hasLocalActiveTasks: true) == .prompt)
    }
}
