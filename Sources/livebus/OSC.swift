import Foundation

enum OSCArg {
    case int(Int32), float(Float), double(Double), string(String), bool(Bool), none

    var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .float(let v): return Int(v)
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return Double(v)
        case .double(let v): return v
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let v): return String(v)
        case .float(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .double(let v): return String(v)
        default: return nil
        }
    }
}

struct OSCMessage {
    let address: String
    let args: [OSCArg]
}

enum OSCParser {
    static func parse(_ d: [UInt8]) -> [OSCMessage] {
        var out: [OSCMessage] = []
        parse(d, into: &out, depth: 0)
        return out
    }

    private static func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    private static func string(_ d: [UInt8], _ i: inout Int) -> String? {
        guard i < d.count, let end = d[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: d[i..<end], as: UTF8.self)
        i = (end + 4) & ~3
        return s
    }

    private static func parse(_ d: [UInt8], into out: inout [OSCMessage], depth: Int) {
        var i = 0
        guard depth < 8, let addr = string(d, &i) else { return }
        if addr == "#bundle" {
            i += 8 // time tag
            while i + 4 <= d.count {
                let size = Int(u32(d, i)); i += 4
                guard size > 0, i + size <= d.count else { return }
                parse(Array(d[i..<i + size]), into: &out, depth: depth + 1)
                i += size
            }
            return
        }
        var args: [OSCArg] = []
        if i < d.count, d[i] == UInt8(ascii: ","), let tags = string(d, &i) {
            tagLoop: for t in tags.dropFirst() {
                switch t {
                case "i":
                    guard i + 4 <= d.count else { break tagLoop }
                    args.append(.int(Int32(bitPattern: u32(d, i)))); i += 4
                case "f":
                    guard i + 4 <= d.count else { break tagLoop }
                    args.append(.float(Float(bitPattern: u32(d, i)))); i += 4
                case "d":
                    guard i + 8 <= d.count else { break tagLoop }
                    let bits = UInt64(u32(d, i)) << 32 | UInt64(u32(d, i + 4))
                    args.append(.double(Double(bitPattern: bits))); i += 8
                case "h":
                    guard i + 8 <= d.count else { break tagLoop }
                    let bits = UInt64(u32(d, i)) << 32 | UInt64(u32(d, i + 4))
                    args.append(.int(Int32(truncatingIfNeeded: Int64(bitPattern: bits)))); i += 8
                case "s", "S":
                    guard let s = string(d, &i) else { break tagLoop }
                    args.append(.string(s))
                case "T": args.append(.bool(true))
                case "F": args.append(.bool(false))
                case "N", "I": args.append(.none)
                default: break tagLoop
                }
            }
        }
        out.append(OSCMessage(address: addr, args: args))
    }
}

/// Server UDP OSC, solo su 127.0.0.1.
final class OSCServer {
    private let fd: Int32
    private let handler: (OSCMessage) -> Void
    private var closed = false

    /// Chiude il socket: il thread di ricezione esce da solo.
    func stop() {
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    deinit { stop() }

    init(port: UInt16, handler: @escaping (OSCMessage) -> Void) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw LBError("could not open the OSC socket") }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else {
            close(sock)
            throw LBError("OSC port \(port) already in use: another livebus is probably running. "
                + "Stop it with Ctrl-C in its terminal (or: pkill -f \"livebus run\"), then try again.")
        }
        fd = sock
        self.handler = handler
    }

    func start() {
        let fd = self.fd, handler = self.handler
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n < 0 { if errno == EINTR { continue }; return }  // EBADF dopo stop()
                if n == 0 { continue }
                for m in OSCParser.parse(Array(buf[0..<n])) { handler(m) }
            }
        }
        t.name = "livebus.osc"
        t.start()
    }
}
