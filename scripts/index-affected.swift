#!/usr/bin/env swift
// index-affected.swift — affected-tests.sh 的索引级选择器(CLI)。
// 改动的 .swift 文件 → 该文件定义的符号(USR)→ 反向引用闭包(传递)→
// 受影响文件清单(仓库相对路径,stdout 每行一个,含输入文件自身)。
// 任何不健康信号 exit 3,affected-tests.sh 见 3 回落文本匹配,选择器永不挂掉流程。
//
// 依赖:Xcode 工具链 libIndexStore.dylib,零链接期耦合(经同目录 index-affected-shim.c
// 垫片 dlopen;Swift 的 @convention(c) 表达不了按值返回的 indexstore_string_ref_t,
// 故有垫片,由本脚本按需 clang 编译进 <repo>/build/ 并按源 mtime 缓存)。
// C API 签名依据 indexstore-db 公开头(2026-11-03 快照):
//   Sources/IndexStoreCAPI/include/IndexStoreCAPI/indexstore_functions.h
//   role 位值: DECLARATION=1<<0 DEFINITION=1<<1 REFERENCE=1<<2 READ=1<<3
//              WRITE=1<<4 CALL=1<<5 ADDRESSOF=1<<7;依赖 kind: UNIT=1 RECORD=2 FILE=3
// record 名**不猜**:经 unit 依赖(kind=RECORD)拿 store 自己报告的文件路径
// (裸绝对路径假设实测 0/262 覆盖,2026-11-03)。
//
// 新鲜度:索引是该 worktree 最近一次构建的快照;「改完未构建就跑」窗口内闭包按旧图
// 计算,方向偏安全(旧名引用者仍被选出)。改动文件不在索引=新文件/未构建 → exit 3。
//
// 用法:
//   probe    <datastore> <repo-root> <repo相对文件>    探针:record 覆盖/定义 USR/反查引用
//   closure  <datastore> <repo-root> <repo相对文件...>  传递闭包
// 退出码:0 健康;3 索引不健康(dylib/store/record 缺失);2 用法错误。

import Darwin
import Foundation

// MARK: - C API 位值(出处见文件头注释)

private let roleDeclaration: UInt64 = 1 << 0
private let roleDefinition: UInt64 = 1 << 1
private let roleReference: UInt64 = 1 << 2
private let roleRead: UInt64 = 1 << 3
private let roleWrite: UInt64 = 1 << 4
private let roleCall: UInt64 = 1 << 5
private let roleAddressOf: UInt64 = 1 << 7
private let depKindRecord: UInt32 = 2
/// 「该文件定义/声明了什么」:协议方法在协议体里只有 DECLARATION,漏掉会漏种子。
private let defBits: UInt64 = roleDeclaration | roleDefinition
/// 「该文件引用了什么」:不含 DECLARATION/DEFINITION/DYNAMIC(修饰位非引用)。
private let refBits: UInt64 = roleReference | roleRead | roleWrite | roleCall | roleAddressOf

private func unhealthy(_ msg: String) -> Never {
    FileHandle.standardError.write(("index-affected: " + msg + "\n").data(using: .utf8)!)
    exit(3)
}

private func usage() -> Never {
    FileHandle.standardError.write("""
    usage:
      index-affected.swift probe   <datastore> <repo-root> <repo-relative-file>
      index-affected.swift closure <datastore> <repo-root> <repo-relative-file>...
    """.data(using: .utf8)!)
    exit(2)
}

// MARK: - 垫片 ABI 函数指针(@convention(c) 回调不能捕获,只能住全局)

