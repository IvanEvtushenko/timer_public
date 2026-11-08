// Таймер в меню-баре macOS. Та же логика и тот же CSV, что у stopwatch.py:
// одна кнопка Старт/Пауза (Пробел), поле задачи, каждый непрерывный отрезок — строка в time_log.csv,
// «продолжить прошлую сессию», «завершить» = как закрытие окна раньше.
// Виден на всех рабочих столах и поверх полноэкранных окон. Открывается смахиванием
// от левого края трекпада, хоткеем ⌃⌥⌘T или кликом по значку в меню-баре.
// Живёт всегда: launchd поднимает его после любого выхода, а идущий интервал переживает
// перезапуск (state.json). Маркер «неполный день» — на сессию, отдельный файл рядом с логом.

import AppKit
import Carbon.HIToolbox

var logOverride: String? = nil     // только для --selftest / --snapshot: не трогаем настоящий лог
var stateOverride: String? = nil   // то же для файла состояния

// MARK: - Настройки:  defaults write com.ivanevtushenko.timer <ключ> <значение>
enum Config {
    private static let d = UserDefaults.standard
    static var logPath: String { logOverride ?? d.string(forKey: "logPath") ?? "~/Documents/time_log.csv" }
    static var fingers: Int    { let v = d.integer(forKey: "fingers");  return v > 0 ? v : 1 }       // пальцев в жесте
    static var edge: Double    { let v = d.double(forKey: "edge");      return v > 0 ? v : 0.03 }    // «край» — доля ширины трекпада
    static var distance: Double{ let v = d.double(forKey: "distance");  return v > 0 ? v : 0.25 }    // путь вправо, доля ширины
    static var window: Double  { let v = d.double(forKey: "window");    return v > 0 ? v : 0.6 }     // секунд на жест
    static var hotkey: Bool    { d.object(forKey: "hotkey") == nil ? true : d.bool(forKey: "hotkey") }
    static var gesture: Bool   { d.object(forKey: "gesture") == nil ? true : d.bool(forKey: "gesture") }
    static var screen: String? { d.string(forKey: "screen") }                                        // часть имени дисплея
}

