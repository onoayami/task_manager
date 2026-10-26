import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Model

struct WorkSession: Codable, Identifiable {
    var id = UUID()
    var task: String
    var start: Date
    var end: Date?
    var adjust: TimeInterval? = nil   // 手動で時間を編集したときの調整分（＋/−秒）

    var isAdjustment: Bool { adjust != nil }
    var isOpen: Bool { end == nil && adjust == nil }

    func duration(now: Date) -> TimeInterval {
        if let a = adjust { return a }
        return (end ?? now).timeIntervalSince(start)
    }
}

/// 計測中・一時停止中のタスク（同時に複数持てる）
struct ActiveRun: Codable {
    var task: String
    var base: TimeInterval = 0   // 旧バージョン互換用
    var paused: Bool = false
    var since: Date? = nil       // 今回の計測を開始した時刻
}

/// 書き出し・タイムライン用：1日の範囲に切り取ったセッション
struct Segment {
    var task: String
    var start: Date
    var end: Date?          // nil = 計測中
    var adjust: TimeInterval?
    var seconds: TimeInterval
}

/// メモの履歴：その日だけのメモ（日をまたぐと新しいメモになる）
struct NoteEntry: Codable {
    var day: String    // "yyyy-MM-dd"
    var text: String
}

struct AppData: Codable {
    var tasks: [String] = []
    var sessions: [WorkSession] = []
    var active: [ActiveRun] = []          // 計測中・一時停止中のタスク（開始順）
    var noteHistory: [String: [NoteEntry]] = [:]   // タスクごとのメモ（日付つき）
    var pendingResume: [String] = []      // 再起動などで止まり、起動時に再開を確認するタスク
    var dayStartHour: Int = 0             // 日付が切り替わる時刻（0〜23時）
    var splitAtDayChange: Bool = true     // 日をまたいだら記録を区切る（次の日は0から）

    enum CodingKeys: String, CodingKey {
        case tasks, sessions, active, noteHistory, pendingResume, dayStartHour, splitAtDayChange
    }
    enum LegacyKeys: String, CodingKey { case pausedTask, runBase, askResumeOnLaunch, notes }

    init() {}

    // 旧バージョン（1件ずつ計測）のデータも読めるように
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? []
        sessions = try c.decodeIfPresent([WorkSession].self, forKey: .sessions) ?? []
        if let h = try c.decodeIfPresent([String: [NoteEntry]].self, forKey: .noteHistory) {
            noteHistory = h
        } else {
            // 旧バージョンのメモ（日付なし）は、過去の日付のメモとして残す
            let l = try decoder.container(keyedBy: LegacyKeys.self)
            let old = try l.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
            noteHistory = old.mapValues { [NoteEntry(day: "1970-01-01", text: $0)] }
        }
        dayStartHour = try c.decodeIfPresent(Int.self, forKey: .dayStartHour) ?? 0
        splitAtDayChange = try c.decodeIfPresent(Bool.self, forKey: .splitAtDayChange) ?? true

        if let a = try c.decodeIfPresent([ActiveRun].self, forKey: .active) {
            active = a
            pendingResume = try c.decodeIfPresent([String].self, forKey: .pendingResume) ?? []
        } else {
            let l = try decoder.container(keyedBy: LegacyKeys.self)
            let base = try l.decodeIfPresent(TimeInterval.self, forKey: .runBase) ?? 0
            if let open = sessions.last(where: { $0.isOpen }) {
                active = [ActiveRun(task: open.task, base: base, paused: false)]
            } else if let p = try l.decodeIfPresent(String.self, forKey: .pausedTask) {
                active = [ActiveRun(task: p, base: base, paused: true)]
                if try l.decodeIfPresent(Bool.self, forKey: .askResumeOnLaunch) == true {
                    pendingResume = [p]
                }
            }
        }
    }
}

