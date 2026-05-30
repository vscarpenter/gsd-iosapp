import Testing
@testable import GSDModel

struct CaptureParserTests {
    @Test func doubleExclamationSetsUrgentAndImportant() {
        let r = CaptureParser.parse("Ship the build !!")
        #expect(r.urgent && r.important)
        #expect(r.title == "Ship the build")
    }

    @Test func singleExclamationSetsUrgentOnly() {
        let r = CaptureParser.parse("Call dentist !")
        #expect(r.urgent && !r.important)
        #expect(r.title == "Call dentist")
    }

    @Test func asteriskSetsImportant() {
        let r = CaptureParser.parse("Plan roadmap *")
        #expect(!r.urgent && r.important)
        #expect(r.title == "Plan roadmap")
    }

    @Test func doubleExclamationTakesPrecedenceOverSingle() {
        let r = CaptureParser.parse("Urgent thing !!")
        #expect(r.urgent && r.important)
    }

    @Test func hashTagsLowercasedAndDeduplicated() {
        let r = CaptureParser.parse("Buy milk #Errand #errand #Home")
        #expect(r.tags == ["errand", "home"])
        #expect(r.title == "Buy milk")
    }

    @Test func tagsCappedAt20() {
        let many = (1...25).map { "#t\($0)" }.joined(separator: " ")
        let r = CaptureParser.parse("Task \(many)")
        #expect(r.tags.count == 20)
    }

    @Test func noFlagsLeavesBothFalse() {
        let r = CaptureParser.parse("Just a note")
        #expect(!r.urgent && !r.important)
        #expect(r.title == "Just a note")
    }

    @Test func validURLMovedToDescriptionAdditions() {
        let r = CaptureParser.parse("Read this https://example.com/post later")
        #expect(r.descriptionAdditions == ["https://example.com/post"])
        #expect(r.title == "Read this later")
    }

    @Test func unsafeURLLeftInTitle() {
        let r = CaptureParser.parse("see ftp://example.com now")
        #expect(r.descriptionAdditions.isEmpty)
        #expect(r.title.contains("ftp://example.com"))
    }

    @Test func titleEmptiedByURLBecomesReviewLinkBelow() {
        let r = CaptureParser.parse("https://example.com/x")
        #expect(r.title == "Review link below")
        #expect(r.descriptionAdditions == ["https://example.com/x"])
    }

    @Test func collapsesWhitespaceAfterRemoval() {
        let r = CaptureParser.parse("a   !!   b")
        #expect(r.title == "a b")
    }

    // Fix 1: tag length validation
    @Test func tagOver30CharsIsDropped() {
        let longTag = "#" + String(repeating: "a", count: 31)
        let r = CaptureParser.parse("Task \(longTag)")
        #expect(r.tags.isEmpty)
    }

    @Test func tagExactly30CharsIsKept() {
        let tag30 = "#" + String(repeating: "a", count: 30)
        let r = CaptureParser.parse("Task \(tag30)")
        #expect(r.tags == [String(repeating: "a", count: 30)])
    }

    @Test func digitLeadingTagIsKept() {
        let r = CaptureParser.parse("Task #123")
        #expect(r.tags.contains("123"))
    }
}