// MARK: - Палитра (как в stopwatch.py)
extension NSColor {
    convenience init(_ hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
let BG = NSColor(0x14161c), BG_HOVER = NSColor(0x1e212b), CLOCK_ON = NSColor(0xf4f6fb), CLOCK_DIM = NSColor(0xaeb6c7)
let MUTED = NSColor(0x6b7385), MUTED_SOFT = NSColor(0x4b5263), LINE = NSColor(0x262a34)
let MARK = NSColor(0xc9a25e)        // маркер «неполный день» включён
let ERR = NSColor(0xc96a5e)         // ошибка в окошке ручного интервала
let SELECT = NSColor(0x2e3342)      // выделение текста — вместо системного синего
let PLACEHOLDER = "try_"

// MARK: - Время
/// Идёт и во сне ноутбука (аналог CLOCK_BOOTTIME): после пробуждения часы показывают реальное прошедшее время.
func mono() -> Double {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return Double(mach_continuous_time()) * Double(tb.numer) / Double(tb.denom) / 1e9
}
func hms(_ seconds: Double) -> String {
    let s = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}
let wallFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()

// MARK: - CSV-лог (формат и правила — как у stopwatch.py / sync_nano.py)
enum Log {
    static let fields = ["session_start", "start", "end", "task"]   // длительность = end − start, отдельно не храним
    static var url: URL { URL(fileURLWithPath: (Config.logPath as NSString).expandingTildeInPath) }

    static func escape(_ s: String) -> String {       // как csv.writer: кавычки только при необходимости
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
    static func line(session: Date, start: Date, end: Date, task: String) -> String {
        [wallFmt.string(from: session), wallFmt.string(from: start), wallFmt.string(from: end),
         task.isEmpty ? "—" : task].map(escape).joined(separator: ",")
    }
    /// Вставить интервал на его место по времени (ручное добавление задним числом): файл остаётся
    /// упорядоченным, и «последняя сессия» читается как раньше.
    static func insert(session: Date, start: Date, end: Date, task: String) {
        migrateIfNeeded()
        let fallback = { append(session: session, start: start, end: end, dur: end.timeIntervalSince(start), task: task) }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return fallback() }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first.flatMap({ parse($0).first }), let cB = header.firstIndex(of: "start") else { return fallback() }
        let key = wallFmt.string(from: start)
        var at = lines.count
        for i in 1..<lines.count {
            if let f = parse(lines[i]).first, f.count > cB, f[cB] > key { at = i; break }
        }
        lines.insert(line(session: session, start: start, end: end, task: task), at: at)
        try? (lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
    }
    /// Все интервалы лога (начало, конец) — для проверки пересечений.
    static func intervals() -> [(Date, Date)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let rows = parse(text)
        guard let h = rows.first, let cB = h.firstIndex(of: "start"), let cE = h.firstIndex(of: "end") else { return [] }
        return rows.dropFirst().compactMap { r in
            guard r.count > max(cB, cE), let b = wallFmt.date(from: r[cB]), let e = wallFmt.date(from: r[cE]) else { return nil }
            return (b, e)
        }
    }
    static func append(session: Date, start: Date, end: Date, dur: Double, task: String) {
        let row = line(session: session, start: start, end: end, task: task) + "\r\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        migrateIfNeeded()
        var data = Data()
        if !fm.fileExists(atPath: url.path) || ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) == 0 {
            data.append((fields.joined(separator: ",") + "\r\n").data(using: .utf8)!)
        }
        data.append(row.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
        else { try? data.write(to: url) }
    }

    /// Файл со старой шапкой (с duration_sec/duration_hms) один раз переписывается в новую: лишние колонки
    /// выбрасываются, остальное без изменений. Идемпотентно.
    static func migrateIfNeeded() {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        let rows = parse(text); guard let header = rows.first, header != fields else { return }
        let idx = fields.map { header.firstIndex(of: $0) }
        guard idx.allSatisfy({ $0 != nil }) else { return }           // незнакомая шапка — не трогаем
        var out = fields.joined(separator: ",") + "\r\n"
        for r in rows.dropFirst() { out += idx.map { r.indices.contains($0!) ? escape(r[$0!]) : "" }.joined(separator: ",") + "\r\n" }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Минимальный разбор CSV с кавычками (задача может содержать запятую).
    /// Идём по unicodeScalars: как Character «\r\n» — один символ, и конец строки потерялся бы.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        var it = text.unicodeScalars.makeIterator(); var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? { if let p = pending { pending = nil; return p }; return it.next() }
        func endRow() { row.append(field); field = ""; if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }
        while let c = next() {
            if inQuotes {
                if c == "\"" { if let n = next() { if n == "\"" { field.unicodeScalars.append(c) } else { inQuotes = false; pending = n } } else { inQuotes = false } }
                else { field.unicodeScalars.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { endRow() }
            else if c == "\r" { if let n = next(), n != "\n" { pending = n }; endRow() }
            else { field.unicodeScalars.append(c) }
        }
        endRow()
        return rows
    }

    struct Session { let start: Date; let total: Double; let task: String; let lastEnd: Date }
    /// Последняя сессия лога: (session_start, сумма секунд, задача, конец последнего отрезка).
    static func lastSession() -> Session? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let rows = parse(text); guard rows.count > 1, let header = rows.first else { return nil }
        func col(_ n: String) -> Int? { header.firstIndex(of: n) }
        guard let cS = col("session_start"), let cB = col("start"), let cE = col("end") else { return nil }
        let cT = col("task")
        guard let last = rows.last, last.count > cS, let start = wallFmt.date(from: last[cS]) else { return nil }
        var total = 0.0, task = "", lastEnd = start
        for r in rows.dropFirst() where r.count > max(cS, cB, cE) && r[cS] == last[cS] {
            if let b = wallFmt.date(from: r[cB]), let e = wallFmt.date(from: r[cE]) {
                total += max(0, e.timeIntervalSince(b)); lastEnd = max(lastEnd, e)
            }
            if let cT, r.count > cT, !r[cT].isEmpty, r[cT] != "—" { task = r[cT] }
        }
        return Session(start: start, total: total, task: task, lastEnd: lastEnd)
    }
}

// MARK: - Состояние между перезапусками (крэш, обновление, перезагрузка)
struct SavedState: Codable {
    var sessionActive: Bool, running: Bool
    var sessionStart: Double, segStart: Double     // unix-секунды
    var accumulated: Double
    var task: String
    var alive: Double                              // последний признак жизни: сердцебиение раз в 15 с или выход
}
enum Persist {
    static var url: URL {
        if let o = stateOverride { return URL(fileURLWithPath: o) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Timer/state.json")
    }
    static func save(_ s: SavedState) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }
    static func load() -> SavedState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: d)
    }
}

// MARK: - Маркер «неполный день» на сессию: incomplete_sessions.csv рядом с логом,
// одна колонка session_start — та же строка, что в time_log.csv (по ней и связываются)
enum Marks {
    static var url: URL { Log.url.deletingLastPathComponent().appendingPathComponent("incomplete_sessions.csv") }
    static func load() -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(Log.parse(text).dropFirst().compactMap { $0.first }.filter { !$0.isEmpty })
    }
    static func set(_ session: String, _ on: Bool) {
        var all = load(); if on { all.insert(session) } else { all.remove(session) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ((["session_start"] + all.sorted()).joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Ручной интервал: разбор ЧЧ:ММ, привязка к дате, соседи
enum Manual {
    static let hm: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "HH:mm"; return f
    }()
    /// «12:30», «12.30», «1230», «930», «9» → (12,30) (12,30) (12,30) (9,30) (9,0). Любой не-цифровой знак — разделитель.
    static func parse(_ s: String) -> (Int, Int)? {
        let parts = s.split(whereSeparator: { !($0.isASCII && $0.isNumber) })
        var h: Int?, m: Int?
        if parts.count == 2 { h = Int(parts[0]); m = Int(parts[1]) }
        else if parts.count == 1, (1...4).contains(parts[0].count) {
            let d = parts[0]
            if d.count <= 2 { h = Int(d); m = 0 } else { h = Int(d.dropLast(2)); m = Int(d.suffix(2)) }
        }
        guard let h, let m, (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
    /// Конец — последнее прошедшее ЧЧ:ММ (позже «сейчас» — значит вчера), начало — последнее перед концом.
    static func resolve(_ a: (Int, Int), _ b: (Int, Int), now: Date = Date()) -> (Date, Date)? {
        let cal = Calendar.current
        guard var end = cal.date(bySettingHour: b.0, minute: b.1, second: 0, of: now) else { return nil }
        if end > now { end = cal.date(byAdding: .day, value: -1, to: end)! }
        guard var start = cal.date(bySettingHour: a.0, minute: a.1, second: 0, of: end), start != end else { return nil }
        if start > end { start = cal.date(byAdding: .day, value: -1, to: start)! }
        return (start, end)
    }
    /// Ввод — с точностью до минуты, таймер — до секунды: если край заходит на соседний интервал меньше
    /// чем на минуту, он подтягивается к соседу. Возвращает итоговые края и настоящее пересечение, если есть.
    static func fit(_ s0: Date, _ e0: Date, against xs: [(Date, Date)]) -> (Date, Date, (Date, Date)?) {
        var s = s0, e = e0
        for (b, x) in xs {
            if b <= s && x > s && x.timeIntervalSince(s) < 60 { s = x }
            if b < e && x >= e && e.timeIntervalSince(b) < 60 { e = b }
        }
        return (s, e, xs.first { $0.0 < e && s < $0.1 })
    }
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "сегодня" }
        if cal.isDateInYesterday(d) { return "вчера" }
        let f = DateFormatter(); f.dateFormat = "dd.MM"; return f.string(from: d)
    }
    static func human(_ sec: Double) -> String {
        let m = Int((sec / 60).rounded()); return m >= 60 ? String(format: "%d ч %02d мин", m / 60, m % 60) : "\(m) мин"
    }
}

// MARK: - Логика секундомера (1:1 со stopwatch.py)
final class Stopwatch {
    private(set) var running = false          // идёт ли отсчёт прямо сейчас
    private(set) var sessionActive = false    // начата ли сессия (есть незакрытый старт)
    private var accumulated = 0.0             // сумма завершённых отрезков текущей сессии
    private var segStartMono = 0.0
    private var segStartWall = Date()
    private var sessionStartWall = Date()
    var task = "" { didSet { if task != oldValue { onChange?() } } }
    var onChange: (() -> Void)?               // сохранить состояние на диск

    var elapsed: Double { running ? accumulated + (mono() - segStartMono) : accumulated }
    /// Ключ сессии — ровно та строка, что пишется в session_start лога; nil, пока сессии нет.
    var sessionKey: String? { sessionActive ? wallFmt.string(from: sessionStartWall) : nil }
    var sessionStartDate: Date? { sessionActive ? sessionStartWall : nil }
    var runningSince: Date? { running ? segStartWall : nil }
    /// Ручной интервал, добавленный в текущую сессию, — сразу виден на часах.
    func addManual(_ dur: Double) { accumulated += max(0, dur); onChange?() }

    func toggle() { running ? pause() : start() }
    func start() {
        if !sessionActive { sessionActive = true; accumulated = 0; sessionStartWall = Date() }
        segStartMono = mono(); segStartWall = Date(); running = true; onChange?()
    }
    func pause() { guard running else { return }; endSegment(); running = false; onChange?() }
    /// «Стоп»: как закрытие окна у старого таймера — дописать отрезок, сессия закрыта, часы на 00:00:00.
    func stop() { if running { endSegment() }; running = false; sessionActive = false; accumulated = 0; onChange?() }
    func continueLast(_ s: Log.Session) {
        guard !sessionActive else { return }
        sessionActive = true; sessionStartWall = s.start; accumulated = s.total
        if !s.task.isEmpty { task = s.task }
        segStartMono = mono(); segStartWall = Date(); running = true; onChange?()
    }

    // --- переживание перезапуска ---
    /// Перерыв короче этого (крэш → launchd поднял за секунды, обновление, быстрая перезагрузка) —
    /// интервал продолжается, будто ничего не было. Длиннее (мак был выключен) — отрезок закрывается
    /// моментом последнего признака жизни, сессия остаётся на паузе.
    static let resumeGap: TimeInterval = 5 * 60

    func snapshot(alive: Date = Date()) -> SavedState {
        SavedState(sessionActive: sessionActive, running: running,
                   sessionStart: sessionStartWall.timeIntervalSince1970, segStart: segStartWall.timeIntervalSince1970,
                   accumulated: accumulated, task: task, alive: alive.timeIntervalSince1970)
    }
    func restore(_ s: SavedState, now: Date = Date()) {
        let alive = Date(timeIntervalSince1970: s.alive), gap = now.timeIntervalSince(alive)
        task = s.task
        guard s.sessionActive else { return }
        sessionActive = true; sessionStartWall = Date(timeIntervalSince1970: s.sessionStart); accumulated = s.accumulated
        if s.running {
            let segStart = Date(timeIntervalSince1970: s.segStart)
            if gap < Stopwatch.resumeGap {
                segStartWall = segStart; segStartMono = mono() - now.timeIntervalSince(segStart); running = true
                return
            }
            let dur = alive.timeIntervalSince(segStart)
            if dur > 0 { accumulated += dur }
            if dur >= 1 { Log.append(session: sessionStartWall, start: segStart, end: alive, dur: dur, task: task) }
        }
        if gap > 12 * 3600 { sessionActive = false; accumulated = 0 }   // пауза старше 12 ч — сессия закрыта
    }
    /// Перед выходом процесса (SIGTERM, обновление, выключение): отрезок сразу дописывается в лог,
    /// а если таймер шёл — новый отрезок начинается с этого момента, чтобы после перезапуска продолжить.
    func checkpointForExit() {
        guard running else { return }
        endSegment(); segStartWall = Date(); segStartMono = mono()
    }
    private func endSegment() {
        let dur = mono() - segStartMono; accumulated += dur
        if dur >= 1 { Log.append(session: sessionStartWall, start: segStartWall, end: Date(), dur: dur, task: task) }
    }
}

// MARK: - Виджеты
final class FlatButton: NSButton {
    var normalColor = MUTED, hoverColor = CLOCK_ON, size: CGFloat = 13
    private var tracking: NSTrackingArea?
    convenience init(_ title: String, target: AnyObject, action: Selector, size: CGFloat = 13) {
        self.init(frame: .zero); self.size = size
        isBordered = false; setButtonType(.momentaryChange); self.target = target; self.action = action
        wantsLayer = true; layer?.cornerRadius = 7; focusRingType = .none
        (cell as? NSButtonCell)?.highlightsBy = []
        setTitle(title)
    }
    func setTitle(_ t: String, color: NSColor? = nil) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color ?? normalColor, .paragraphStyle: p])
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize { let s = super.intrinsicContentSize; return NSSize(width: s.width + 36, height: s.height + 16) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self); addTrackingArea(tracking!)
    }
    override func mouseEntered(with e: NSEvent) { layer?.backgroundColor = BG_HOVER.cgColor; setTitle(title, color: hoverColor) }
    override func mouseExited(with e: NSEvent)  { layer?.backgroundColor = nil; setTitle(title, color: normalColor) }
}

final class TimerPanel: NSPanel {
    var onSpace: (() -> Void)?, onEscape: (() -> Void)?, onFinish: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var editingTask: Bool { (firstResponder as? NSTextView)?.isFieldEditor ?? false }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { onEscape?(); return }
        if !editingTask {
            if e.keyCode == UInt16(kVK_Space) { onSpace?(); return }
            if (e.keyCode == UInt16(kVK_Return) || e.keyCode == UInt16(kVK_ANSI_KeypadEnter)) && e.modifierFlags.contains(.command) { onFinish?(); return }
        }
        super.keyDown(with: e)
    }
}