enum ExportFormat { case csv, markdown }

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var data = AppData()
    @Published var now = Date()

    private var timer: Timer?
    private let fileURL: URL
    private var observers: [NSObjectProtocol] = []

    // 自動一時停止（スリープ・ロック）。理由がすべて解消されたら自動で再開
    enum AutoPauseReason { case sleep, lock }
    private var autoPauseReasons: Set<AutoPauseReason> = []
    private var autoPausedTasks: Set<String> = []
    private static let lastAliveKey = "lastAlive"

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")

        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppData.self, from: raw) {
            data = decoded
        }

        recoverUnfinishedSessions()
        fillMissingSince()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        observeSystemEvents()

        if !data.pendingResume.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.askResume()
            }
        }
    }

    private func tick() {
        now = Date()
        if Int(now.timeIntervalSince1970) % 15 == 0 {
            UserDefaults.standard.set(now, forKey: Self.lastAliveKey)
        }
    }

    /// 旧データ：計測開始時刻がない場合、累計時間から逆算して補う
    private func fillMissingSince() {
        var changed = false
        for i in data.active.indices where data.active[i].since == nil {
            let task = data.active[i].task
            let list = data.sessions.filter { $0.task == task && !$0.isAdjustment }
            var remain = data.active[i].base + (list.last(where: { $0.isOpen }).map { $0.duration(now: Date()) } ?? 0)
            var since = list.last?.start ?? Date()
            for x in list.reversed() {
                since = x.start
                remain -= x.duration(now: Date())
                if remain <= 1 { break }
            }
            data.active[i].since = since
            changed = true
        }
        if changed { save() }
    }

    // MARK: 日付（切り替え時刻を考慮）

    /// その時刻が属する「日」（切り替え時刻を考慮した日付の0:00）
    func logicalDay(_ date: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .hour, value: -data.dayStartHour, to: date)!
        return Calendar.current.startOfDay(for: shifted)
    }

    var logicalToday: Date { logicalDay(now) }

    /// その日の範囲（切り替え時刻〜翌日の切り替え時刻）
    func window(_ day: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.date(byAdding: .hour, value: data.dayStartHour, to: cal.startOfDay(for: day))!
        let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!
        let end = cal.date(byAdding: .hour, value: data.dayStartHour, to: next)!
        return (start, end)
    }

    func isInToday(_ date: Date) -> Bool { logicalDay(date) == logicalToday }

    /// セッションをその日の分だけに切り取る
    func segment(_ s: WorkSession, on day: Date) -> Segment? {
        if let a = s.adjust {
            return logicalDay(s.start) == day ? Segment(task: s.task, start: s.start, end: s.start, adjust: a, seconds: a) : nil
        }
        let realEnd = s.end ?? now
        if data.splitAtDayChange {
            let w = window(day)
            let st = max(s.start, w.start)
            let en = min(realEnd, w.end)
            guard en > st || (st == s.start && en == realEnd && logicalDay(s.start) == day) else { return nil }
            let ongoing = s.end == nil && en == realEnd
            return Segment(task: s.task, start: st, end: ongoing ? nil : en, adjust: nil,
                           seconds: max(0, en.timeIntervalSince(st)))
        } else {
            guard logicalDay(s.start) == day else { return nil }
            return Segment(task: s.task, start: s.start, end: s.end, adjust: nil,
                           seconds: realEnd.timeIntervalSince(s.start))
        }
    }

    func setDayStartHour(_ h: Int) {
        data.dayStartHour = max(0, min(23, h))
        save()
    }

    func setSplitAtDayChange(_ on: Bool) {
        data.splitAtDayChange = on
        save()
    }

    // MARK: 状態

    private func activeIndex(_ task: String) -> Int? {
        data.active.firstIndex(where: { $0.task == task })
    }
    private func openSessionIndex(_ task: String) -> Int? {
        data.sessions.lastIndex(where: { $0.task == task && $0.isOpen })
    }

    func isActive(_ task: String) -> Bool { activeIndex(task) != nil }
    func isRunning(_ task: String) -> Bool { data.active.contains { $0.task == task && !$0.paused } }
    func isPaused(_ task: String) -> Bool { data.active.contains { $0.task == task && $0.paused } }

    var runningTasks: [String] { data.active.filter { !$0.paused }.map(\.task) }
    var anyRunning: Bool { data.active.contains { !$0.paused } }

    /// 今回の計測の経過時間（一時停止中の時間は含まない）
    func elapsed(_ task: String) -> TimeInterval {
        guard let a = data.active.first(where: { $0.task == task }) else { return 0 }
        let since = (a.since ?? now).addingTimeInterval(-1)
        let today = logicalToday
        return data.sessions
            .filter { $0.task == task && !$0.isAdjustment && $0.start >= since }
            .reduce(0) { sum, s in
                if data.splitAtDayChange {
                    return sum + (segment(s, on: today)?.seconds ?? 0)
                }
                return sum + s.duration(now: now)
            }
    }

    /// 計測中・一時停止中のタスクの経過時間の合計（メニューバー表示用）
    var activeElapsedTotal: TimeInterval {
        data.active.reduce(0) { $0 + elapsed($1.task) }
    }

    // MARK: タイマー操作（タスクごと）

    func start(_ task: String) {
        clearAuto(task)
        if let i = activeIndex(task) {
            if data.active[i].paused { resume(task) }
            return
        }
        let t = Date()
        data.active.append(ActiveRun(task: task, since: t))
        data.sessions.append(WorkSession(task: task, start: t))
        save()
    }

    /// ボタンからの一時停止（自動再開の対象にしない）
    func manualPause(_ task: String) {
        clearAuto(task)
        pause(task)
    }

    private func pause(_ task: String) {
        guard let i = activeIndex(task), !data.active[i].paused else { return }
        if let s = openSessionIndex(task) {
            let end = Date()
            data.sessions[s].end = end
            data.active[i].base += end.timeIntervalSince(data.sessions[s].start)
        }
        data.active[i].paused = true
        save()
    }

    func resume(_ task: String) {
        clearAuto(task)
        guard let i = activeIndex(task), data.active[i].paused else { return }
        data.active[i].paused = false
        data.sessions.append(WorkSession(task: task, start: Date()))
        save()
    }

    func stop(_ task: String) {
        clearAuto(task)
        if let s = openSessionIndex(task) { data.sessions[s].end = Date() }
        data.active.removeAll { $0.task == task }
        data.pendingResume.removeAll { $0 == task }
        save()
    }

    func pauseAll() { for t in runningTasks { manualPause(t) } }
    func resumeAll() { for a in data.active where a.paused { resume(a.task) } }
    func stopAll() { for a in data.active { stop(a.task) } }

    // MARK: 自動一時停止・再開

    private func clearAuto(_ task: String) {
        autoPausedTasks.remove(task)
        if autoPausedTasks.isEmpty { autoPauseReasons.removeAll() }
    }

    private func observeSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()

        func on(_ center: NotificationCenter, _ name: Notification.Name,
                _ handler: @escaping @MainActor (Store) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self { handler(self) } }
            }
            observers.append(token)
        }

        on(ws, NSWorkspace.willSleepNotification) { $0.autoPause(.sleep) }
        on(ws, NSWorkspace.didWakeNotification) { $0.now = Date(); $0.autoResume(.sleep) }
        on(NotificationCenter.default, .NSCalendarDayChanged) { $0.now = Date() }
        on(dn, Notification.Name("com.apple.screenIsLocked")) { $0.autoPause(.lock) }
        on(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.autoResume(.lock) }
        on(ws, NSWorkspace.willPowerOffNotification) { $0.pauseForQuit() }
    }

    private func autoPause(_ reason: AutoPauseReason) {
        let running = runningTasks
        if !running.isEmpty {
            for t in running { pause(t) }
            autoPausedTasks.formUnion(running)
        }
        if !autoPausedTasks.isEmpty { autoPauseReasons.insert(reason) }
        UserDefaults.standard.set(Date(), forKey: Self.lastAliveKey)
    }

    private func autoResume(_ reason: AutoPauseReason) {
        guard autoPauseReasons.contains(reason) else { return }
        autoPauseReasons.remove(reason)
        guard autoPauseReasons.isEmpty else { return }   // ロック中はロック解除まで待つ
        let tasks = autoPausedTasks
        autoPausedTasks.removeAll()
        for a in data.active where a.paused && tasks.contains(a.task) {
            resume(a.task)
        }
    }

    /// アプリ終了・シャットダウン時：計測中のタスクを一時停止し、次回起動時に確認する
    func pauseForQuit() {
        let running = runningTasks
        guard !running.isEmpty else { return }
        for t in running { pause(t) }
        for t in running where !data.pendingResume.contains(t) { data.pendingResume.append(t) }
        save()
    }

    /// 強制終了・電源断などで計測中のまま終わっていた場合の後始末
    private func recoverUnfinishedSessions() {
        let lastAlive = UserDefaults.standard.object(forKey: Self.lastAliveKey) as? Date
        var changed = false
        for s in data.sessions.indices where data.sessions[s].isOpen {
            let task = data.sessions[s].task
            var end = lastAlive ?? data.sessions[s].start
            if end < data.sessions[s].start { end = data.sessions[s].start }
            data.sessions[s].end = end
            let dur = end.timeIntervalSince(data.sessions[s].start)
            if let i = activeIndex(task) {
                data.active[i].base += dur
                data.active[i].paused = true
            } else {
                data.active.append(ActiveRun(task: task, base: dur, paused: true, since: data.sessions[s].start))
            }
            if !data.pendingResume.contains(task) { data.pendingResume.append(task) }
            changed = true
        }
        // 古いデータとの整合性：開いたセッションがないのに「計測中」のものは一時停止扱い
        for i in data.active.indices where !data.active[i].paused && openSessionIndex(data.active[i].task) == nil {
            data.active[i].paused = true
            changed = true
        }
        if changed { save() }
    }

    private func askResume() {
        let tasks = data.pendingResume.filter { isPaused($0) }
        data.pendingResume = []
        save()
        guard !tasks.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        let list = tasks.map { "・\($0)（ここまで \(Fmt.clock(elapsed($0)))）" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "計測を再開しますか？"
        alert.informativeText = "再起動・シャットダウンのため、次の計測を一時停止しました。\n\n\(list)"
        alert.addButton(withTitle: tasks.count > 1 ? "すべて再開する" : "再開する")
        alert.addButton(withTitle: "一時停止のまま")
        alert.addButton(withTitle: "計測を終了")

        switch alert.runModal() {
        case .alertFirstButtonReturn: for t in tasks { resume(t) }
        case .alertThirdButtonReturn: for t in tasks { stop(t) }
        default: break
        }
    }

    // MARK: タスク操作

    func addTask(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !data.tasks.contains(trimmed) else { return }
        data.tasks.append(trimmed)
        save()
    }

    /// 並べ替え：task を target の位置へ移動する
    func moveTask(_ task: String, to target: String) {
        guard task != target,
              let from = data.tasks.firstIndex(of: task),
              let to = data.tasks.firstIndex(of: target) else { return }
        data.tasks.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    func deleteTask(_ name: String) { deleteTasks([name]) }

    /// タスクを一覧から削除（過去の記録は書き出し用に残す）
    func deleteTasks(_ names: Set<String>) {
        for n in names where isActive(n) { stop(n) }
        data.tasks.removeAll { names.contains($0) }
        resetNotesToday(names)   // 前の日までのメモは書き出し用に残す
        save()
    }

    /// 名前を変更（過去の記録・メモも新しい名前に引き継ぐ）。失敗時はエラーメッセージを返す
    func rename(_ old: String, to new: String) -> String? {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "名前を入力してください" }
        if name == old { return nil }
        if data.tasks.contains(name) { return "同じ名前のタスクがあります" }

        if let i = data.tasks.firstIndex(of: old) { data.tasks[i] = name }
        for i in data.sessions.indices where data.sessions[i].task == old {
            data.sessions[i].task = name
        }
        if let i = activeIndex(old) { data.active[i].task = name }
        if let i = data.pendingResume.firstIndex(of: old) { data.pendingResume[i] = name }
        if autoPausedTasks.remove(old) != nil { autoPausedTasks.insert(name) }
        if let h = data.noteHistory.removeValue(forKey: old) { data.noteHistory[name] = h }
        save()
        return nil
    }

    /// 今日の作業時間を指定した分数に書き換える
    func setTodayMinutes(_ task: String, minutes: Int) {
        data.sessions.removeAll {
            $0.task == task && $0.isAdjustment && isInToday($0.start)
        }
        let raw = todayTotal(for: task)
        let diff = TimeInterval(minutes * 60) - raw
        if abs(diff) >= 1 {
            let now = Date()
            data.sessions.append(WorkSession(task: task, start: now, end: now, adjust: diff))
        }
        save()
    }

    func resetToday(_ task: String) { resetToday([task]) }

    /// 今日の作業時間を0にする（計測中・一時停止中なら停止）
    func resetToday(_ names: Set<String>) {
        for n in names where isActive(n) { stop(n) }
        let today = logicalToday
        let w = window(today)
        if data.splitAtDayChange {
            // 前日から続いていた分は前日の記録として残し、今日の分だけ消す
            data.sessions = data.sessions.compactMap { s in
                guard names.contains(s.task) else { return s }
                if s.isAdjustment { return logicalDay(s.start) == today ? nil : s }
                let end = s.end ?? Date()
                if end <= w.start || s.start >= w.end { return s }
                if s.start < w.start { var c = s; c.end = w.start; return c }
                return nil
            }
        } else {
            data.sessions.removeAll { names.contains($0.task) && logicalDay($0.start) == today }
        }
        save()
    }

    // MARK: メモ（日付ごとに保存。日をまたぐと新しいメモになる）

    private func dayKey(_ day: Date) -> String { Fmt.day.string(from: day) }

    /// その日のメモ（指定なしなら今日）。その日に書いたメモだけを返す
    func note(for task: String, on day: Date? = nil) -> String {
        let key = dayKey(day ?? logicalToday)
        return data.noteHistory[task]?.first(where: { $0.day == key })?.text ?? ""
    }

    /// その日のメモを保存（指定なしなら今日。ほかの日のメモはそのまま残る）
    func setNote(_ task: String, _ text: String, on day: Date? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = dayKey(day ?? logicalToday)
        var list = data.noteHistory[task] ?? []
        let before = list.first(where: { $0.day == key })?.text
        list.removeAll { $0.day == key }
        if !t.isEmpty {
            list.append(NoteEntry(day: key, text: t))
            list.sort { $0.day < $1.day }
        }
        let after = list.first(where: { $0.day == key })?.text
        guard before != after else { return }   // 変化なしなら保存しない
        data.noteHistory[task] = list.isEmpty ? nil : list
        save()
    }

    /// 今日のメモを空にする（前の日までのメモはその日の記録として残る）
    func resetNotesToday(_ names: Set<String>) {
        for n in names { setNote(n, "") }
    }

    // MARK: 集計（開始日で振り分け。合計は各タスクの時間の足し算）

    func segments(on day: Date) -> [Segment] {
        data.sessions.compactMap { segment($0, on: day) }.sorted { $0.start < $1.start }
    }

    func totals(on day: Date) -> [(task: String, seconds: TimeInterval)] {
        var order: [String] = []
        var sums: [String: TimeInterval] = [:]
        for s in segments(on: day) {
            if sums[s.task] == nil { order.append(s.task) }
            sums[s.task, default: 0] += s.seconds
        }
        return order.map { ($0, max(0, sums[$0]!)) }
    }

    func dayTotal(_ day: Date) -> TimeInterval {
        totals(on: day).reduce(0) { $0 + $1.seconds }
    }

    func total(for task: String, on day: Date) -> TimeInterval {
        totals(on: day).first(where: { $0.task == task })?.seconds ?? 0
    }

    func todayTotal(for task: String) -> TimeInterval { total(for: task, on: logicalToday) }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let raw = try? enc.encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: 書き出し

    func export(_ format: ExportFormat, day: Date) {
        let dayStr = Fmt.day.string(from: day)
        let ext = format == .csv ? "csv" : "md"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = downloads.appendingPathComponent("task-log-\(dayStr).\(ext)")

        let text = format == .csv ? makeCSV(day: day) : makeMarkdown(day: day)
        var out = Data()
        if format == .csv { out.append(contentsOf: [0xEF, 0xBB, 0xBF]) } // Excel用BOM
        out.append(text.data(using: .utf8)!)

        do {
            try out.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    private func makeCSV(day: Date) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let d = Fmt.day.string(from: day)
        var lines = ["日付,タスク,作業時間(分),メモ"]
        for t in totals(on: day) {
            lines.append("\(d),\(q(t.task)),\(Int(t.seconds / 60)),\(q(note(for: t.task, on: day)))")
        }
        lines.append("\(d),\(q("合計")),\(Int(dayTotal(day) / 60)),")
        return lines.joined(separator: "\n") + "\n"
    }

    private func makeMarkdown(day: Date) -> String {
        let d = Fmt.day.string(from: day)
        let list = totals(on: day)
        var md = "# 作業ログ \(d)\n\n## タスク別合計\n\n| タスク | 作業時間 |\n|---|---:|\n"
        for t in list {
            md += "| \(t.task) | \(Fmt.minutes(t.seconds)) |\n"
        }
        md += "| **合計** | **\(Fmt.minutes(dayTotal(day)))** |\n"

        let withNotes = list.filter { !note(for: $0.task, on: day).isEmpty }
        if !withNotes.isEmpty {
            md += "\n## メモ\n"
            for t in withNotes {
                md += "\n### \(t.task)\n\n\(note(for: t.task, on: day))\n"
            }
        }

        md += "\n## タイムライン\n\n"
        let ss = segments(on: day)
        if ss.isEmpty { md += "記録なし\n" }
        for s in ss {
            if let a = s.adjust {
                let sign = a >= 0 ? "+" : "−"
                md += "- 手動調整　\(s.task)（\(sign)\(Fmt.minutes(abs(a)))）\n"
            } else {
                let st = Fmt.time.string(from: s.start)
                let en = s.end.map { Fmt.time.string(from: $0) } ?? "計測中"
                md += "- \(st)〜\(en)　\(s.task)（\(Fmt.minutes(s.seconds))）\n"
            }
        }
        return md
    }
}

// MARK: - Formatting

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static let label: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    static func minutes(_ sec: TimeInterval) -> String {
        let m = Int(sec / 60)
        return m >= 60 ? "\(m / 60)時間\(m % 60)分" : "\(m)分"
    }

    static func clock(_ sec: TimeInterval) -> String {
        let s = Int(sec)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 「90」や「1:30」を分数に変換
    static func parseMinutes(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "：", with: ":")
        if t.contains(":") {
            let p = t.split(separator: ":").map { Int($0) }
            guard p.count == 2, let h = p[0], let m = p[1], h >= 0, (0..<60).contains(m) else { return nil }
            return h * 60 + m
        }
        guard let m = Int(t), m >= 0 else { return nil }
        return m
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var newTask = ""
    @State private var dayOffset = 0
    @State private var selected: Set<String> = []
    @State private var bulkConfirm: BulkConfirm = .none
    @State private var resetNotesToo = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showSettings = false
    @State private var draggingTask: String?   // ドラッグで並べ替え中のタスク
    @State private var rowFrames: [String: CGRect] = [:]   // 各行の位置（並べ替えの判定用）

    private var exportDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: store.logicalToday)!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            currentStatus

            HStack {
                TextField("新しいタスク", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("追加", action: add)
            }

            if store.data.tasks.isEmpty {
                Text("タスクを追加してください").font(.caption).foregroundStyle(.secondary)
            } else {
                // 選択している時だけメニューを表示
                if !validSelection.isEmpty { bulkBar }

                VStack(spacing: 4) {
                    ForEach(store.data.tasks, id: \.self) { task in
                        TaskRow(task: task, day: exportDay, isSelected: Binding(
                            get: { selected.contains(task) },
                            set: { on in
                                if on { selected.insert(task) } else { selected.remove(task) }
                                if validSelection.isEmpty { bulkConfirm = .none }
                            }
                        ),
                        onDragMove: { y in dragMoved(task, to: y) },
                        onDragEnd: { draggingTask = nil })
                        .opacity(draggingTask == task ? 0.5 : 1)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: RowFrameKey.self,
                                                   value: [task: g.frame(in: .named("taskList"))])
                        })
                    }
                }
                .coordinateSpace(name: "taskList")
                .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(dayOffset <= -7)
                Text(dayOffset == 0 ? "今日 \(Fmt.label.string(from: exportDay))"
                                    : Fmt.label.string(from: exportDay))
                    .frame(minWidth: 110)
                Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(dayOffset >= 7)
                Spacer()
                Text("合計 \(Fmt.minutes(store.dayTotal(exportDay)))")
                    .font(.subheadline)
            }
            HStack {
                Button("CSV書き出し") { store.export(.csv, day: exportDay) }
                Button("MD書き出し") { store.export(.markdown, day: exportDay) }
                if dayOffset != 0 {
                    Button("今日") { dayOffset = 0 }
                }
            }

            Divider()

            HStack {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer()
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(showSettings ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("設定")
                Button("終了") {
                    store.stopAll()
                    NSApp.terminate(nil)
                }
            }

            if showSettings { settingsPanel }
        }
        .padding(14)
        .frame(width: 420)
    }

    // 計測中・一時停止中のタスク（複数）
    @ViewBuilder
    private var currentStatus: some View {
        if store.data.active.isEmpty {
            Text("停止中").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if store.data.active.count > 1 {
                    HStack {
                        Text("\(store.data.active.count)件を計測中")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.anyRunning {
                            Button("すべて一時停止") { store.pauseAll() }
                        } else {
                            Button("すべて再開") { store.resumeAll() }
                        }
                        Button("すべて停止") { store.stopAll() }
                    }
                    .controlSize(.small)
                }
                ForEach(store.data.active, id: \.task) { run in
                    ActiveRunCard(task: run.task, paused: run.paused)
                }
            }
        }
    }

    /// ドラッグ中：つかんだ位置が隣の行の真ん中を越えたら、その位置へ移動する
    private func dragMoved(_ task: String, to y: CGFloat) {
        draggingTask = task
        let tasks = store.data.tasks
        guard let from = tasks.firstIndex(of: task) else { return }
        let below = tasks[(from + 1)...].filter { (rowFrames[$0]?.midY ?? .infinity) < y }
        let above = tasks[..<from].filter { (rowFrames[$0]?.midY ?? -.infinity) > y }
        guard let target = below.last ?? above.first else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.moveTask(task, to: target) }
    }

    private func add() {
        store.addTask(newTask)
        newTask = ""
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("設定").font(.callout).bold()
            HStack {
                Text("日付の切り替え時刻")
                Picker("", selection: Binding(
                    get: { store.data.dayStartHour },
                    set: { store.setDayStartHour($0) }
                )) {
                    ForEach(0..<24, id: \.self) { h in Text("\(h):00").tag(h) }
                }
                .labelsHidden()
                .frame(width: 80)
            }
            Text("例：4:00にすると、深夜3時の作業は前の日の記録になります。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("日をまたいだら記録を区切る（次の日は0分から）", isOn: Binding(
                get: { store.data.splitAtDayChange },
                set: { store.setSplitAtDayChange($0) }
            ))
            .toggleStyle(.checkbox)
            Text(store.data.splitAtDayChange
                 ? "切り替え時刻までの分は前の日に記録され、次の日は0分から数えます。"
                 : "日をまたいだ計測は、開始した日にまとめて記録されます。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(PanelStyle())
    }

    private var validSelection: Set<String> {
        selected.intersection(store.data.tasks)
    }

    // まとめて操作のメニュー
    private var bulkBar: some View {
        let count = validSelection.count
        return VStack(alignment: .leading, spacing: 6) {
            switch bulkConfirm {
            case .delete:
                Text("選択した\(count)件のタスクを削除しますか？").font(.callout).bold()
                Text("一覧から消えます（書き出し用の過去の記録は残ります）。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("キャンセル") { bulkConfirm = .none }
                    Button("\(count)件を削除") {
                        store.deleteTasks(validSelection)
                        selected.removeAll()
                        bulkConfirm = .none
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            case .reset:
                Text("選択した\(count)件の今日の時間をリセットしますか？").font(.callout).bold()
                Text("今日の記録が0分になります。計測中のタスクが含まれる場合は停止します。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("メモもリセットする", isOn: $resetNotesToo)
                    .toggleStyle(.checkbox)
                if resetNotesToo {
                    Text("今日のメモが空になります。前の日までのメモは、その日の記録に残ります。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("キャンセル") {
                        bulkConfirm = .none
                        resetNotesToo = false
                    }
                    Button(resetNotesToo ? "\(count)件を時間・メモともリセット" : "\(count)件をリセット") {
                        store.resetToday(validSelection)
                        if resetNotesToo { store.resetNotesToday(validSelection) }
                        bulkConfirm = .none
                        resetNotesToo = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            case .none:
                HStack {
                    Text("\(count)件選択中").font(.callout)
                    Spacer()
                    Button("全選択") { selected = Set(store.data.tasks) }
                        .disabled(count == store.data.tasks.count)
                    Button("選択解除") { selected.removeAll() }
                    Button("時間リセット") { bulkConfirm = .reset }
                        .tint(.red)
                    Button("削除") { bulkConfirm = .delete }
                        .tint(.red)
                }
            }
        }
        .modifier(PanelStyle(color: bulkConfirm == .reset ? .orange : .red))
    }
}

struct ActiveRunCard: View {
    @EnvironmentObject var store: Store
    let task: String
    let paused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(paused ? "⏸ 一時停止中" : "▶ 計測中")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(task).font(.headline).lineLimit(1)
            }
            Spacer()
            Text(Fmt.clock(store.elapsed(task)))
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(paused ? .secondary : .primary)
            if paused {
                Button("再開") { store.resume(task) }
            } else {
                Button("一時停止") { store.manualPause(task) }
            }
            Button("停止") { store.stop(task) }
        }
        .padding(8)
        .background((paused ? Color.orange : Color.accentColor).opacity(0.12))
        .cornerRadius(8)
    }
}

// MARK: - 並べ替え

/// 各行の位置を集める
struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Task Row

enum BulkConfirm { case none, delete, reset }

enum RowMode { case normal, edit, confirmDelete, confirmReset, memo }

struct TaskRow: View {
    @EnvironmentObject var store: Store
    let task: String
    let day: Date            // 下で選んでいる日（メモはこの日の分を表示・編集する）
    @Binding var isSelected: Bool
    var onDragMove: (CGFloat) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    @GestureState private var isDragging = false

    @State private var mode: RowMode = .normal
    @State private var editName = ""
    @State private var editMinutes = ""
    @State private var editError: String?
    @State private var memoText = ""
    @State private var memoDay = Date.distantPast   // memoText がどの日のメモか（その日に保存する）
    @State private var resetNoteToo = false

    var body: some View {
        let isActive = store.isActive(task)
        let isRunning = store.isRunning(task)
        let memo = store.note(for: task, on: day)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // ここをつかんで上下にドラッグすると並べ替えられる
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    // 行の高さは変えずに、つかめる範囲だけ少し広げる
                    .contentShape(Rectangle().inset(by: -5))
                    .help("ドラッグで並べ替え")
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("taskList"))
                            .updating($isDragging) { _, state, _ in state = true }
                            .onChanged { onDragMove($0.location.y) }
                            .onEnded { _ in onDragEnd() }
                    )
                    // ドラッグが途中で取り消された場合も、薄い表示を元に戻す
                    .onChange(of: isDragging) { dragging in if !dragging { onDragEnd() } }

                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("まとめて操作する時に選択")

                Button {
                    if isRunning { store.manualPause(task) }
                    else { store.start(task) }   // 一時停止中なら再開、未計測なら開始
                } label: {
                    Image(systemName: isRunning ? "pause.circle.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(isRunning ? Color.orange : Color.accentColor)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task).lineLimit(1)
                    if !memo.isEmpty {
                        Text(memo).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(Fmt.minutes(store.total(for: task, on: day)))   // 下で選んでいる日の時間
                    .font(.caption).foregroundStyle(.secondary)

                // 編集 → メモ → リセット → 削除
                icon("pencil", help: "名前・時間を編集", active: mode == .edit) { toggle(.edit) }
                icon("note.text", help: "メモ", active: mode == .memo || !memo.isEmpty) { toggle(.memo) }
                icon("arrow.counterclockwise", help: "今日の時間をリセット", active: mode == .confirmReset) { toggle(.confirmReset) }
                icon("trash", help: "削除", active: mode == .confirmDelete) { toggle(.confirmDelete) }
            }

            switch mode {
            case .normal: EmptyView()
            case .edit: editPanel
            case .confirmDelete: deletePanel
            case .confirmReset: resetPanel
            case .memo: memoPanel
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }

    private func icon(_ name: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle(_ m: RowMode) {
        if mode == m { mode = .normal; return }
        switch m {
        case .edit:
            editName = task
            editMinutes = String(Int(store.todayTotal(for: task) / 60))
            editError = nil
        case .memo:
            loadMemo()
        default: break
        }
        mode = m
    }

    // MARK: パネル

    private var editPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("名前").lineLimit(1).fixedSize().frame(width: 80, alignment: .leading)
                TextField("タスク名", text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveEdit)
            }
            HStack {
                Text("今日の時間").lineLimit(1).fixedSize().frame(width: 80, alignment: .leading)
                TextField("分", text: $editMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit(saveEdit)
                Text("分（「1:30」でもOK）").font(.caption).foregroundStyle(.secondary)
            }
            if let e = editError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { mode = .normal }
                Button("保存", action: saveEdit).keyboardShortcut(.defaultAction)
            }
        }
        .modifier(PanelStyle())
    }

    private func saveEdit() {
        guard let minutes = Fmt.parseMinutes(editMinutes) else {
            editError = "時間は「90」や「1:30」の形で入力してください"
            return
        }
        if let err = store.rename(task, to: editName) {
            editError = err
            return
        }
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if minutes != Int(store.todayTotal(for: name) / 60) {
            store.setTodayMinutes(name, minutes: minutes)
        }
        mode = .normal
    }

    private var deletePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("「\(task)」を削除しますか？").font(.callout).bold()
            Text("一覧から消えます（書き出し用の過去の記録は残ります）。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { mode = .normal }
                Button("削除") { store.deleteTask(task) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .modifier(PanelStyle(color: .red))
    }

    private var resetPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("「\(task)」の今日の時間（\(Fmt.minutes(store.todayTotal(for: task)))）をリセットしますか？")
                .font(.callout).bold()
                .fixedSize(horizontal: false, vertical: true)
            Text("今日の記録が0分になります。計測中の場合は停止します。")
                .font(.caption).foregroundStyle(.secondary)
            if !store.note(for: task).isEmpty {
                Toggle("メモもリセットする", isOn: $resetNoteToo)
                    .toggleStyle(.checkbox)
                if resetNoteToo {
                    Text("今日のメモが空になります。前の日までのメモは、その日の記録に残ります。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") {
                    mode = .normal
                    resetNoteToo = false
                }
                Button(resetNoteToo ? "時間・メモをリセット" : "リセット") {
                    store.resetToday(task)
                    if resetNoteToo { store.resetNotesToday([task]) }
                    resetNoteToo = false
                    mode = .normal
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .modifier(PanelStyle(color: .orange))
    }

    private var memoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(memoDay == store.logicalToday ? "今日のメモ（\(Fmt.label.string(from: memoDay))）"
                                                   : "\(Fmt.label.string(from: memoDay))のメモ")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("入力すると自動で保存されます").font(.caption2).foregroundStyle(.secondary)
            }
            TextEditor(text: $memoText)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("閉じる") { mode = .normal }
            }
        }
        .modifier(PanelStyle())
        // 入力のたびに自動保存（入力欄に出ている日のメモとして保存する）
        .onChange(of: memoText) { text in store.setNote(task, text, on: memoDay) }
        // 下で日付を切り替えた時・日をまたいだ時は、その日のメモに切り替える
        .onChange(of: day) { _ in loadMemo() }
    }

    private func loadMemo() {
        memoDay = day
        memoText = store.note(for: task, on: day)
    }
}

struct PanelStyle: ViewModifier {
    var color: Color = .secondary
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(color.opacity(0.08))
            .cornerRadius(6)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onTerminate: (@MainActor () -> Void)?
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.onTerminate?()
    }
}

@main
struct TaskTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: Store

    init() {
        let s = Store()
        _store = StateObject(wrappedValue: s)
        AppDelegate.onTerminate = { [weak s] in s?.pauseForQuit() }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    // 1件ならタスク名、2件以上なら「件数＋合計」
    @ViewBuilder
    private var menuBarLabel: some View {
        let active = store.data.active
        if active.isEmpty {
            Image(systemName: "timer")
        } else {
            let icon = store.anyRunning ? "⏱" : "⏸"
            if active.count == 1 {
                let task = active[0].task
                let name = task.count > 12 ? String(task.prefix(12)) + "…" : task
                Text("\(icon) \(name) \(Fmt.minutes(store.elapsed(task)))")
            } else {
                Text("\(icon) \(active.count)件 \(Fmt.minutes(store.activeElapsedTotal))")
            }
        }
    }
}
