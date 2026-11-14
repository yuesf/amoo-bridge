import Foundation

// ADB 驱动手机上的 Amoo App 自己发消息，再从界面读回模型回复。
// 不经过 18789 / 8765 等本地网关：那些请求会被 Amoo 拦截。
// 锁屏/息屏走 Amoo 自带的锁屏聊天卡片，解锁走聊天页；都不需要 PIN。

final class AmooDriver {

    struct Node {
        let cls: String
        let id: String
        let text: String
        let desc: String
        let bounds: String
        let clickable: Bool
    }

    enum DriverError: Error, CustomStringConvertible {
        case adbFailed(String)
        case notReady(String)
        case dumpFailed
        case textNotFilled
        case sendButtonMissing
        case sendNotConfirmed
        case lockCardFailed
        case timeout(String)

        var description: String {
            switch self {
            case .adbFailed(let s): return "adb 命令失败：\(s)"
            case .notReady(let s): return s
            case .dumpFailed: return "无法读取手机界面（uiautomator dump 失败）"
            case .textNotFilled: return "文本未能填入 Amoo 输入框"
            case .sendButtonMissing: return "找不到 Amoo 的发送按钮"
            case .sendNotConfirmed: return "未确认消息已发出"
            case .lockCardFailed: return "无法打开 Amoo 的锁屏聊天卡片"
            case .timeout(let s):
                return "等待 Amoo 回复超时（45 秒上限）"
                    + (s.isEmpty ? "，未收到回复事件（手机端会话可能被云端中断，重试一次通常能恢复）"
                                 : "，最后看到：\(s)")
            }
        }
    }

    private let adb: String
    private let serial: String
    // 本次请求的绝对截止点；连单条 adb 命令也不许越过它
    private var deadline: Date = .distantFuture
    private let wakeReceiver = "com.stepos.ailauncher/.chat.wake.StartBroadcastReceiver"
    // 已解锁时把 Amoo 聊天页拉到前台：uiautomator dump 会等 UI idle，
    // 抖音这类一直在动的 App 会让 dump 挂满 10s 超时；切到 Amoo 后 dump 稳定 2.1s。
    private let chatActivity = "com.stepos.ailauncher/.chat.activity.ChatMainActivity"
    // 界面是有状态的，一次只允许一条消息在跑，避免并发把聊天页搞乱
    // 静态锁：Gateway 每次请求会新建 driver 实例，锁必须跨实例共享
    private static let sharedLock = NSLock()