/// Ячейка с тихим редактором: приглушённый курсор и выделение в цвет панели, а не системное синее.
final class QuietCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let t = super.setUpFieldEditorAttributes(textObj)
        if let tv = t as? NSTextView {
            tv.insertionPointColor = MUTED
            tv.selectedTextAttributes = [.backgroundColor: SELECT, .foregroundColor: CLOCK_ON]
        }
        return t
    }
}
class QuietField: NSTextField {
    override class var cellClass: AnyClass? { get { QuietCell.self } set {} }
}
/// Поле ЧЧ:ММ окошка ручного интервала: при фокусе подсвечивается.
final class TimeField: QuietField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
}

// MARK: - Приложение
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let sw = Stopwatch()
    var statusItem: NSStatusItem!
    var panel: TimerPanel!
    var container: NSView!
    var clock: NSTextField!, mainBtn: FlatButton!, finishBtn: FlatButton!, continueBtn: FlatButton!, taskField: NSTextField!
    var markBtn: FlatButton!
    var addBtn: FlatButton!, addPanel: TimerPanel!, addContainer: NSView!
    var startField: TimeField!, endField: TimeField!, addHint: NSTextField!
    var addRows: [(Date, Date)] = []            // интервалы лога + идущий отрезок, снятые при открытии окошка
    var addClosedAt = Date.distantPast
    var markKey: String? = nil, incomplete = false, markReload = true   // какая сессия на маркере и отмечена ли
    var lastSession: Log.Session?
    var lastHide = Date.distantPast
    var hotKeyRef: EventHotKeyRef?
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let st = Persist.load() { sw.restore(st) }
        sw.onChange = { [weak self] in self?.persist() }
        persist()
        reloadLastSession()
        buildStatusItem(); buildPanel(); buildAddPanel(); buildMenu()
        taskField.stringValue = sw.task
        if Config.hotkey { registerHotkey() }
        if Config.gesture {
            let devs = TouchStart(Int32(Config.fingers), Config.edge, Config.distance, Config.window) { [weak self] in self?.togglePanel() }
            if devs == 0 { NSLog("Timer: мультитач недоступен — жест выключен, остаются хоткей и клик по меню-бару") }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in TouchRestart() }
        }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        let beat = Timer(timeInterval: 15, repeats: true) { [weak self] _ in if self?.sw.running == true { self?.persist() } }
        RunLoop.main.add(beat, forMode: .common)                // признак жизни: по нему видно, когда процесс умер
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in self?.prepareExit(); exit(0) }; src.resume()
        sigSource = src
        refresh()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            lastSession = Log.Session(start: Date(), total: 4675, task: "", lastEnd: Date())
            continueBtn.setTitle("продолжить прошлую сессию · \(hms(lastSession!.total))")
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                snap(out + "-idle.png")
                sw.start(); refresh(); pressMark(); refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
                    snap(out + "-running.png"); showAdd()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        print("keytest открыть окошко: панель видна=\(panel.isVisible) окошко ключевое=\(addPanel.isKeyWindow)   (true true)")
                        snap(out + "-add.png", view: addContainer)
                        endField.stringValue = "25:00"; updateAddHint(); snap(out + "-add-error.png", view: addContainer)
                        panel.makeKeyAndOrderFront(nil)                 // клик в главную панель
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                            print("keytest клик в панель: окошко видно=\(addPanel.isVisible) панель видна=\(panel.isVisible)   (false true)")
                            showAdd(); hideAdd(returnFocus: true)        // Esc
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                print("keytest Esc: окошко видно=\(addPanel.isVisible) панель видна=\(panel.isVisible) панель ключевая=\(panel.isKeyWindow)   (false true true)")
                                showAdd(); startField.stringValue = "07:00"; endField.stringValue = "07:20"; updateAddHint()
                                let before = sw.elapsed; commitAdd()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                    print("keytest Enter: окошко видно=\(addPanel.isVisible) +\(Int((sw.elapsed - before) / 60)) мин на часах   (false, +0: 07:00 раньше начала сессии → отдельная сессия)")
                                    print((try? String(contentsOf: Log.url, encoding: .utf8)) ?? "")
                                    sw.stop(); exit(0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func persist() { Persist.save(sw.snapshot()) }
    func prepareExit() { sw.checkpointForExit(); persist() }
    func snap(_ path: String, view: NSView? = nil) {
        let v = view ?? container!
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot: \(path) \(Int(v.bounds.width))x\(Int(v.bounds.height))")
    }
    var sigSource: DispatchSourceSignal?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { prepareExit(); return .terminateNow }

    func reloadLastSession() {
        lastSession = Log.lastSession()
        if let s = lastSession, Date().timeIntervalSince(s.lastEnd) > 12 * 3600 { lastSession = nil }   // старше 12 ч — продолжать нечего
    }

    // MARK: меню-бар
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem.button else { return }
        b.target = self; b.action = #selector(statusClicked); b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil; return
        }
        if Date().timeIntervalSince(lastHide) < 0.4 { return }    // панель только что спряталась от этого же клика
        togglePanel()
    }
    func buildMenu() {
        menu.addItem(withTitle: "Показать / скрыть  (⌃⌥⌘T, смахивание слева)", action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Старт / Пауза", action: #selector(menuSpace), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Завершить сессию", action: #selector(menuFinish), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Показать лог в Finder", action: #selector(menuLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Перезапустить (идущий интервал продолжится)", action: #selector(menuQuit), keyEquivalent: "").target = self
    }
    @objc func menuToggle() { togglePanel() }
    @objc func menuSpace()  { sw.toggle(); refresh() }
    @objc func menuFinish() { finish() }
    @objc func menuLog()    { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
    @objc func menuQuit()   { NSApp.terminate(nil) }

    // MARK: панель
    func buildPanel() {
        panel = TimerPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.becomesKeyOnlyIfNeeded = false
        panel.onSpace = { [weak self] in self?.sw.toggle(); self?.refresh() }
        panel.onEscape = { [weak self] in self?.hidePanel() }
        panel.onFinish = { [weak self] in self?.finish() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.afterKeyChange() } }      // фокус ушёл в окошко интервала — панель не прячем
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                if self?.addPanel?.isVisible == true { self?.positionAdd() } }
        }

        container = NSView(); container.wantsLayer = true
        container.layer?.backgroundColor = BG.cgColor; container.layer?.cornerRadius = 16
        container.layer?.borderWidth = 1; container.layer?.borderColor = LINE.cgColor
        panel.contentView = container

        clock = NSTextField(labelWithString: "00:00:00")
        clock.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .ultraLight)
        clock.textColor = CLOCK_DIM; clock.alignment = .center

        mainBtn = FlatButton("Старт", target: self, action: #selector(pressMain))
        finishBtn = FlatButton("завершить", target: self, action: #selector(pressFinish), size: 11)
        finishBtn.normalColor = MUTED_SOFT; finishBtn.setTitle("завершить")
        addBtn = FlatButton("добавить интервал", target: self, action: #selector(pressAdd), size: 11)
        addBtn.normalColor = MUTED_SOFT; addBtn.setTitle("добавить интервал")
        let row = NSStackView(views: [mainBtn, finishBtn, addBtn]); row.orientation = .horizontal; row.spacing = 4

        taskField = QuietField(); taskField.delegate = self
        taskField.isBezeled = false; taskField.drawsBackground = false; taskField.focusRingType = .none
        taskField.alignment = .center; taskField.font = NSFont.systemFont(ofSize: 13); taskField.textColor = MUTED
        taskField.placeholderAttributedString = NSAttributedString(string: PLACEHOLDER, attributes: [.foregroundColor: MUTED_SOFT, .font: NSFont.systemFont(ofSize: 13)])
        let underline = NSView(); underline.wantsLayer = true; underline.layer?.backgroundColor = LINE.cgColor
        let taskWrap = NSStackView(views: [taskField, underline]); taskWrap.orientation = .vertical; taskWrap.spacing = 4; taskWrap.alignment = .centerX

        markBtn = FlatButton("○ неполный день", target: self, action: #selector(pressMark), size: 11)
        markBtn.normalColor = MUTED_SOFT; markBtn.setTitle("○ неполный день")
        markBtn.toolTip = "Отметить текущую сессию — пишется в incomplete_sessions.csv"
        let taskRow = NSStackView(views: [markBtn, taskWrap]); taskRow.orientation = .horizontal; taskRow.spacing = 6; taskRow.alignment = .centerY
        taskRow.detachesHiddenViews = false     // без сессии маркер скрыт, но место держит — поле не прыгает

        continueBtn = FlatButton("продолжить прошлую сессию", target: self, action: #selector(pressContinue), size: 12)

        let stack = NSStackView(views: [clock, row, taskRow, continueBtn])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10; stack.detachesHiddenViews = true
        stack.setCustomSpacing(16, after: row)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            taskField.widthAnchor.constraint(equalToConstant: 210),
            underline.widthAnchor.constraint(equalTo: taskField.widthAnchor), underline.heightAnchor.constraint(equalToConstant: 1),
        ])
        if let s = lastSession { continueBtn.setTitle("продолжить прошлую сессию · \(hms(s.total))") }
    }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }
    func showPanel() {
        markReload = true                      // перечитать отметку (вдруг файл правили руками)
        refresh()
        container.layoutSubtreeIfNeeded()
        panel.setContentSize(container.fittingSize)
        // Закреплено на главном дисплее macOS (Настройки → Дисплеи → «Основной дисплей»). Ключ `screen` —
        // закрепить на другом по части имени; если он не подключён, снова главный.
        let screen = Config.screen.flatMap { n in NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(n) } }
            ?? NSScreen.screens.first ?? NSScreen.main!
        let vf = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.minX + 10, y: vf.maxY - size.height - 8))   // левый верхний угол
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)          // пробел — таймеру, а не полю задачи
    }
    func hidePanel() {
        guard panel.isVisible else { return }
        hideAdd(returnFocus: false)
        panel.makeFirstResponder(nil); panel.orderOut(nil); lastHide = Date()
    }
    /// Кто-то потерял фокус: окошко интервала закрывается от любого другого действия,
    /// панель — когда фокус ушёл и не в окошко.
    func afterKeyChange() {
        if addPanel.isVisible && !addPanel.isKeyWindow { hideAdd(returnFocus: false) }
        if panel.isVisible && !panel.isKeyWindow && !addPanel.isKeyWindow { hidePanel() }
    }

    // MARK: окошко «добавить интервал»
    func buildAddPanel() {
        addPanel = TimerPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        addPanel.isFloatingPanel = true; addPanel.level = .floating; addPanel.hidesOnDeactivate = false
        addPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        addPanel.isOpaque = false; addPanel.backgroundColor = .clear; addPanel.hasShadow = true
        addPanel.onEscape = { [weak self] in self?.hideAdd(returnFocus: true) }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: addPanel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.afterKeyChange() } }

        addContainer = NSView(); addContainer.wantsLayer = true
        addContainer.layer?.backgroundColor = BG.cgColor; addContainer.layer?.cornerRadius = 16
        addContainer.layer?.borderWidth = 1; addContainer.layer?.borderColor = LINE.cgColor
        addPanel.contentView = addContainer

        let font = NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .ultraLight)
        let w = ("00:00" as NSString).size(withAttributes: [.font: font]).width + 12
        func timeField() -> TimeField {
            let f = TimeField(); f.delegate = self
            f.isBezeled = false; f.drawsBackground = false; f.focusRingType = .none
            f.alignment = .center; f.font = font; f.textColor = CLOCK_DIM
            f.widthAnchor.constraint(equalToConstant: w).isActive = true
            return f
        }
        startField = timeField(); endField = timeField()
        startField.onFocus = { [weak self] in self?.startField.textColor = CLOCK_ON; self?.endField.textColor = CLOCK_DIM }
        endField.onFocus = { [weak self] in self?.endField.textColor = CLOCK_ON; self?.startField.textColor = CLOCK_DIM }
        startField.nextKeyView = endField; endField.nextKeyView = startField
        let dash = NSTextField(labelWithString: "–"); dash.font = font; dash.textColor = MUTED_SOFT
        let times = NSStackView(views: [startField, dash, endField]); times.orientation = .horizontal; times.spacing = 4

        addHint = NSTextField(labelWithString: ""); addHint.font = NSFont.systemFont(ofSize: 12); addHint.alignment = .center
        let stack = NSStackView(views: [times, addHint]); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: addContainer.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: addContainer.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: addContainer.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: addContainer.trailingAnchor, constant: -28),
        ])
    }

    /// Что предложить: конец — сейчас (или начало идущего отрезка), начало — конец последнего
    /// интервала сегодня, то есть ровно «дыра»; если сегодня ничего не было — получасом раньше.
    func addDefaults() -> (Date, Date) {
        func floorMin(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60) }
        func ceilMin(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.up) * 60) }
        let end = floorMin(sw.runningSince ?? Date())
        var start = end.addingTimeInterval(-30 * 60)
        if let p = addRows.map({ $0.1 }).filter({ $0 <= end }).max(), Calendar.current.isDate(p, inSameDayAs: end), ceilMin(p) < end {
            start = ceilMin(p)
        }
        return (start, end)
    }
    func showAdd() {
        addRows = Log.intervals()
        if let r = sw.runningSince { addRows.append((r, Date())) }
        let (s, e) = addDefaults()
        startField.stringValue = Manual.hm.string(from: s); endField.stringValue = Manual.hm.string(from: e)
        updateAddHint()
        addContainer.layoutSubtreeIfNeeded(); addPanel.setContentSize(addContainer.fittingSize)
        positionAdd()
        addPanel.makeKeyAndOrderFront(nil)
        startField.selectText(nil)
    }
    func positionAdd() {                        // под главной панелью, той же ширины
        let f = panel.frame, h = addPanel.frame.height
        let w = max(f.width, addContainer.fittingSize.width)
        addPanel.setFrame(NSRect(x: f.minX, y: f.minY - 8 - h, width: w, height: h), display: true)
    }
    func hideAdd(returnFocus: Bool) {
        guard addPanel.isVisible else { return }
        addPanel.makeFirstResponder(nil); addPanel.orderOut(nil); addClosedAt = Date()
        if returnFocus, panel.isVisible { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(nil) }
    }
    /// Разобрать поля: итоговый интервал или nil, и текст подсказки под полями.
    func evalAdd() -> ((Date, Date)?, String) {
        guard let a = Manual.parse(startField.stringValue), let b = Manual.parse(endField.stringValue) else { return (nil, "время — ЧЧ:ММ") }
        guard let (s0, e0) = Manual.resolve(a, b) else { return (nil, "пустой интервал") }
        let (s, e, hit) = Manual.fit(s0, e0, against: addRows)
        if s >= e { return (nil, "пустой интервал") }
        if let h = hit { return (nil, "пересекается с \(Manual.hm.string(from: h.0))–\(Manual.hm.string(from: h.1))") }
        let days = Calendar.current.isDate(s, inSameDayAs: e) ? Manual.day(s) : "\(Manual.day(s)) → \(Manual.day(e))"
        return ((s, e), "\(days) · \(Manual.human(e.timeIntervalSince(s)))")
    }
    func updateAddHint() {
        let (iv, text) = evalAdd()
        addHint.stringValue = text; addHint.textColor = iv == nil ? ERR : MUTED
    }
    /// Enter: в текущую сессию, если интервал не раньше её начала, иначе — отдельной сессией.
    func commitAdd() {
        guard let (s, e) = evalAdd().0 else { NSSound.beep(); return }
        let into = sw.sessionStartDate.flatMap { s >= $0 ? $0 : nil }
        Log.insert(session: into ?? s, start: s, end: e, task: sw.task)
        if into != nil { sw.addManual(e.timeIntervalSince(s)) }
        reloadLastSession()
        if let ls = lastSession { continueBtn.setTitle("продолжить прошлую сессию · \(hms(ls.total))") }
        hideAdd(returnFocus: true)
        addBtn.setTitle("добавлено")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.addBtn.setTitle("добавить интервал") }
        refresh()
    }
    func nudge(_ f: NSTextField, _ minutes: Int) {   // ↑ / ↓ — ±5 минут
        let (h, m) = Manual.parse(f.stringValue) ?? (Calendar.current.component(.hour, from: Date()), 0)
        let t = ((h * 60 + m + minutes) % 1440 + 1440) % 1440
        let text = String(format: "%02d:%02d", t / 60, t % 60)
        if let ed = f.currentEditor() as? NSTextView { ed.string = text } else { f.stringValue = text }
        updateAddHint()
    }

    // MARK: действия
    @objc func pressMain() { sw.toggle(); panel.makeFirstResponder(nil); refresh() }
    @objc func pressFinish() { finish() }
    @objc func pressAdd() {
        if addPanel.isVisible { hideAdd(returnFocus: true); return }
        if Date().timeIntervalSince(addClosedAt) < 0.35 { return }   // этот же клик только что закрыл окошко
        showAdd()
    }
    @objc func pressContinue() { if let s = lastSession { sw.continueLast(s); taskField.stringValue = sw.task; panel.makeFirstResponder(nil); refresh() } }
    @objc func pressMark() {
        guard let key = sw.sessionKey else { return }
        if key != markKey { markKey = key; incomplete = Marks.load().contains(key) }
        incomplete.toggle(); Marks.set(key, incomplete); updateMarkBtn(); panel.makeFirstResponder(nil)
    }
    func updateMarkBtn() {
        markBtn.normalColor = incomplete ? MARK : MUTED_SOFT
        markBtn.setTitle(incomplete ? "● неполный день" : "○ неполный день")
    }
    func finish() { sw.stop(); reloadLastSession(); if let s = lastSession { continueBtn.setTitle("продолжить прошлую сессию · \(hms(s.total))") }; refresh() }

    // поле задачи: Enter/Esc снимают фокус (как в старом таймере); курсор — приглушённый
    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === taskField { sw.task = taskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { updateAddHint() }
    }
    func controlTextDidBeginEditing(_ n: Notification) { ((n.object as? NSTextField)?.currentEditor() as? NSTextView)?.insertionPointColor = MUTED }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if let f = c as? TimeField {                 // окошко интервала: Enter — добавить, Esc — закрыть, ↑↓ — ±5 мин
            switch sel {
            case #selector(NSResponder.insertNewline(_:)): commitAdd(); return true
            case #selector(NSResponder.cancelOperation(_:)): hideAdd(returnFocus: true); return true
            case #selector(NSResponder.moveUp(_:)): nudge(f, 5); return true
            case #selector(NSResponder.moveDown(_:)): nudge(f, -5); return true
            default: return false
            }
        }
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.cancelOperation(_:)) { panel.makeFirstResponder(nil); return true }
        return false
    }

    // MARK: отрисовка состояния
    func refresh() {
        let key = sw.sessionKey                 // новая сессия, «продолжить», перезапуск — маркер следует за сессией
        if key != markKey || markReload {
            markReload = false; markKey = key
            incomplete = key.map { Marks.load().contains($0) } ?? false; updateMarkBtn()
        }
        if markBtn.isHidden == sw.sessionActive { markBtn.isHidden = !sw.sessionActive }
        let t = hms(sw.elapsed)
        if clock.stringValue != t { clock.stringValue = t }
        clock.textColor = sw.running ? CLOCK_ON : CLOCK_DIM
        let title = sw.running ? "Пауза" : (sw.sessionActive ? "Продолжить" : "Старт")
        if mainBtn.title != title { mainBtn.setTitle(title) }
        let showFinish = sw.sessionActive, showContinue = !sw.sessionActive && lastSession != nil
        var relayout = false
        if finishBtn.isHidden == showFinish { finishBtn.isHidden = !showFinish; relayout = true }
        if continueBtn.isHidden == showContinue { continueBtn.isHidden = !showContinue; relayout = true }
        if relayout, panel.isVisible { let o = panel.frame; container.layoutSubtreeIfNeeded(); let s = container.fittingSize
            panel.setFrame(NSRect(x: o.minX, y: o.maxY - s.height, width: s.width, height: s.height), display: true) }
        guard let b = statusItem.button else { return }
        let (symbol, fallback) = sw.running ? ("play.fill", "▶") : (sw.sessionActive ? ("pause.fill", "⏸") : ("timer", "◷"))
        if statusSymbol != symbol {
            statusSymbol = symbol
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Таймер")
            b.title = b.image == nil ? fallback : ""
        }
    }
    var statusSymbol = ""

    // MARK: хоткей ⌃⌥⌘T (Carbon, без разрешений)
    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in DispatchQueue.main.async { gApp?.togglePanel() }; return noErr }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: 0x54494D52, id: 1)   // 'TIMR'
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

