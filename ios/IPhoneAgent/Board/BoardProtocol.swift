import CoreBluetooth
import Foundation

/// GATT layout and message formats from docs/ble-protocol.md.
enum BoardUUID {
    static func make(_ suffix: String) -> CBUUID { CBUUID(string: "6e400001-a9e8-4b1b-9c39-6d6f8a3c" + suffix) }
    static let service = make("0000")
    static let cmd = make("0001")
    static let reply = make("0002")
    static let status = make("0003")
    static let all = [cmd, reply, status]
}

/// The 1 s JSON heartbeat on `status`.
struct BoardStatus: Codable, Equatable {
    struct BLE: Codable, Equatable { var mtu: Int?, phy: Int?, rdrop: Int?, n: Int? }
    var up: Int?
    var rst: String?
    var heap: Int?
    var hid: String?
    var hgen: UInt32?
    var ble: BLE?

    var inputState: String { hid ?? "off" }
    var inputReady: Bool { inputState == "ok" }

    static func decode(_ data: Data) -> BoardStatus? { try? JSONDecoder().decode(BoardStatus.self, from: data) }

    func merged(with newer: BoardStatus) -> BoardStatus {
        var result = newer
        result.up = newer.up ?? up; result.rst = newer.rst ?? rst; result.heap = newer.heap ?? heap
        result.hid = newer.hid ?? hid; result.hgen = newer.hgen ?? hgen
        let a = ble ?? BLE(), b = newer.ble ?? BLE()
        result.ble = BLE(mtu: b.mtu ?? a.mtu, phy: b.phy ?? a.phy, rdrop: b.rdrop ?? a.rdrop, n: b.n ?? a.n)
        return result
    }
}

/// A `reply` notify: `<id> ok [extra]` or `<id> err <reason>`.
struct BoardReply: Equatable {
    let id: Int
    let ok: Bool
    let text: String  // extra after "ok", or the error reason

    static func parse(_ line: String) -> BoardReply? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
            .map(String.init)
        guard parts.count >= 2, let id = Int(parts[0]), parts[1] == "ok" || parts[1] == "err" else { return nil }
        return BoardReply(id: id, ok: parts[1] == "ok", text: parts.count > 2 ? parts[2] : "")
    }
}