    init(adb: String, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    // MARK: - 设备是否可自动发送

    // 锁屏 / 息屏也能发：只要 adb 在线即可，其余交给锁屏聊天卡片处理
    func ready() -> (Bool, String) {
        let devs = run(["devices"])
        guard devs.contains(serial), devs.contains("\tdevice") else {
            return (false, "adb 未连接设备 \(serial)")
        }
        return (true, "设备已连接 · 锁屏与亮屏均可发消息")
    }

    private func isLocked() -> Bool {
        run(["shell", "dumpsys", "trust"]).contains("deviceLocked=1")
    }




    // adb 会把参数拼成一条设备端 shell 命令执行，文本里的空格会被拆成多个词，
    // Amoo 只收到第一个词（实测 21 字 → len=10，等于被砍到第一个空格前）。
    // 所以必须自己做一层单引号转义再拼进去。
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 发一条消息并等回复

    // 45 秒上限：手机休眠后 OpenClaw/AgentBus 到云端的会话要重连（约 11s）+ 云端模型冷启动（约 20s），
    // 首条实测约 37s；15 秒会把冷启动误判成超时并触发客户端重试（曾出现 69 秒 + 报错）。
    // 会话热起来后 3–6 秒即返回，超时只是上限，不会拖慢正常请求。
    func send(_ text: String, timeout: TimeInterval = 45) -> Result<String, DriverError> {
        // 从请求进入就开始计时：排队、adb 命令、等云端事件、读界面全受同一个截止点约束
        let due = Date().addingTimeInterval(timeout)
        deadline = due
        func left() -> TimeInterval { max(0, due.timeIntervalSinceNow) }

        AmooDriver.sharedLock.lock()
        defer { AmooDriver.sharedLock.unlock() }
        // 排在后面的请求不能因为等锁而越过截止点（45 秒）
        guard left() > 0.5 else { return .failure(.timeout("")) }

        let (ok, why) = ready()
        guard ok else { return .failure(.notReady(why)) }

        let locked = isLocked()

        if locked {
            // 锁屏 / 息屏：一次 adb 完成唤醒 + 打开 Amoo 自带的锁屏聊天卡片（不需要 PIN、不需要解锁）
            //
            // 卡片有时会被密码界面挡住（刚息屏时锁屏动画还在跑），第一轮探测不到就重发一次唤醒。
            // 探测成功只说明卡片 Activity 在栈里，不保证它已经渲染出输入框，
            // 所以后面读回复时还要校验气泡文本在不在（见下）。
            var cardReady = false
            for _ in 0..<2 {
                let wakeCmd = "input keyevent 224; am broadcast -a com.stepos.ailauncher.action.AI_KEY_WAKE -n \(wakeReceiver)"
                _ = run(["shell", wakeCmd])
                for _ in 0..<20 {
                    guard left() > 0 else { break }
                    let win = run(["shell", "dumpsys", "window"])
                    if win.contains("LockScreenChatSheetActivity") { cardReady = true; break }
                    Thread.sleep(forTimeInterval: min(0.1, left()))
                }
                if cardReady { break }
                Thread.sleep(forTimeInterval: min(0.3, left()))
            }
            guard left() > 0 else { return .failure(.timeout("")) }
            guard cardReady else { return .failure(.lockCardFailed) }
        } else {
            // 已解锁：把 Amoo 聊天页拉到前台，然后直接用 CARD_SEND_TEXT 广播发送。
            //
            // 旧实现走「SEND intent 填 ShareActivity → dump 确认输入框 → 找按钮坐标 → tap」，
            // 要 2 次 dump + 1.2s 固定等待，实测光是"准备"就 5s；更糟的是 dump 会被
            // 前台 App（抖音等）的持续动画拖到挂满 10s 超时，一次请求能拖到 60s+。
            //
            // 实测（CARD_SEND_TEXT 广播对解锁态同样有效，云端 1.9s 就回）：
            //   切 ChatMainActivity + 广播 + 事件驱动 → 5.0–6.0s（平均 5.4s），4/4 成功
            // 切前台还顺带保证后面的 dump 稳定在 2.1s（Amoo 界面静止，不会等 idle 超时）。
            //
            // 先收起通知栏：通知栏展开时 Amoo 的卡片消息会被漏掉（实测第一条直接 45s 无回复，
            // 重发才救回来）。cmd statusbar collapse 约 0.2s，很便宜。
            _ = run(["shell", "cmd", "statusbar", "collapse"])
            let started = run(["shell", "am", "start", "-n", chatActivity])
            if started.contains("Error:") { return .failure(.adbFailed(started)) }
            // 给界面一点点时间完成首帧布局；不 dump，只等固定极短时间
            Thread.sleep(forTimeInterval: min(0.25, left()))
            guard left() > 0 else { return .failure(.timeout("")) }
        }

        // 云端回复由 Amoo 自己的 logcat 埋点 event=cloud.response.first 通知。
        // 不再每 1.5s 做一次 2.4s 的界面 dump 轮询，也不再为「连续两次一致」多等一轮。
        _ = run(["logcat", "-c"])
        let waiter = ReplyEventWaiter(adb: adb, serial: serial)
        waiter.start()

        // 发送动作：锁屏卡片和解锁态聊天页都用 CARD_SEND_TEXT 广播直接发。
        // 实测解锁态下该广播同样有效（logcat 有 cardSendText.input，云端 1.9s 就回）。
        // card_text 必须自己加引号，否则带空格的提问会被设备端 shell 拆词，Amoo 只收到第一个词。
        let sendCmd = "am broadcast -a com.stepos.ailauncher.action.CARD_SEND_TEXT"
            + " -n \(wakeReceiver) --es card_text \(shellQuote(text))"
        let sent = run(["shell", sendCmd])
        // 长文本会让 am broadcast 直接失败；立刻报错，别白等到超时
        if sent.contains("Error") || sent.contains("Exception") {
            waiter.stop()
            return .failure(.adbFailed(String(sent.prefix(200))))
        }

        // 等云端回复事件。实时 logcat 流偶尔会漏掉这一行（实测 8 次里丢 1 次的表现），
        // 但 `logcat -d` 事后读缓冲区一定读得到，所以两条路并行，谁先到算谁。
        let skip: Set<String> = ["正在思考中", "已完成", "发消息或按住说话", "发消息", "换一个"]
        let matchKey = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))