private enum IS {
    typealias LoadFn = @convention(c) (UnsafePointer<CChar>) -> Bool
    typealias StoreCreateFn = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias ReaderCreateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>)
        -> UnsafeMutableRawPointer?
    typealias ReaderDisposeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias OccApplyFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool
    ) -> Bool
    typealias OccRolesFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
    typealias OccSymbolFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias SymStringFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>, Int) -> Int
    typealias SymKindFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias UnitsApplyFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Bool
    ) -> Bool
    typealias UnitReaderCreateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>)
        -> UnsafeMutableRawPointer?
    typealias UnitReaderDisposeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias DepsApplyFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool
    ) -> Bool
    typealias DepKindFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    typealias DepFilepathFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>, Int) -> Int
    typealias DepNameFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>, Int) -> Int

    static var loadShim: LoadFn!
    static var storeCreate: StoreCreateFn!
    static var readerCreate: ReaderCreateFn!
    static var readerDispose: ReaderDisposeFn!
    static var occurrencesApply: OccApplyFn!
    static var occurrenceRoles: OccRolesFn!
    static var occurrenceSymbol: OccSymbolFn!
    static var symbolUsr: SymStringFn!
    static var symbolName: SymStringFn!
    static var symbolKind: SymKindFn!
    static var unitsApply: UnitsApplyFn!
    static var unitReaderCreate: UnitReaderCreateFn!
    static var unitReaderDispose: UnitReaderDisposeFn!
    static var depsApply: DepsApplyFn!
    static var depKind: DepKindFn!
    static var depFilepath: DepFilepathFn!
    static var depName: DepNameFn!
    /// 回调里建 unit reader 需要它,而 @convention(c) 不能捕获——住全局。
    static var currentStore: UnsafeMutableRawPointer?

    /// $DEVELOPER_DIR 优先(尊重自定义工具链),回落 xcode-select -p。
    private static func libIndexStorePath() -> String {
        let toolchain: String
        if let devDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !devDir.isEmpty {
            toolchain = devDir
        } else {
            let out = Pipe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            p.arguments = ["-p"]
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run()
                p.waitUntilExit()
            } catch { unhealthy("xcode-select -p 跑不了:\(error)") }
            toolchain = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return toolchain + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
    }

    /// 垫片按需编译到 <repoRoot>/build/(源 mtime 缓存),返回其路径。
    private static func ensureShim(repoRoot: String) -> String {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let src = dir.appendingPathComponent("index-affected-shim.c").path
        let out = repoRoot + "/build/index-affected-shim.dylib"
        let fm = FileManager.default
        func mtime(_ path: String) -> Date {
            (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        }
        guard fm.fileExists(atPath: src) else { unhealthy("垫片源缺失:\(src)") }
        if !fm.fileExists(atPath: out) || mtime(src) > mtime(out) {
            try? fm.createDirectory(atPath: repoRoot + "/build", withIntermediateDirectories: true)
            let err = Pipe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            p.arguments = ["-dynamiclib", "-O2", "-o", out, src]
            p.standardError = err
            do { try p.run()
                p.waitUntilExit()
            } catch { unhealthy("clang 启动失败:\(error)") }
            guard p.terminationStatus == 0 else {
                unhealthy("clang 编译垫片失败:" + String(
                    decoding: err.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ))
            }
        }
        return out
    }

    static func load(repoRoot: String) {
        let shim = ensureShim(repoRoot: repoRoot)
        guard let handle = dlopen(shim, RTLD_NOW) else {
            unhealthy("dlopen 垫片失败:\(String(cString: dlerror()))")
        }
        func ptr<T>(_ name: String, _ type: T.Type) -> T {
            guard let p = dlsym(handle, name) else { unhealthy("dlsym \(name) 失败(垫片过期?)") }
            return unsafeBitCast(p, to: type)
        }
        loadShim = ptr("ia_load", LoadFn.self)
        storeCreate = ptr("ia_store_create", StoreCreateFn.self)
        readerCreate = ptr("ia_reader_create", ReaderCreateFn.self)
        readerDispose = ptr("ia_reader_dispose", ReaderDisposeFn.self)
        occurrencesApply = ptr("ia_occurrences_apply", OccApplyFn.self)
        occurrenceRoles = ptr("ia_occurrence_roles", OccRolesFn.self)
        occurrenceSymbol = ptr("ia_occurrence_symbol", OccSymbolFn.self)
        symbolUsr = ptr("ia_symbol_usr", SymStringFn.self)
        symbolName = ptr("ia_symbol_name", SymStringFn.self)
        symbolKind = ptr("ia_symbol_kind", SymKindFn.self)
        unitsApply = ptr("ia_units_apply", UnitsApplyFn.self)
        unitReaderCreate = ptr("ia_unit_reader_create", UnitReaderCreateFn.self)
        unitReaderDispose = ptr("ia_unit_reader_dispose", UnitReaderDisposeFn.self)
        depsApply = ptr("ia_unit_deps_apply", DepsApplyFn.self)
        depKind = ptr("ia_dep_kind", DepKindFn.self)
        depFilepath = ptr("ia_dep_filepath", DepFilepathFn.self)
        depName = ptr("ia_dep_name", DepNameFn.self)
        let lib = libIndexStorePath()
        guard lib.withCString({ loadShim($0) }) else { unhealthy("ia_load libIndexStore 失败:\(lib)") }
    }
}

