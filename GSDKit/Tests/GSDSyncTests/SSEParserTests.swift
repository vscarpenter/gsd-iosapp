import Testing
@testable import GSDSync

struct SSEParserTests {
    @Test func dispatchesOnBlankLine() {
        var p = SSEParser()
        #expect(p.feed("event: tasks") == nil)
        #expect(p.feed("data: {\"a\":1}") == nil)
        let e = p.feed("")
        #expect(e == SSEParser.Event(event: "tasks", data: "{\"a\":1}", id: nil))
    }

    @Test func multiLineDataJoinedWithNewline() {
        var p = SSEParser()
        _ = p.feed("data: line1")
        _ = p.feed("data: line2")
        let e = p.feed("")
        #expect(e?.data == "line1\nline2")
    }

    @Test func ignoresCommentHeartbeat() {
        var p = SSEParser()
        #expect(p.feed(":keep-alive") == nil)
        #expect(p.feed("") == nil)        // nothing buffered → no dispatch
    }

    @Test func capturesIdForReconnect() {
        var p = SSEParser()
        _ = p.feed("id: abc")
        _ = p.feed("data: x")
        let e = p.feed("")
        #expect(e?.id == "abc")
        #expect(p.lastEventId == "abc")
    }

    @Test func stripsSingleLeadingSpaceOnly() {
        var p = SSEParser()
        _ = p.feed("data:  two-spaces")   // one space stripped → " two-spaces"
        #expect(p.feed("")?.data == " two-spaces")
    }

    @Test func parsesPBConnect() {
        var p = SSEParser()
        _ = p.feed("event: PB_CONNECT")
        _ = p.feed("data: {\"clientId\":\"c123\"}")
        let e = p.feed("")
        #expect(e?.event == "PB_CONNECT")
        #expect(e?.data == "{\"clientId\":\"c123\"}")
    }

    // Real PocketBase wire format (Probe P1): no space after the colon, with an `id:` line.
    @Test func parsesRealPocketBaseConnectNoSpace() {
        var p = SSEParser()
        _ = p.feed("id:zvAqCYJ3FIM8WOaLNqggbHZkTEXi0uzhcLKlV9AO")
        _ = p.feed("event:PB_CONNECT")
        _ = p.feed("data:{\"clientId\":\"zvAqCYJ3FIM8WOaLNqggbHZkTEXi0uzhcLKlV9AO\"}")
        let e = p.feed("")
        #expect(e?.event == "PB_CONNECT")
        #expect(e?.id == "zvAqCYJ3FIM8WOaLNqggbHZkTEXi0uzhcLKlV9AO")
        #expect(e?.data == "{\"clientId\":\"zvAqCYJ3FIM8WOaLNqggbHZkTEXi0uzhcLKlV9AO\"}")
    }
}
