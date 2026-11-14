import AppKit
import WebKit
import Foundation
import Darwin

// Amoo Bridge for Mac —— 按 amoo-bridge-site 的产品思路做的本机实现。
// 界面：AppKit 窗口 + WKWebView（Resources/index.html）
// 网关：仅监听 127.0.0.1 的 OpenAI 兼容 HTTP 服务

let kBundleID = "local.amoo.bridge.mac"
let kVersion = "1.0.0"

// MARK: - 配置

enum Store {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "ab.port": 8788,
            "ab.apiKey": "sk-amoo",
            "ab.model": "amoo-phone",
            "ab.upstream": "",
            "ab.autoStart": true,
            "ab.autoConnect": true,
            "ab.phonePort": 8080,
            "ab.adbPath": ""
        ])
    }
    static var port: Int { d.object(forKey: "ab.port") as? Int ?? 8788 }
    static var apiKey: String { d.string(forKey: "ab.apiKey") ?? "sk-amoo" }
    static var model: String { d.string(forKey: "ab.model") ?? "amoo-phone" }
    static var upstream: String { d.string(forKey: "ab.upstream") ?? "" }
    static var autoStart: Bool { d.bool(forKey: "ab.autoStart") }
    static var autoConnect: Bool { d.bool(forKey: "ab.autoConnect") }
    static var phonePort: Int { d.object(forKey: "ab.phonePort") as? Int ?? 8080 }
    static var adbPath: String { d.string(forKey: "ab.adbPath") ?? "" }
}

// MARK: - 极简 HTTP 请求解析

struct HTTPReq {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ raw: Data) -> HTTPReq? {
        let bytes = [UInt8](raw)
        var headEnd = -1
        if bytes.count >= 4 {
            for i in 0...(bytes.count - 4) {
                if bytes[i] == 13 && bytes[i+1] == 10 && bytes[i+2] == 13 && bytes[i+3] == 10 {
                    headEnd = i + 4
                    break
                }
            }
        }
        guard headEnd > 0 else { return nil }
        let headData = raw.subdata(in: 0..<headEnd)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var hs: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                hs[k] = v
            }
        }
        let bodyStart = headEnd
        let body: Data
        if (hs["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            // Node/undici 发大请求体时常用 chunked；没收到终止块就等下一次 recv
            guard let decoded = decodeChunked(raw.subdata(in: bodyStart..<raw.count)) else {
                return nil
            }
            body = decoded
        } else {
            let need = Int(hs["content-length"] ?? "0") ?? 0
            guard raw.count >= bodyStart + need else { return nil }
            body = raw.subdata(in: bodyStart..<(bodyStart + need))
        }
        return HTTPReq(method: parts[0], path: parts[1], headers: hs, body: body)
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var out = Data()
        var i = 0
        while true {
            var j = i
            while j + 1 < b.count, !(b[j] == 13 && b[j+1] == 10) { j += 1 }
            guard j + 1 < b.count else { return nil }
            let line = String(decoding: b[i..<j], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let hex = line.components(separatedBy: ";").first ?? line
            guard let size = Int(hex, radix: 16) else { return nil }
            i = j + 2
            if size == 0 { return out }
            guard i + size + 2 <= b.count else { return nil }
            out.append(contentsOf: b[i..<(i + size)])
            i += size + 2
        }
    }
}

// MARK: - 本机网关

protocol GatewayDelegate: AnyObject {
    func gatewayDidChange()
    func gatewayDidFail(_ message: String)
}

final class Gateway {
    weak var delegate: GatewayDelegate?
    private(set) var isRunning = false
    private(set) var actualPort = 0
    private(set) var requestCount = 0

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private let session = URLSession(configuration: .default)