private func shimString(_ fn: IS.SymStringFn, _ sym: UnsafeMutableRawPointer?) -> String? {
    guard let sym else { return nil }
    var buf = [CChar](repeating: 0, count: 4096)
    let fullLength = fn(sym, &buf, buf.count)
    guard fullLength > 0 else { return nil }
    guard fullLength < buf.count else { unhealthy("USR/符号名超过 4096 字节缓冲(长度 \(fullLength))") }
    return String(cString: buf)
}

private func usrString(_ sym: UnsafeMutableRawPointer?) -> String? {
    shimString(IS.symbolUsr, sym)
}

private func kindName(_ sym: UnsafeMutableRawPointer?) -> String {
    switch IS.symbolKind(sym) {
    case 5: "enum"
    case 6: "struct"
    case 7: "class"
    case 8: "protocol"
    case 9: "extension"
    case 11: "typealias"
    case 12: "func"
    case 16: "method"
    case 17: "class-method"
    case 18: "static-method"
    case 13: "var"
    case 19: "property"
    case 22: "init"
    case 23: "deinit"
    default: "kind\(IS.symbolKind(sym))"
    }
}

// MARK: - 阶段一:unit 依赖枚举 → 仓库内 record 名(store 自己报告的,不猜)

private final class RepoRecords {
    var unitCount = 0
    /// repo相对路径 → store 报告的 record 名(同一文件多 unit 引用只留一份,名字相同)。
    var storeNameFor: [String: String] = [:]
    /// 诊断:依赖 kind 分布(UNIT=1 RECORD=2 FILE=3)与各形状采样(各 ≤5)。
    var kindCount: [UInt32: Int] = [:]
    var swiftSamples = Set<String>()
    var usersSamples = Set<String>()
    var outsideSamples = Set<String>()

    /// recordName = record_reader_create 要的键("Foo.swift-38QI52BNQY8ZV");filePath = 源文件路径,仓库归属按它判。
    func note(recordName: String, filePath: String, kind: UInt32) {
        kindCount[kind, default: 0] += 1
        if filePath.hasSuffix(".swift"), swiftSamples.count < 5 {
            swiftSamples.insert(filePath)
        }
        if filePath.hasPrefix("/Users"), usersSamples.count < 5 {
            usersSamples.insert(filePath)
        }
        if filePath.hasPrefix(repoPrefixGlobal), filePath.count > repoPrefixGlobal.count {
            let rel = String(filePath.dropFirst(repoPrefixGlobal.count))
            if rel.hasPrefix("NemoNotch/") || rel.hasPrefix("NemoNotchTests/") {
                storeNameFor[rel] = recordName
                return
            }
        }
        if outsideSamples.count < 5 {
            outsideSamples.insert(filePath)
        }
    }
}

/// units 回调不能捕获,@convention(c) 需要的仓库前缀住全局(单线程脚本)。
private var repoPrefixGlobal = ""