        func readReply() -> Result<String, DriverError> {
            var lastCandidate = ""
            for _ in 0..<4 {
                guard left() > 0 else { break }
                guard let nodes = dumpUI() else {
                    Thread.sleep(forTimeInterval: min(0.3, left())); continue
                }
                let sentIdx = nodes.lastIndex(where: {
                    $0.id == "tvSentMessage"
                        && String($0.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(matchKey.count)) == matchKey
                })
                guard let sentIdx = sentIdx else {
                    // 读到的是别的界面（密码框 / 桌面），不是 Amoo 聊天页。
                    // 锁屏时最常见：锁屏动画把卡片盖住了。这时重新唤醒一次并等界面切回来。
                    let texts = nodes.compactMap { $0.text.isEmpty ? nil : $0.text }
                    let wrongScreen = texts.contains("输入密码")
                        || !nodes.contains { $0.id == "chat_list" || $0.id == "ail_sheet_root" }
                    if wrongScreen, locked {
                        let wakeCmd = "input keyevent 224; am broadcast -a com.stepos.ailauncher.action.AI_KEY_WAKE -n \(wakeReceiver)"
                        _ = run(["shell", wakeCmd])
                        Thread.sleep(forTimeInterval: min(0.5, left()))
                        continue
                    }
                    Thread.sleep(forTimeInterval: min(0.3, left()))
                    continue
                }
                let candidates = nodes[(sentIdx + 1)...]
                    .filter { $0.cls == "TextView" }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 2 && !skip.contains($0) }
                if let c = candidates.last, !c.isEmpty {
                    // 即使读到了回复，越过截止点也算超时，不把迟到结果当成功返回
                    guard left() > 0 else { break }
                    return .success(c)
                }
                lastCandidate = candidates.last ?? ""
                Thread.sleep(forTimeInterval: min(0.3, left()))
            }
            return .failure(.timeout(lastCandidate))
        }

        // 第一轮：等事件 + 读回复
        let gotEvent = waitReplyEvent(waiter: waiter, deadline: due, cap: 14)
        if gotEvent, left() > 0 {
            let result = readReply()
            if case .success = result { waiter.stop(); return result }
            if case .failure(let e) = result, case .timeout = e {
                // 事件到了但界面还没渲染出回复，再多等一轮
                waiter.stop()
                let second = readReply()
                if case .success = second { return second }
                if case .failure(let e2) = second { return .failure(e2) }
            }
            waiter.stop()
            return result
        }
        waiter.stop()

        // 第二轮：事件没来（实时流漏了、或 Amoo 侧会话被拆）。
        // 先看界面有没有回复 —— 有就直接用，事件只是丢了。
        let uiResult = readReply()
        if case .success(let reply) = uiResult { return .success(reply) }
        guard left() > 1 else { return .failure(.timeout("")) }

        // 界面也没有 → 重发一次。实测重发能救回被拆掉的云端会话。
        let retryCmd = "am broadcast -a com.stepos.ailauncher.action.CARD_SEND_TEXT"
            + " -n \(wakeReceiver) --es card_text \(shellQuote(text))"
        _ = run(["shell", retryCmd])
        let waiter2 = ReplyEventWaiter(adb: adb, serial: serial)
        waiter2.start()
        let gotEvent2 = waitReplyEvent(waiter: waiter2, deadline: due)
        if gotEvent2, left() > 0 {
            let result2 = readReply()
            waiter2.stop()
            return result2
        }
        waiter2.stop()

        // 重发也没等到事件：最后再扫一遍界面（消息可能已经渲染出来了，只是事件丢了）
        let finalResult = readReply()
        if case .success(let reply) = finalResult { return .success(reply) }
        return .failure(.timeout(""))
    }

    // MARK: - ADB / UI 工具

    // 等 Amoo 的云端回复事件。
    //
    // 两条路并行：
    //   A) ReplyEventWaiter 的实时 logcat 流——最快，通常 2–4 秒就命中
    //   B) 定期 `logcat -d` 读设备缓冲区——实时流漏了也能补回来
    // 实测实时流偶尔整条事件都收不到（缓冲里明明有），只有 B 能兜住。
    //
    // `cap` 给首次等待封顶：云端会话偶尔会被拆掉、事件根本不会来，
    // 那时早一点进入重发分支，比干等到 45 秒超时强得多。
    private func waitReplyEvent(waiter: ReplyEventWaiter, deadline due: Date,
                                cap: TimeInterval? = nil) -> Bool {
        let marker = "event=cloud.response.first"
        let pollEvery: TimeInterval = 1.0
        var nextPoll = Date().addingTimeInterval(pollEvery)
        let hardStop = cap.map { min(due, Date().addingTimeInterval($0)) } ?? due
        while Date().timeIntervalSince(hardStop) < 0 {
            // 实时流最多等 1 秒就主动查一次缓冲区
            let remaining = hardStop.timeIntervalSinceNow
            if remaining <= 0 { break }
            if waiter.wait(timeout: min(pollEvery, remaining)) { return true }
            if Date() >= nextPoll {
                nextPoll = Date().addingTimeInterval(pollEvery)
                let buf = run(["logcat", "-d", "-v", "time"], timeout: 3)
                if buf.contains(marker) { return true }
            }
        }
        return false
    }

    private func run(_ args: [String], timeout: TimeInterval = 12) -> String {
        // 用容错解码：adb 输出里的中文可能在超时截断时切在多字节字符中间，
        // 严格解码会整块失败返回空串。转成 String 只用于文本判断，截断不影响。
        String(decoding: runData(args, timeout: timeout), as: UTF8.self)
    }

    private func runData(_ args: [String], timeout: TimeInterval = 12) -> Data {
        // 单条 adb 命令也不能越过本次请求的截止点
        let limit = min(timeout, max(0.1, deadline.timeIntervalSinceNow))
        guard limit > 0.1, FileManager.default.isExecutableFile(atPath: adb) else { return Data() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["-s", serial] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return Data() }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            if task.isRunning { task.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return data
    }

    private func dumpUI() -> [Node]? {
        // 一次 adb 把 XML 直接输出到 stdout，省掉 pull + rm 两次进程。
        // 尾部会附一行 "UI hierchary dumped to: /dev/tty"，必须截断后才能交给 XMLParser。
        //
        // 超时给 5s：uiautomator 会等 UI 空闲，前台 App 持续动画时它会挂到自身 10s 超时，
        // 这里宁可提前失败重试，也不要让一次 dump 吃掉整个请求预算。
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</hierarchy>".utf8)
        for _ in 0..<2 {
            let raw = runData(["exec-out", "uiautomator", "dump", "/dev/tty"], timeout: 5)
            guard let start = raw.range(of: xmlStart),
                  let end = raw.range(of: xmlEnd),
                  start.lowerBound <= end.lowerBound else { continue }
            let xml = raw[start.lowerBound..<end.upperBound]
            if let nodes = parseUI(Data(xml)), !nodes.isEmpty { return nodes }
        }
        return nil
    }

    private func parseUI(_ data: Data) -> [Node]? {
        let parser = XMLParser(data: data)
        let collector = NodeCollector()
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.nodes
    }

    private final class NodeCollector: NSObject, XMLParserDelegate {
        var nodes: [Node] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard elementName == "node" else { return }
            let cls = (attributeDict["class"] ?? "").split(separator: ".").last.map(String.init) ?? ""
            let rid = (attributeDict["resource-id"] ?? "").split(separator: "/").last.map(String.init) ?? ""
            nodes.append(Node(cls: cls, id: rid,
                              text: attributeDict["text"] ?? "",
                              desc: attributeDict["content-desc"] ?? "",
                              bounds: attributeDict["bounds"] ?? "",
                              clickable: attributeDict["clickable"] == "true"))
        }
    }
}

