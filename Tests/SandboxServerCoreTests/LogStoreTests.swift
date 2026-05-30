import XCTest
@testable import SandboxServerAPI
#if SandboxServerEnabled
@testable import SandboxServerCore

/// D2: LogStore is the console's log tail/resume contract. Covers both list shapes (tail vs
/// incremental resume), level + substring filtering, and ring eviction without seq reuse.
final class LogStoreTests: XCTestCase {
    private func emitN(_ store: LogStore, _ n: Int) -> [Int] {
        (0..<n).map { store.emit(level: "info", message: "m\($0)", source: "test").seq }
    }

    func testTailIsNewestFirstWithNoCursor() {
        let store = LogStore()
        let seq = emitN(store, 10)
        let page = store.list(level: nil, contains: nil, sinceSeq: nil, limit: 3)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.items.map(\.seq), [seq[9], seq[8], seq[7]], "tail returns the newest, newest-first")
    }

    func testResumeIsOldestFirstWithCursorThenDrains() {
        let store = LogStore()
        let seq = emitN(store, 10)
        // After seq[4], the next 5 match; limit 3 → the oldest 3 of those, with a cursor.
        let page = store.list(level: nil, contains: nil, sinceSeq: seq[4], limit: 3)
        XCTAssertEqual(page.items.map(\.seq), [seq[5], seq[6], seq[7]])
        XCTAssertEqual(page.nextCursor, String(seq[7]))
        // Paging from that cursor returns the remaining 2 (< limit) and no further cursor.
        let page2 = store.list(level: nil, contains: nil, sinceSeq: seq[7], limit: 3)
        XCTAssertEqual(page2.items.map(\.seq), [seq[8], seq[9]])
        XCTAssertNil(page2.nextCursor)
    }

    func testLevelAndSubstringFilters() {
        let store = LogStore()
        _ = store.emit(level: "info", message: "apple", source: "a")
        _ = store.emit(level: "warn", message: "banana", source: "a")
        _ = store.emit(level: "warn", message: "apricot", source: "a")
        _ = store.emit(level: "error", message: "cherry", source: "a")
        let warns = store.list(level: "warn", contains: nil, sinceSeq: nil, limit: 10)
        XCTAssertEqual(warns.items.map(\.message), ["apricot", "banana"], "level filter, newest-first")
        let ap = store.list(level: nil, contains: "AP", sinceSeq: nil, limit: 10)
        XCTAssertEqual(ap.items.map(\.message), ["apricot", "apple"], "substring filter is case-insensitive")
        let both = store.list(level: "warn", contains: "ap", sinceSeq: nil, limit: 10)
        XCTAssertEqual(both.items.map(\.message), ["apricot"], "level AND substring compose")
    }

    func testRingEvictionDropsOldestWithoutSeqReuse() {
        let store = LogStore(maxCount: 5)
        let seq = emitN(store, 8)
        XCTAssertEqual(store.count, 5, "bounded to maxCount")
        XCTAssertEqual(seq, Array(stride(from: seq[0], through: seq[0] + 7, by: 1)), "seq is monotonic +1 — never reused")
        let survivors = Set(store.list(level: nil, contains: nil, sinceSeq: nil, limit: 100).items.map(\.seq))
        XCTAssertEqual(survivors, Set(seq[3...7]), "the newest 5 survive; the oldest 3 are evicted")
        let next = store.emit(level: "info", message: "x", source: "test").seq
        XCTAssertEqual(next, seq[7] + 1, "a new entry keeps climbing past the evicted seqs")
    }
}
#endif