private func enumRepoRecords(repoRoot: String) -> RepoRecords {
    final class UnitDeps {
        let owner: RepoRecords
        let reader: UnsafeMutableRawPointer?
        init(owner: RepoRecords, reader: UnsafeMutableRawPointer?) {
            self.owner = owner
            self.reader = reader
        }
    }
    let result = RepoRecords()
    repoPrefixGlobal = repoRoot + "/"
    let unitsCb: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Bool = { ctx, cName in
        let repo = Unmanaged<RepoRecords>.fromOpaque(ctx!).takeUnretainedValue()
        repo.unitCount += 1
        guard let ur = IS.unitReaderCreate(IS.currentStore, cName) else { return true }
        defer { IS.unitReaderDispose(ur) }
        let deps = UnitDeps(owner: repo, reader: ur)
        let depsCb: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool = { ctx, dep in
            let d = Unmanaged<UnitDeps>.fromOpaque(ctx!).takeUnretainedValue()
            var nameBuf = [CChar](repeating: 0, count: 1024)
            let nameLen = IS.depName(dep, &nameBuf, nameBuf.count)
            var pathBuf = [CChar](repeating: 0, count: 8192)
            let pathLen = IS.depFilepath(dep, &pathBuf, pathBuf.count)
            guard nameLen > 0, nameLen < nameBuf.count, pathLen > 0, pathLen < pathBuf.count else { return true }
            d.owner.note(
                recordName: String(cString: nameBuf),
                filePath: String(cString: pathBuf),
                kind: IS.depKind(dep)
            )
            return true
        }
        _ = IS.depsApply(ur, Unmanaged.passUnretained(deps).toOpaque(), depsCb)
        return true
    }
    _ = IS.unitsApply(IS.currentStore, Unmanaged.passUnretained(result).toOpaque(), unitsCb)
    return result
}

// MARK: - 阶段二:record 读取 → defs[file]/refs[usr] 两张表

/// 单文件的回调收集器(经 Unmanaged 指针进 @convention(c) 上下文)。
private final class FileFacts {
    var defs = Set<String>()
    var refs = Set<String>()
}

private struct RepoIndex {
    let records: RepoRecords
    let filesWithRecord: Set<String>
    let defs: [String: Set<String>]
    let refs: [String: Set<String>]
}

private func repoSwiftFiles(_ repoRoot: String) -> [String] {
    var result: [String] = []
    for top in ["NemoNotch", "NemoNotchTests"] {
        guard let enumerator = FileManager.default.enumerator(atPath: repoRoot + "/" + top) else { continue }
        for case let rel as String in enumerator where rel.hasSuffix(".swift") {
            result.append(top + "/" + rel)
        }
    }
    return result.sorted()
}

private func scanIndex(repoRoot: String) -> RepoIndex {
    let records = enumRepoRecords(repoRoot: repoRoot)
    var filesWithRecord = Set<String>()
    var defs: [String: Set<String>] = [:]
    var refs: [String: Set<String>] = [:]
    for (rel, storeName) in records.storeNameFor.sorted(by: { $0.key < $1.key }) {
        let facts = FileFacts()
        storeName.withCString { cName in
            guard let reader = IS.readerCreate(IS.currentStore, cName) else { return }
            defer { IS.readerDispose(reader) }
            filesWithRecord.insert(rel)
            let ctx = Unmanaged.passUnretained(facts).toOpaque()
            let applier: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool = { ctx, occ in
                let f = Unmanaged<FileFacts>.fromOpaque(ctx!).takeUnretainedValue()
                let roles = IS.occurrenceRoles(occ)
                guard roles != 0, let sym = IS.occurrenceSymbol(occ) else { return true }
                if roles & defBits != 0, let usr = usrString(sym) {
                    f.defs.insert(usr)
                }
                if roles & refBits != 0, let usr = usrString(sym) {
                    f.refs.insert(usr)
                }
                return true
            }
            _ = IS.occurrencesApply(reader, ctx, applier)
        }
        if !facts.defs.isEmpty {
            defs[rel] = facts.defs
        }
        for usr in facts.refs {
            refs[usr, default: []].insert(rel)
        }
    }
    return RepoIndex(records: records, filesWithRecord: filesWithRecord, defs: defs, refs: refs)
}

