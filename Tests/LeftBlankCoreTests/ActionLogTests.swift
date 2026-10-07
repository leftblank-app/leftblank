import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

@Test func actionLogPersistsDistinctSessions() throws {
    let directory = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    do {
        let log = try ActionLog(directory: directory)
        #expect(log.record("command.selected", fields: ["command": "table"]))
        #expect(log.record("insertion.finished", fields: ["version": "2"]))
        // Records are readable before the logger closes, including after a crash.
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2)
    }
    let reopened = try ActionLog(directory: directory)
    #expect(reopened.record("session.start"))
    let entries = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    #expect(entries.map { $0["event"].string } == ["command.selected", "insertion.finished", "session.start"])
    #expect(entries[0]["session"].string == entries[1]["session"].string)
    #expect(entries[0]["session"].string != entries[2]["session"].string)
    #expect(entries[1]["sequence"].int == 2)
    let time = try #require(entries[0]["time"].string)
    #expect(try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time).timeIntervalSinceNow > -60)
}

@Test func actionLogRotationKeepsCompleteRecentRecords() throws {
    let directory = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ActionLog(directory: directory, maxBytes: 700, archivedFiles: 2)
    for index in 0 ..< 30 {
        #expect(log.record("key.down", fields: ["index": String(index), "key": "Return"]))
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(Set(files.map(\.lastPathComponent)) == ["events.jsonl", "events.1.jsonl", "events.2.jsonl"])
    for file in files {
        let data = try Data(contentsOf: file)
        #expect(data.count <= 700)
        for line in data.split(separator: 0x0A) {
            #expect(try JSONDecoder().decode(JSONValue.self, from: Data(line))["event"].string == "key.down")
        }
    }
    let current = try String(contentsOf: log.fileURL, encoding: .utf8)
    #expect(current.contains("\"index\":\"29\""))
}

@Test func actionLogsSharingAFileAppendWithoutOverwritingEachOther() throws {
    let directory = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    // A relaunched workspace logs while the previous one still records its last events.
    let previous = try ActionLog(directory: directory)
    #expect(previous.record("previous.started"))
    let relaunched = try ActionLog(directory: directory)
    for index in 0 ..< 5 {
        #expect(relaunched.record("relaunched.event", fields: ["index": String(index)]))
        #expect(previous.record("previous.event", fields: ["index": String(index)]))
    }
    let entries = try String(contentsOf: relaunched.fileURL, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    #expect(entries.count == 11)
    #expect(entries.filter { $0["event"].string == "relaunched.event" }.compactMap { $0["fields"]["index"].string }
        == ["0", "1", "2", "3", "4"])
    #expect(entries.filter { $0["event"].string == "previous.event" }.count == 5)

    // After one log rotates the shared file, the other keeps writing to the current file.
    let small = try ActionLog(directory: directory, maxBytes: 700, archivedFiles: 2)
    #expect(small.record("rotating.event"))
    #expect(previous.record("previous.afterRotation"))
    let current = try String(contentsOf: relaunched.fileURL, encoding: .utf8)
    #expect(current.contains("rotating.event") && current.contains("previous.afterRotation"))
    #expect(!current.contains("relaunched.event"))
}
