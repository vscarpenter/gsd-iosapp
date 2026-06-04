import Testing
import Foundation
import GSDSnapshot

struct SharedCaptureTests {
    private var sample: SharedCapture {
        SharedCapture(title: "Read this", urls: ["https://example.com"],
                      urgent: false, important: false, tags: ["read", "later"],
                      capturedAt: Date(timeIntervalSince1970: 42))
    }

    @Test func roundTrips() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SharedCapture.self, from: data)
        #expect(decoded == sample)
    }

    @Test func encodesAllFields() throws {
        let json = try JSONEncoder().encode(sample)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(object?["title"] as? String == "Read this")
        #expect(object?["urls"] as? [String] == ["https://example.com"])
        #expect(object?["urgent"] as? Bool == false)
        #expect(object?["tags"] as? [String] == ["read", "later"])
    }
}
