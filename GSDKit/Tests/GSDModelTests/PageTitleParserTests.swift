import Testing
@testable import GSDModel

struct PageTitleParserTests {
    @Test func readsTitleElement() {
        let html = "<html><head><title>Hello World</title></head><body>x</body></html>"
        #expect(PageTitleParser.parse(html: html) == "Hello World")
    }

    @Test func prefersOgTitleOverTitleElement() {
        let html = """
        <head><meta property="og:title" content="OG Headline">
        <title>Tab Title</title></head>
        """
        #expect(PageTitleParser.parse(html: html) == "OG Headline")
    }

    @Test func handlesOgTitleWithContentBeforeProperty() {
        let html = #"<meta content="Reversed Attrs" property="og:title" />"#
        #expect(PageTitleParser.parse(html: html) == "Reversed Attrs")
    }

    @Test func decodesNamedEntities() {
        #expect(PageTitleParser.parse(html: "<title>Tom &amp; Jerry &quot;quoted&quot;</title>")
                == "Tom & Jerry \"quoted\"")
    }

    @Test func decodesNumericEntities() {
        #expect(PageTitleParser.parse(html: "<title>caf&#233; &#x2764;</title>") == "café ❤")
    }

    @Test func collapsesWhitespaceAndTrims() {
        #expect(PageTitleParser.parse(html: "<title>\n  Spaced   Out  \n</title>") == "Spaced Out")
    }

    @Test func caseInsensitiveTags() {
        #expect(PageTitleParser.parse(html: "<TITLE>Caps</TITLE>") == "Caps")
    }

    @Test func nilWhenNoTitle() {
        #expect(PageTitleParser.parse(html: "<html><body>no title here</body></html>") == nil)
    }

    @Test func nilForEmptyTitle() {
        #expect(PageTitleParser.parse(html: "<title>   </title>") == nil)
    }
}