// 监听 Amoo 自己的云端回复埋点，替代「定时反复 dump 界面」。
// 事件到达只作为「可以去读界面」的信号，回复正文仍从 UI 取，不猜测、不伪造。
private final class ReplyEventWaiter {
    private let task = Process()
    private let pipe = Pipe()
    private let errPipe = Pipe()
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var found = false
    private var buffer = Data()
    private var started = false

    // 标记是纯 ASCII，直接在原始字节上搜。
    // 不用 String(data:encoding:.utf8) 解码：readabilityHandler 给的是任意字节块，
    // 块边界切在中文多字节字符中间时解码会返回 nil，整块日志被丢掉，
    // 事件行就随它一起丢了（表现为偶发收不到回复）。
    private static let marker = Data("event=cloud.response.first".utf8)

    init(adb: String, serial: String) {
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["-s", serial, "logcat", "-v", "time"]
        task.standardOutput = pipe
        task.standardError = errPipe
    }

    func start() {
        // stderr 必须有人读：logcat 的错误输出写满管道缓冲区后进程会阻塞，
        // 连带 stdout 也收不到，事件就永远等不来。
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.found else { return }
            self.buffer.append(data)
            if self.buffer.range(of: ReplyEventWaiter.marker) != nil {
                self.found = true
                self.buffer.removeAll()
                self.sem.signal()
            }
        }
        do { try task.run(); started = true } catch { started = false }
    }

    func wait(timeout: TimeInterval) -> Bool {
        guard started else { return false }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); let f = found; lock.unlock()
        return f
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        if task.isRunning { task.terminate(); task.waitUntilExit() }
    }
}