// MARK: - 传递闭包(BFS:文件 → 其定义 USR → 引用文件 → 新文件的 defs …)

private func closure(seeds: [String], index: RepoIndex) -> Set<String>? {
    let missing = seeds.filter { !index.filesWithRecord.contains($0) }
    guard missing.isEmpty else {
        FileHandle.standardError.write(
            ("index-affected: 以下文件不在索引中(新文件未构建/路径不符):" + missing.joined(separator: ", ") + "\n")
                .data(using: .utf8)!
        )
        return nil
    }
    var affected = Set(seeds)
    var queue = seeds
    while !queue.isEmpty {
        var next: [String] = []
        for file in queue {
            for usr in index.defs[file] ?? [] {
                for refFile in index.refs[usr] ?? [] where affected.insert(refFile).inserted {
                    next.append(refFile)
                }
            }
        }
        queue = next
    }
    return affected
}

// MARK: - main

let args = CommandLine.arguments
if args.count < 4 {
    usage()
}

let mode = args[1]
let datastore = args[2]
let repoRoot = URL(fileURLWithPath: args[3]).standardizedFileURL.path

guard FileManager.default.fileExists(atPath: datastore) else { unhealthy("datastore 不存在:\(datastore)") }
IS.load(repoRoot: repoRoot)
guard let store = datastore.withCString({ IS.storeCreate($0) }) else {
    unhealthy("store_create 失败(目录不是索引库?):\(datastore)")
}

IS.currentStore = store

switch mode {
case "probe":
    if args.count != 5 {
        usage()
    }
    let target = args[4]
    let index = scanIndex(repoRoot: repoRoot)
    let all = repoSwiftFiles(repoRoot)
    let pct = all.isEmpty ? 0 : index.filesWithRecord.count * 100 / all.count
    print(
        "units: \(index.records.unitCount), repo swift files: \(all.count), with index record: \(index.filesWithRecord.count) (\(pct)%)"
    )
    let kinds = index.records.kindCount.sorted { $0.key < $1.key }
        .map { "kind\($0.key)=\($0.value)" }.joined(separator: " ")
    print("dep kinds: \(kinds)")
    for sample in index.records.swiftSamples.sorted().prefix(3) {
        print("  [.swift dep 样例] \(String(sample.prefix(140)))")
    }
    for sample in index.records.usersSamples.sorted().prefix(3) {
        print("  [/Users dep 样例] \(String(sample.prefix(140)))")
    }
    for sample in index.records.outsideSamples.sorted().prefix(3) {
        print("  [仓库外 record 样例] \(String(sample.prefix(140)))")
    }
    let targetDefs = (index.defs[target] ?? []).sorted()
    print("definitions in \(target): \(targetDefs.count)")
    for usr in targetDefs.prefix(40) {
        print("  \(usr)")
    }
    guard let first = targetDefs.first else { break }
    let refFiles = (index.refs[first] ?? []).sorted()
    print("reverse refs of \(first): \(refFiles.count) files")
    for f in refFiles {
        print("  \(f)")
    }
case "closure":
    if args.count < 5 {
        usage()
    }
    let seeds = Array(args[4...])
    let index = scanIndex(repoRoot: repoRoot)
    // 前置健康:索引零测试记录(xcodebuild build 不编测试目标;须 build-for-testing
    // 或跑过一次测试)→ 闭包结构性不可能含测试,交给文本回落而不是静默全量。
    if !index.filesWithRecord.contains(where: { $0.hasPrefix("NemoNotchTests/") }) {
        unhealthy("索引无 NemoNotchTests 记录(测试目标未构建过——跑一次测试或 build-for-testing)")
    }
    guard let affected = closure(seeds: seeds, index: index) else { exit(3) }
    for line in affected.sorted() {
        print(line)
    }
default:
    usage()
}