    // USB 自动连接成功后由 DeviceMonitor 写入，优先于手动填写的上游地址
    var usbUpstream = ""
    // USB 已就绪时，消息走 ADB 驱动 Amoo App 自己发，不再转发到本地网关端口
    var usbDevice: DeviceSnapshot?
    var effectiveUpstream: String { usbUpstream.isEmpty ? Store.upstream : usbUpstream }
    var mode: String {
        if !usbUpstream.isEmpty { return "usb" }
        return Store.upstream.isEmpty ? "demo" : "upstream"
    }
    private var amooDriver: AmooDriver? {
        guard let d = usbDevice, d.forwarded, Store.autoConnect,
              !d.adbPath.isEmpty, !d.serial.isEmpty else { return nil }
        return AmooDriver(adb: d.adbPath, serial: d.serial)
    }

    func start(preferred: Int) {
        stop()
        var p = max(1, min(65535, preferred))
        var lastErr = ""
        for _ in 0..<20 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { lastErr = "socket 创建失败"; break }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(p).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc != 0 {
                lastErr = "端口 \(p) 被占用"
                close(fd)
                p += 1
                if p > 65535 { break }
                continue
            }
            guard listen(fd, 16) == 0 else {
                lastErr = "端口 \(p) 监听失败"
                close(fd)
                p += 1
                continue
            }
            listenFD = fd
            actualPort = p
            isRunning = true
            let t = Thread { [weak self] in self?.acceptLoop(fd: fd) }
            t.stackSize = 256 * 1024
            acceptThread = t
            t.start()
            delegate?.gatewayDidChange()
            return
        }
        delegate?.gatewayDidFail("未能启动网关：\(lastErr)")
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        isRunning = false
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        acceptThread = nil
        delegate?.gatewayDidChange()
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var noSig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(client: client)
            }
        }
    }

    private func serve(client: Int32) {
        defer { close(client) }
        let started = Date()
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var req: HTTPReq?
        var headerChecked = false
        for _ in 0..<64 {
            let cap = buf.count
            let n = buf.withUnsafeMutableBytes { recv(client, $0.baseAddress, cap, 0) }
            if n <= 0 { return }
            raw.append(buf, count: n)
            // 带 Expect: 100-continue 的客户端会先只发请求头、等确认再发 body。
            // 不回 100 Continue 就会两边互等，连接一直挂着直到客户端超时。
            if !headerChecked, let end = headerEnd(raw) {
                headerChecked = true
                let head = String(data: raw.subdata(in: 0..<end), encoding: .utf8)?.lowercased() ?? ""
                if head.contains("expect: 100-continue") {
                    let ack = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
                    ack.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                        if let b = p.baseAddress { _ = send(client, b, ack.count, 0) }
                    }
                }
            }
            if let r = HTTPReq.parse(raw) { req = r; break }
            if raw.count > 4 * 1024 * 1024 { return }
        }
        guard let r = req else { return }
        lock.lock(); requestCount += 1; lock.unlock()
        let (code, payload) = route(r)
        // 聊天客户端默认带 stream:true，必须回 SSE，否则它们按流解析会拿不到任何内容
        if wantsStream(r) && code >= 200 && code < 300 {
            sendResponse(client: client, code: 200, body: sseFromCompletion(payload),
                         contentType: "text/event-stream; charset=utf-8")
        } else {
            sendResponse(client: client, code: code, body: payload)
        }
        logRequest(r, code: code, ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    private func headerEnd(_ data: Data) -> Int? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) {
            if b[i] == 13 && b[i+1] == 10 && b[i+2] == 13 && b[i+3] == 10 { return i + 4 }
        }
        return nil
    }

    // 临时诊断日志：确认客户端真实请求形态（/tmp，不进项目目录）
    private static let logLock = NSLock()
    private func logRequest(_ r: HTTPReq, code: Int, ms: Int) {
        let pick = { (k: String) -> String in r.headers[k] ?? "-" }
        let bodyHead = String(data: r.body.prefix(160), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ") ?? ""
        let line = "\(Date()) \(r.method) \(r.path) code=\(code) ms=\(ms) "
            + "len=\(pick("content-length")) te=\(pick("transfer-encoding")) "
            + "expect=\(pick("expect")) accept=\(pick("accept")) "
            + "body=\(bodyHead)\n"
        Gateway.logLock.lock(); defer { Gateway.logLock.unlock() }
        let url = URL(fileURLWithPath: "/tmp/amoo-gateway.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        // 保留最后一次聊天请求的完整 body，便于核对客户端把用户输入放在哪里
        if r.method == "POST" && r.path.contains("chat/completions") {
            try? r.body.write(to: URL(fileURLWithPath: "/tmp/amoo-last-body.json"))
        }
    }

    private func wantsStream(_ r: HTTPReq) -> Bool {
        guard r.method == "POST",
              r.path.split(separator: "?").first.map(String.init) == "/v1/chat/completions",
              let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let flag = obj["stream"] else { return false }
        if let b = flag as? Bool { return b }
        if let n = flag as? NSNumber { return n.boolValue }
        if let s = flag as? String { return s.lowercased() == "true" }
        return false
    }

    // Amoo 的回复是一次性读回的，包装成 OpenAI 兼容的两帧 chunk + [DONE]
    private func sseFromCompletion(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            return "data: [DONE]\n\n".data(using: .utf8) ?? Data()
        }
        let base: [String: Any] = [
            "id": obj["id"] as? String ?? "chatcmpl-\(UUID().uuidString.prefix(12))",
            "object": "chat.completion.chunk",
            "created": obj["created"] as? Int ?? Int(Date().timeIntervalSince1970),
            "model": obj["model"] as? String ?? Store.model
        ]
        var first = base
        first["choices"] = [["index": 0,
                             "delta": ["role": "assistant", "content": content],
                             "finish_reason": NSNull()]]
        var last = base
        last["choices"] = [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]]
        var out = ""
        for chunk in [first, last] {
            if let d = try? JSONSerialization.data(withJSONObject: chunk),
               let s = String(data: d, encoding: .utf8) { out += "data: \(s)\n\n" }
        }
        out += "data: [DONE]\n\n"
        return out.data(using: .utf8) ?? Data()
    }

    private func sendResponse(client: Int32, code: Int, body: Data,
                              contentType: String = "application/json; charset=utf-8") {
        let status: String
        switch code {
        case 200: status = "200 OK"
        case 401: status = "401 Unauthorized"
        case 404: status = "404 Not Found"
        case 502: status = "502 Bad Gateway"
        default: status = "400 Bad Request"
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n\r\n"
        var bytes = Data(head.utf8)
        bytes.append(body)
        bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let n = send(client, base.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func jdata(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
    }

    private func errJSON(_ msg: String, type: String = "invalid_request_error") -> Data {
        jdata(["error": ["message": msg, "type": type, "code": "local_gateway"]])
    }

    private func route(_ r: HTTPReq) -> (Int, Data) {
        let path = r.path.split(separator: "?").first.map(String.init) ?? r.path

        if path == "/health" || path == "/v1/health" {
            return (200, jdata(["status": "ok", "mode": mode, "port": actualPort,
                                "model": Store.model, "upstream": effectiveUpstream]))
        }

        // 浏览器客户端会先发不带 Authorization 的 CORS 预检，不能让鉴权把它挡掉
        if r.method == "OPTIONS" {
            return (200, jdata(["status": "ok"]))
        }

        // 本地网关的 API Key 校验
        let expected = "Bearer \(Store.apiKey)"
        if r.headers["authorization"] != expected {
            return (401, errJSON("API Key 不正确，应为 \(Store.apiKey)", type: "authentication_error"))
        }

        if path == "/v1/models" && r.method == "GET" {
            return (200, jdata([
                "object": "list",
                "data": [["id": Store.model, "object": "model", "owned_by": "local"]]
            ]))
        }

        if path == "/v1/chat/completions" && r.method == "POST" {
            return handleChat(r.body)
        }

        return (404, errJSON("未知接口：\(r.method) \(path)"))
    }

    // Agent 客户端会把完整系统提示 + 工具定义 + 会话历史塞进一条消息（可达十几万字符）。
    // 手机 Amoo 是聊天输入框，只应该收到用户真正说的那句话。
    private func userText(from messages: [[String: Any]]) -> (String, Bool) {
        // 逐条取出所有文本：客户端内部请求不一定带 role，指令也不一定在第一条
        var texts: [String] = []
        for m in messages {
            if let s = m["content"] as? String, !s.isEmpty { texts.append(s); continue }
            if let arr = m["content"] as? [[String: Any]] {
                for part in arr where (part["type"] as? String) == "text" {
                    if let s = part["text"] as? String, !s.isEmpty { texts.append(s) }
                }
            }
        }
        // 标题生成是客户端自动发起的，不该占用手机聊天通道和串行锁
        if texts.contains(where: { $0.hasPrefix("Generate a concise, sentence-case title") }) {
            return ("", true)
        }

        var raw = ""
        for m in messages.reversed() {
            guard (m["role"] as? String) == "user" else { continue }
            if let s = m["content"] as? String, !s.isEmpty { raw = s; break }
            if let arr = m["content"] as? [[String: Any]] {
                for part in arr where (part["type"] as? String) == "text" {
                    if let s = part["text"] as? String, !s.isEmpty { raw = s; break }
                }
                if !raw.isEmpty { break }
            }
        }
        // 兜底：有些客户端不在消息里写 role
        if raw.isEmpty { raw = texts.last ?? "" }

        // WorkBuddy 用 <user_query> 标记用户输入，取最后一段
        if let open = raw.range(of: "<user_query>", options: .backwards),
           let close = raw.range(of: "</user_query>", options: .backwards),
           close.lowerBound > open.upperBound {
            let s = String(raw[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { raw = s }
        }
        // 客户端会把上下文提醒一起塞进用户输入，去掉后再发给手机
        while let a = raw.range(of: "<system-reminder"),
              let b = raw.range(of: "</system-reminder>", range: a.upperBound..<raw.endIndex) {
            raw.removeSubrange(a.lowerBound..<b.upperBound)
        }
        if raw.count > 1000 { raw = String(raw.suffix(1000)) }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }

    private func handleChat(_ body: Data) -> (Int, Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (400, errJSON("请求体不是合法 JSON"))
        }
        let messages = obj["messages"] as? [[String: Any]] ?? []
        let (last, isMeta) = userText(from: messages)
        let model = obj["model"] as? String ?? Store.model

        var content: String
        if isMeta {
            // 标题生成是客户端内部请求，本地直接给标题，不驱动手机、不占串行锁
            content = "新会话"
        } else if let driver = amooDriver {
            guard !last.isEmpty else { return (400, errJSON("没有可发送的用户消息")) }
            switch driver.send(last) {
            case .success(let reply):
                content = reply
            case .failure(let e):
                return (502, errJSON("Amoo 发消息失败：\(e.description)", type: "amoo_error"))
            }
        } else if effectiveUpstream.isEmpty {
            content = "[演示模式] 本机网关已收到：「\(last)」\n\n当前未接入手机端设备。用 USB 接入手机并开启 USB 调试后会自动连接；也可在「设置」页手动填设备端上游地址。"
        } else {
            let (code, data) = forward(body)
            if code >= 200 && code < 300 { return (200, data) }
            var why = "无响应"
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let e = o["error"] as? [String: Any], let m = e["message"] as? String {
                why = m
            } else if let s = String(data: data.prefix(300), encoding: .utf8), !s.isEmpty {
                why = s
            }
            return (502, errJSON("设备端上游不可达或返回错误（HTTP \(code)）：\(why)", type: "upstream_error"))
        }

        let reply: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(12))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        ]
        return (200, jdata(reply))
    }

    private func forward(_ body: Data) -> (Int, Data) {
        let raw = effectiveUpstream
        let base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let url = URL(string: base + "/chat/completions") else {
            return (0, errJSON("设备端上游地址不是合法 URL"))
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, Data) = (0, errJSON("上游请求超时"))
        session.dataTask(with: req) { data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let payload = data ?? self.errJSON(error?.localizedDescription ?? "上游无响应")
            out = (code, payload)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 65)
        return out
    }

    // 应用内「发一条测试消息」走真实 HTTP，验证整条链路
    func testMessage(_ text: String, completion: @escaping (Bool, String) -> Void) {
        guard isRunning else { completion(false, "网关未启动"); return }
        let body = jdata(["model": Store.model, "messages": [["role": "user", "content": text]]])
        let url = URL(string: "http://127.0.0.1:\(actualPort)/v1/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: 70)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Store.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        session.dataTask(with: req) { data, resp, error in
            if let error = error { completion(false, error.localizedDescription); return }
            guard let data = data else { completion(false, "无响应"); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let text = msg["content"] as? String {
                completion(code >= 200 && code < 300, text)
            } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let e = obj["error"] as? [String: Any], let m = e["message"] as? String {
                completion(false, "HTTP \(code)：\(m)")
            } else {
                completion(false, "HTTP \(code)：\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            }
        }.resume()
    }

    // 连通性探测：USB 模式看 Amoo 是否可自动发送；手动上游模式看 /models 是否可达
    func probeUpstream(completion: @escaping (Bool) -> Void) {
        if let driver = amooDriver {
            DispatchQueue.global().async {
                let (ok, _) = driver.ready()
                completion(ok)
            }
            return
        }
        let raw = effectiveUpstream
        guard !raw.isEmpty else { completion(false); return }
        let base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let url = URL(string: base + "/models") else { completion(false); return }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "GET"
        session.dataTask(with: req) { _, resp, _ in
            completion((resp as? HTTPURLResponse) != nil)
        }.resume()
    }
}

// MARK: - USB 设备监听与自动连接

struct DeviceSnapshot {
    var usbPlugged = false
    var usbName = ""
    var adbFound = false
    var adbPath = ""
    var serial = ""
    var unauthorized = false
    var forwarded = false
    var localPort = 0
    var usbUpstream = ""
    var message = ""
}

protocol DeviceMonitorDelegate: AnyObject {
    func deviceDidUpdate(_ snap: DeviceSnapshot)
}

final class DeviceMonitor {
    weak var delegate: DeviceMonitorDelegate?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.amoo.bridge.usb")
    private var activeSerial = ""
    private var activePort = 0
    private var activeUpstream = ""

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() { timer?.invalidate(); timer = nil; queue.async { self.dropForward() } }

    // 配置变更后强制重新建立转发
    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.dropForward()
            self.tick()
        }
    }

    private func tick() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let snap = self.check()
            DispatchQueue.main.async { self.delegate?.deviceDidUpdate(snap) }
        }
    }

    private func check() -> DeviceSnapshot {
        let (plugged, name) = detectUSB()
        let adb = findADB()
        var s = DeviceSnapshot(usbPlugged: plugged, usbName: name,
                               adbFound: adb != nil, adbPath: adb ?? "")
        let devices = adb.map { deviceList($0) } ?? []
        s.unauthorized = devices.contains { $0.1 == "unauthorized" || $0.1 == "offline" }

        guard let adbPath = adb else {
            s.message = "未找到 adb：安装 Android platform-tools，或在设置页填 adb 路径"
            return s
        }
        guard Store.autoConnect else {
            dropForward(adbPath)
            s.message = "USB 自动连接已关闭"
            return s
        }
        // serial 含 ":" 的是 adb connect 的无线设备，不算 USB 接入
        guard let dev = devices.first(where: { $0.1 == "device" && !$0.0.contains(":") }) else {
            dropForward(adbPath)
            if s.unauthorized { s.message = "手机已插入 · 请在手机上点「允许 USB 调试」" }
            else if plugged {
                s.message = "USB 已插入但 adb 未识别（\(name.isEmpty ? "设备" : name)）· 请在手机上切到「传输文件」、开启 USB 调试后重新插拔"
            } else { s.message = "等待 USB 设备接入" }
            return s
        }

        s.serial = dev.0
        if activeSerial == dev.0 && activePort > 0 {
            s.forwarded = true
            s.localPort = activePort
            s.usbUpstream = activeUpstream
            s.message = "USB 已连接 · 自动转发中"
            return s
        }

        dropForward(adbPath)
        if let port = addForward(adbPath, serial: dev.0, phonePort: Store.phonePort) {
            activeSerial = dev.0
            activePort = port
            activeUpstream = "http://127.0.0.1:\(port)/v1"
            s.forwarded = true
            s.localPort = port
            s.usbUpstream = activeUpstream
            s.message = "USB 已连接 · 自动转发中"
        } else {
            s.message = "adb forward 失败 · 检查手机端服务端口 \(Store.phonePort)"
        }
        return s
    }

    private func dropForward(_ adb: String? = nil) {
        guard activePort > 0 else { return }
        if let path = adb ?? findADB() { _ = run(path, ["forward", "--remove", "tcp:\(activePort)"]) }
        activeSerial = ""
        activePort = 0
        activeUpstream = ""
    }

    private func addForward(_ adb: String, serial: String, phonePort: Int) -> Int? {
        let out = run(adb, ["-s", serial, "forward", "tcp:0", "tcp:\(phonePort)"])
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func deviceList(_ adb: String) -> [(String, String)] {
        var list: [(String, String)] = []
        for line in run(adb, ["devices"]).components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("List of") || t.hasPrefix("*") { continue }
            let parts = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2 { list.append((parts[0], parts[1])) }
        }
        return list
    }

    private func detectUSB() -> (Bool, String) {
        let out = run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0"])
        var names: [String] = []
        let key = "\"USB Product Name\" = \""
        for line in out.components(separatedBy: "\n") {
            guard let r = line.range(of: key) else { continue }
            let rest = String(line[r.upperBound...])
            if let end = rest.range(of: "\"") { names.append(String(rest[..<end.lowerBound])) }
        }
        let external = names.filter {
            !$0.contains("Root Hub") && !$0.contains("Bluetooth") &&
            !$0.contains("Hub") && !$0.contains("Apple")
        }
        return (!external.isEmpty, external.first ?? "")
    }

    private func findADB() -> String? {
        let fm = FileManager.default
        let custom = Store.adbPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty && fm.isExecutableFile(atPath: custom) { return custom }
        // 随项目一起分发的 platform-tools：<项目根>/tools/platform-tools/adb
        let projectRoot = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundled = projectRoot.appendingPathComponent("tools/platform-tools/adb").path
        if fm.isExecutableFile(atPath: bundled) { return bundled }
        let fixed = [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            NSHomeDirectory() + "/Android/Sdk/platform-tools/adb",
            "/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/opt/android-sdk/platform-tools/adb"
        ]
        for p in fixed where fm.isExecutableFile(atPath: p) { return p }
        for root in ["/opt/homebrew/Caskroom/android-platform-tools", "/usr/local/Caskroom/android-platform-tools"] {
            if let versions = try? fm.contentsOfDirectory(atPath: root) {
                for v in versions {
                    let p = root + "/" + v + "/platform-tools/adb"
                    if fm.isExecutableFile(atPath: p) { return p }
                }
            }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let p = String(dir) + "/adb"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func run(_ exe: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return "" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if task.isRunning { task.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler,
                         GatewayDelegate, NSWindowDelegate, DeviceMonitorDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private let gateway = Gateway()
    private let monitor = DeviceMonitor()
    private var device = DeviceSnapshot()
    private var upstreamOK = false
    private var probeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.register()
        gateway.delegate = self
        monitor.delegate = self
        buildWindow()
        buildStatusItem()
        startProbeTimer()

        if Store.autoStart { gateway.start(preferred: Store.port) }
        monitor.start()
        pushState()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        gateway.stop()
        probeTimer?.invalidate()
    }

    private func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "bridge")
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")

        if let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: nil) {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }

        let rect = NSRect(x: 0, y: 0, width: 980, height: 700)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Amoo Bridge for Mac"
        window.minSize = NSSize(width: 860, height: 620)
        window.center()
        window.setFrameAutosaveName("AmooBridgeMacWindow")
        window.contentView = webView
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◎"
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
        }
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let running = gateway.isRunning
        if statusItem.button?.image == nil {
            statusItem.button?.title = running ? "◉" : "◎"
        }
        let menu = NSMenu()
        let title = running ? "网关运行中 · 端口 \(gateway.actualPort)" : "网关已停止"
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let open = NSMenuItem(title: "打开窗口", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let toggle = NSMenuItem(title: running ? "停止网关" : "启动网关", action: #selector(toggleGateway), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func openWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleGateway() {
        if gateway.isRunning { gateway.stop() } else { gateway.start(preferred: Store.port) }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: 状态推送

    private func stateDict() -> [String: Any] {
        return [
            "version": kVersion,
            "running": gateway.isRunning,
            "port": gateway.actualPort,
            "configuredPort": Store.port,
            "apiKey": Store.apiKey,
            "model": Store.model,
            "upstream": gateway.effectiveUpstream,
            "manualUpstream": Store.upstream,
            "upstreamOK": upstreamOK,
            "mode": gateway.mode,
            "autoStart": Store.autoStart,
            "autoConnect": Store.autoConnect,
            "phonePort": Store.phonePort,
            "adbPath": Store.adbPath,
            "adbFound": device.adbFound,
            "adbDetectedPath": device.adbPath,
            "usbPlugged": device.usbPlugged,
            "usbName": device.usbName,
            "serial": device.serial,
            "unauthorized": device.unauthorized,
            "usbForwarded": device.forwarded,
            "usbLocalPort": device.localPort,
            "deviceMessage": device.message,
            "requestCount": gateway.requestCount
        ]
    }

    private func pushState() {
        guard let d = try? JSONSerialization.data(withJSONObject: stateDict()),
              let s = String(data: d, encoding: .utf8) else { return }
        callJS("window.onNative(\(s));")
        DispatchQueue.main.async { self.refreshStatusItem() }
    }

    private func event(_ type: String, ok: Bool, text: String) {
        let obj: [String: Any] = ["type": type, "ok": ok, "text": text]
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        callJS("window.onEvent(\(s));")
    }

    private func callJS(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script) { _, err in
                if let err = err { NSLog("[bridge js] \(err.localizedDescription)") }
            }
        }
    }

    // MARK: GatewayDelegate

    func gatewayDidChange() { DispatchQueue.main.async { self.pushState() } }

    func gatewayDidFail(_ message: String) {
        DispatchQueue.main.async {
            self.event("gateway", ok: false, text: message)
            self.pushState()
        }
    }

    // MARK: 上游探测（断线自动重连）

    func deviceDidUpdate(_ snap: DeviceSnapshot) {
        let wasConnected = device.forwarded
        device = snap
        gateway.usbUpstream = snap.usbUpstream
        gateway.usbDevice = snap
        if !wasConnected && snap.forwarded {
            // USB 充电时保持屏幕常亮：手机云端会话空闲约 20s 就冷掉（要 30s+ 重建），
            // 常亮后 OpenClaw keepalive 不断，首条之后稳定 3–6 秒。仅充电时生效，拔线即恢复。
            if !snap.adbPath.isEmpty {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: snap.adbPath)
                p.arguments = ["-s", snap.serial, "shell", "settings", "put",
                               "global", "stay_on_while_plugged_in", "7"]
                try? p.run()
                p.waitUntilExit()
            }
            event("usb", ok: true, text: "USB 已自动连接 · \(snap.serial) · 通过 Amoo 发消息")
            gateway.probeUpstream { [weak self] ok in
                DispatchQueue.main.async { self?.upstreamOK = ok; self?.pushState() }
            }
        } else if wasConnected && !snap.forwarded {
            upstreamOK = false
            event("usb", ok: false, text: "USB 连接已断开，等待重新接入")
        }
        pushState()
    }

    private func startProbeTimer() {
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, !self.gateway.effectiveUpstream.isEmpty else { return }
            self.gateway.probeUpstream { ok in
                DispatchQueue.main.async {
                    let changed = ok != self.upstreamOK
                    self.upstreamOK = ok
                    if changed {
                        self.pushState()
                        self.event("upstream", ok: ok,
                                   text: ok ? "设备端通道已就绪" : "设备端未就绪，正在自动重试")
                    }
                }
            }
        }
    }

    // MARK: JS -> Swift

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msg = message.body as? [String: Any], let action = msg["action"] as? String else { return }
        switch action {
        case "ready":
            pushState()
        case "start":
            gateway.start(preferred: Store.port)
            pushState()
        case "stop":
            gateway.stop()
            pushState()
        case "copy":
            if let text = msg["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                event("copy", ok: true, text: "已复制")
            }
        case "test":
            let text = msg["text"] as? String ?? "你好"
            event("test", ok: true, text: "正在通过本机网关发送…")
            gateway.testMessage(text) { [weak self] ok, result in
                DispatchQueue.main.async {
                    self?.event("testResult", ok: ok, text: result)
                    self?.pushState()
                }
            }
        case "save":
            saveSettings(msg)
        default:
            break
        }
    }

    private func saveSettings(_ msg: [String: Any]) {
        let port = (msg["port"] as? Int) ?? Store.port
        let key = (msg["apiKey"] as? String) ?? Store.apiKey
        let model = (msg["model"] as? String) ?? Store.model
        let upstream = (msg["upstream"] as? String) ?? Store.upstream
        let autoStart = (msg["autoStart"] as? Bool) ?? Store.autoStart
        let autoConnect = (msg["autoConnect"] as? Bool) ?? Store.autoConnect
        let phonePort = (msg["phonePort"] as? Int) ?? Store.phonePort
        let adbPath = (msg["adbPath"] as? String) ?? Store.adbPath
        guard (1...65535).contains(port), (1...65535).contains(phonePort),
              !key.isEmpty, !model.isEmpty else {
            event("save", ok: false, text: "端口 / 手机端端口需在 1–65535，API Key 和模型名不能为空")
            return
        }
        Store.d.set(port, forKey: "ab.port")
        Store.d.set(key, forKey: "ab.apiKey")
        Store.d.set(model, forKey: "ab.model")
        Store.d.set(upstream.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ab.upstream")
        Store.d.set(autoStart, forKey: "ab.autoStart")
        Store.d.set(autoConnect, forKey: "ab.autoConnect")
        Store.d.set(phonePort, forKey: "ab.phonePort")
        Store.d.set(adbPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ab.adbPath")
        upstreamOK = false
        if gateway.isRunning { gateway.start(preferred: port) }
        monitor.reset()
        pushState()
        event("save", ok: true, text: "设置已保存，网关与 USB 连接已按新配置重建")
    }
}

// MARK: - 入口（单实例）

Store.register()
signal(SIGPIPE, SIG_IGN)

let peers = NSRunningApplication.runningApplications(withBundleIdentifier: kBundleID)
    .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
if let running = peers.first {
    running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