var gApp: AppDelegate?

// `Timer --selftest /tmp/x.csv` — прогнать логику и запись CSV без интерфейса
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    logOverride = CommandLine.arguments[i + 1]
    let s = Stopwatch(); s.task = "проверка, с запятой"
    s.start(); Thread.sleep(forTimeInterval: 1.3); s.pause()
    s.start(); Thread.sleep(forTimeInterval: 0.3); s.pause()          // < 1 с — в лог не идёт
    s.start(); Thread.sleep(forTimeInterval: 1.1); s.stop()
    var swipes = 0
    _ = TouchStart(1, 0.03, 0.25, 0.6) { swipes += 1 }
    func frame(_ t: Double, _ pts: [(Float, Float)], id: Int32 = 1) { var xs = pts.map { $0.0 }, ys = pts.map { $0.1 }; TouchSimulate(Int32(pts.count), &xs, &ys, t, id) }
    frame(0.0, [(0.01, 0.5)]); frame(0.1, [(0.10, 0.5)]); frame(0.2, [(0.30, 0.52)]); frame(0.3, [(0.40, 0.52)]); frame(0.4, [])   // быстрый свайп от края — 1 раз
    frame(1.0, [(0.20, 0.5)], id: 2); frame(1.2, [(0.60, 0.5)], id: 2); frame(1.3, [], id: 2)                                  // не от края — 0
    frame(2.0, [(0.01, 0.5)], id: 3); frame(2.9, [(0.40, 0.5)], id: 3); frame(3.0, [], id: 3)                                   // слишком медленно — 0
    frame(4.0, [(0.01, 0.5)], id: 4); frame(4.2, [(0.30, 0.9)], id: 4); frame(4.3, [], id: 4)                                   // ушёл вверх — 0
    frame(5.0, [(0.01, 0.5), (0.02, 0.6)], id: 5); frame(5.2, [(0.40, 0.5), (0.41, 0.6)], id: 5); frame(5.3, [], id: 5)         // два пальца при fingers=1 — 0
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    print("gesture: swipes=\(swipes) (ожидается 1)")
    // --- переживание перезапуска
    func rows() -> Int { (try? String(contentsOf: Log.url, encoding: .utf8)).map { Log.parse($0).count - 1 } ?? 0 }
    let now = Date(), t0 = now.addingTimeInterval(-600).timeIntervalSince1970, nowTs = now.timeIntervalSince1970
    var r0 = rows()
    let a = Stopwatch(); a.restore(SavedState(sessionActive: true, running: true, sessionStart: t0, segStart: t0, accumulated: 0, task: "крэш", alive: nowTs - 20), now: now)
    print("крэш, перерыв 20 с:   running=\(a.running) elapsed=\(Int(a.elapsed.rounded())) новых строк=\(rows() - r0)   (ожидается true, 600, 0)")
    r0 = rows()
    let b = Stopwatch(); b.restore(SavedState(sessionActive: true, running: true, sessionStart: t0, segStart: t0, accumulated: 0, task: "выключен", alive: t0 + 120), now: now)
    print("перерыв 8 мин:        running=\(b.running) session=\(b.sessionActive) elapsed=\(Int(b.elapsed.rounded())) новых строк=\(rows() - r0)   (false, true, 120, 1)")
    r0 = rows()
    let c = Stopwatch(); c.restore(SavedState(sessionActive: true, running: true, sessionStart: t0, segStart: t0, accumulated: 0, task: "обновление", alive: nowTs), now: now)
    c.checkpointForExit(); let snap = c.snapshot()
    let c2 = Stopwatch(); c2.restore(snap, now: Date().addingTimeInterval(3))
    print("выход → перезапуск:   новых строк=\(rows() - r0) running=\(c2.running) elapsed=\(Int(c2.elapsed.rounded()))   (1, true, 603)")
    let c3 = Stopwatch(); c3.restore(snap, now: Date().addingTimeInterval(3600))
    print("выход → через час:    running=\(c3.running) session=\(c3.sessionActive) elapsed=\(Int(c3.elapsed.rounded()))   (false, true, 600)")
    let d = Stopwatch(); d.restore(SavedState(sessionActive: true, running: false, sessionStart: t0 - 50000, segStart: t0 - 50000, accumulated: 1200, task: "", alive: nowTs - 13 * 3600), now: now)
    print("пауза 13 ч назад:     session=\(d.sessionActive)   (false)")
    stateOverride = logOverride! + "-state.json"; Persist.save(snap)
    print("state.json туда-обратно: \(Persist.load()?.task ?? "nil")   (обновление)")
    // --- ручной интервал
    func hmStr(_ v: (Int, Int)?) -> String { v.map { String(format: "%02d:%02d", $0.0, $0.1) } ?? "nil" }
    print("разбор: \(["12:30", "12.30", "1230", "930", "9", "12:", "24:00", "12:75", "", "abc"].map { hmStr(Manual.parse($0)) })")
    print("        (ожидается 12:30 12:30 12:30 09:30 09:00 12:00 nil nil nil nil)")
    let cal = Calendar.current, ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
    func rs(_ a: String, _ b: String) -> String {
        guard let r = Manual.resolve(Manual.parse(a)!, Manual.parse(b)!, now: ten) else { return "nil" }
        let df = DateFormatter(); df.dateFormat = "dd HH:mm"; return "\(df.string(from: r.0))–\(df.string(from: r.1))"
    }
    let dd = { (o: Int) -> String in let df = DateFormatter(); df.dateFormat = "dd"; return df.string(from: cal.date(byAdding: .day, value: o, to: ten)!) }
    print("в 10:00: 09:00–09:45 → \(rs("9:00", "9:45")), 14:00–15:00 → \(rs("14", "15")), 23:30–00:30 → \(rs("2330", "0030")), 9–9 → \(rs("9", "9"))")
    print("        (ожидается \(dd(0)) 09:00–\(dd(0)) 09:45, \(dd(-1)) 14:00–\(dd(-1)) 15:00, \(dd(-1)) 23:30–\(dd(0)) 00:30, nil)")
    let base = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    let nb = [(base, base.addingTimeInterval(35)), (base.addingTimeInterval(3600 - 20), base.addingTimeInterval(4000))]   // 12:00:00–12:00:35, 12:59:40–13:06:40
    let (fs, fe, fh) = Manual.fit(base, base.addingTimeInterval(3600), against: nb)
    print("подтяжка к соседям <1 мин: \(Int(fs.timeIntervalSince(base)))..\(Int(fe.timeIntervalSince(base))) пересечение=\(fh != nil)   (35..3580 false)")
    let (_, _, fh2) = Manual.fit(base.addingTimeInterval(-600), base.addingTimeInterval(600), against: nb)
    print("настоящее пересечение найдено: \(fh2 != nil)   (true)")
    let ins = logOverride! + "-ins.csv"; let keep = logOverride
    logOverride = ins; try? FileManager.default.removeItem(atPath: ins)
    for hh in [10, 12] { let t = cal.date(bySettingHour: hh, minute: 0, second: 0, of: Date())!; Log.append(session: t, start: t, end: t.addingTimeInterval(600), dur: 600, task: "t\(hh)") }
    for hh in [11, 13, 9] { let t = cal.date(bySettingHour: hh, minute: 0, second: 0, of: Date())!; Log.insert(session: t, start: t, end: t.addingTimeInterval(600), task: "m\(hh)") }
    let order = Log.parse(try! String(contentsOf: Log.url, encoding: .utf8)).dropFirst().map { $0[3] }
    print("вставка по времени: \(order)   ([m9, t10, m11, t12, m13])")
    logOverride = keep

    // --- маркер на сессию
    let e = Stopwatch(); e.start(); let key = e.sessionKey!; Thread.sleep(forTimeInterval: 1.1); e.pause()
    let lastRow = Log.parse(try! String(contentsOf: Log.url, encoding: .utf8)).last!
    print("ключ сессии = session_start в логе: \(key == lastRow[0])   (true)")
    let f = Stopwatch(); f.continueLast(Log.lastSession()!)
    print("«продолжить» → тот же ключ: \(f.sessionKey == key)   (true)")
    e.stop(); print("после «завершить» ключа нет: \(e.sessionKey == nil)   (true)")
    Marks.set("2026-10-12 10:00:00", true); Marks.set("2026-10-12 12:00:00", true); Marks.set("2026-10-12 10:00:00", false)
    print("неполные сессии: \(Marks.load().sorted())   ([2026-10-12 12:00:00])")
    print(try! String(contentsOf: Marks.url, encoding: .utf8))
    let last = Log.lastSession()
    print("elapsed=\(s.elapsed) sessionActive=\(s.sessionActive) last=\(last.map { "total=\($0.total) task=\($0.task)" } ?? "nil")")
    print(try! String(contentsOf: Log.url, encoding: .utf8))
    exit(0)
}

// `Timer --snapshot <префикс>` — PNG панели; лог, состояние и маркер — в файлы рядом с префиксом
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    logOverride = CommandLine.arguments[i + 1] + ".csv"; stateOverride = CommandLine.arguments[i + 1] + "-state.json"
}

// `Timer --touch-debug` — печатать кадры трекпада, чтобы проверить жест
if CommandLine.arguments.contains("--touch-debug") {
    let n = TouchDebug()
    print("мультитач-устройств: \(n). Проведи пальцем от левого края трекпада — должно напечатать >>> SWIPE. Ctrl+C — выход.")
    _ = TouchStart(Int32(Config.fingers), Config.edge, Config.distance, Config.window) { print(">>> SWIPE (обработчик)") }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate(); gApp = delegate
app.delegate = delegate
app.run()
