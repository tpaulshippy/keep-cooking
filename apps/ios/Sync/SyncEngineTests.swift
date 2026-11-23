// Smidgen — Lane 2 iOS Foundation
// apps/ios/Sync/SyncEngineTests.swift
//
// XCTest coverage for the pure sync core:
//   1. Two-device convergence (A + B edit offline, sync, agree).
//   2. Collision matrix (rows x columns documented in SYNC_TEST.md).
//   3. Photo SHA-256 dedup.
//
// These tests exercise ONLY pure Sendable functions + the SyncEngine actor
// with an in-memory fake transport — no SwiftData, no network, no CloudKit.

import XCTest

// MARK: - Fake transport (in-memory Lane 1 stand-in)

actor FakeServer {
    var store: [String: SyncEnvelope] = [:]

    func pull(since: Date?) async -> [SyncEnvelope] {
        store.values.filter { env in
            guard let since else { return true }
            return env.updatedAt > since
        }.sorted(by: { $0.updatedAt < $1.updatedAt })
    }

    /// LWW accept: server keeps the newest per id, returns server-won conflicts.
    func push(_ envs: [SyncEnvelope]) async -> [SyncEnvelope] {
        var won: [SyncEnvelope] = []
        for env in envs {
            if let cur = store[env.id], cur.updatedAt > env.updatedAt {
                won.append(cur)
            } else {
                store[env.id] = env
            }
        }
        return won
    }
}

struct FakeTransport: SyncTransport {
    let server: FakeServer
    func pull(since: Date?) async throws -> [SyncEnvelope] {
        await server.pull(since: since)
    }
    func push(_ envelopes: [SyncEnvelope]) async throws -> [SyncEnvelope] {
        await server.push(envelopes)
    }
}

// MARK: - Helpers

/// Sendable box so @Sendable applyRemote closures can record results
/// without captured-var warnings (error in Swift 6 mode).
/// Unchecked because all access is serialized through `lock`.
final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncEnvelope] = []
    func append(_ envelope: SyncEnvelope) {
        lock.withLock { values.append(envelope) }
    }
    var all: [SyncEnvelope] {
        lock.withLock { values }
    }
}

func makeEnv(id: String, at date: Date, device: String, deleted: Bool = false,
             entity: SyncEntityName = .recipe) -> SyncEnvelope {
    SyncEnvelope(id: id, updatedAt: date, deviceId: device, deleted: deleted,
                 entity: entity, payload: ["title": "T"])
}

let base = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - 1. Two-device convergence

final class TwoDeviceConvergenceTests: XCTestCase {
    func testTwoDevicesConvergeAfterOfflineEdits() async throws {
        let server = FakeServer()
        let engineA = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: server))
        let engineB = SyncEngine(deviceId: "device-b", transport: FakeTransport(server: server))

        // Both start from the same seed record.
        let seed = makeEnv(id: "r1", at: base, device: "seed")
        _ = await server.push([seed])
        _ = try await engineA.sync()
        _ = try await engineB.sync()

        // Airplane mode: A renames at t+10, B renames at t+20 (B wins).
        await engineA.enqueue(makeEnv(id: "r1", at: base.addingTimeInterval(10), device: "device-a"))
        await engineB.enqueue(makeEnv(id: "r1", at: base.addingTimeInterval(20), device: "device-b"))

        _ = try await engineA.sync() // A pushes t+10
        let resB = try await engineB.sync() // B pulls t+10 (keeps local, newer), pushes t+20
        XCTAssertEqual(resB.pushed, 1)

        // A syncs again and must converge on B's newer write.
        let appliedBox = EnvelopeBox()
        _ = try await engineA.sync(applyRemote: { appliedBox.append($0) })
        XCTAssertEqual(appliedBox.all.count, 1)
        XCTAssertEqual(appliedBox.all.first?.deviceId, "device-b")

        let finalA = await server.store["r1"]
        XCTAssertEqual(finalA?.deviceId, "device-b")
        let pendingA = await engineA.pendingCount
        let pendingB = await engineB.pendingCount
        XCTAssertEqual(pendingA, 0)
        XCTAssertEqual(pendingB, 0)
    }

    func testDeleteTombstoneBeatsOlderLiveRecord() async throws {
        let server = FakeServer()
        let engine = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: server))
        _ = await server.push([makeEnv(id: "r9", at: base, device: "seed")])
        _ = try await engine.sync()
        // Local delete (tombstone) at t+30 must survive push and read back.
        await engine.enqueue(makeEnv(id: "r9", at: base.addingTimeInterval(30),
                                     device: "device-a", deleted: true))
        let res = try await engine.sync()
        XCTAssertEqual(res.pushed, 1)
        let r9deleted = (await server.store["r9"])?.deleted
        XCTAssertEqual(r9deleted, true)
    }
}

// MARK: - 2. Collision matrix (see SYNC_TEST.md for the table)

final class CollisionMatrixTests: XCTestCase {
    func testMatrix() {
        struct Case {
            let name: String
            let local: SyncEnvelope
            let remote: SyncEnvelope
            let expect: MergeOutcome
        }
        let cases: [Case] = [
            Case(name: "remote newer wins",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "b"),
                 expect: .takeRemote),
            Case(name: "local newer wins",
                 local: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "b"),
                 expect: .keepLocal),
            Case(name: "identical no-op",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "a"),
                 expect: .identical),
            Case(name: "tie breaks remote (convergent)",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "b"),
                 expect: .takeRemote),
            Case(name: "newer tombstone deletes",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "b", deleted: true),
                 expect: .takeRemote),
            Case(name: "older tombstone loses to live record",
                 local: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "b", deleted: true),
                 expect: .keepLocal),
            Case(name: "resurrect: live write after tombstone wins",
                 local: makeEnv(id: "x", at: base, device: "a", deleted: true),
                 remote: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "b", deleted: false),
                 expect: .takeRemote),
        ]
        for c in cases {
            XCTAssertEqual(mergeOutcome(local: c.local, remote: c.remote), c.expect, c.name)
        }
    }
}

// MARK: - 3. Photo dedup

final class PhotoDedupTests: XCTestCase {
    func testIdenticalBytesShareOneKey() async {
        let engine = SyncEngine(deviceId: "d",
            transport: FakeTransport(server: FakeServer()))
        let bytes = Data("fake-jpeg-bytes".utf8)
        let first = await engine.photoKey(for: bytes)
        let second = await engine.photoKey(for: bytes)
        XCTAssertNotNil(first) // first upload gets a key
        XCTAssertNil(second) // second is a dedup hit
        XCTAssertEqual(first, "photos/" + sha256Hex(of: bytes) + ".jpg")
    }

    func testDifferentBytesGetDifferentKeys() async {
        let engine = SyncEngine(deviceId: "d",
            transport: FakeTransport(server: FakeServer()))
        let k1 = await engine.photoKey(for: Data("photo-one".utf8))
        let k2 = await engine.photoKey(for: Data("photo-two".utf8))
        XCTAssertNotNil(k1)
        XCTAssertNotNil(k2)
        XCTAssertNotEqual(k1, k2)
    }
}
