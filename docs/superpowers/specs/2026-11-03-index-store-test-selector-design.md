# Index Store 版测试选择器 — 设计(2026-11-03)

## 背景与问题

现状 `scripts/affected-tests.sh`(2026-11-01 上线):改动 .swift → 顶层符号名 → 测试文件 grep。三个局限:

1. **只一跳,不传递**。用户要的是调用链:"a 引用了 b,b 引用了 c,那 c 改动会把 c b a 都测试一遍"。文本法做不到——改底层纯函数,引用它的中间层文件名/符号名不出现在任何测试文件里,漏选后只能靠全量兜底。
2. **选集偏大**。同名符号 grep 命中即选(方向安全:只会多跑),但 `start` 这类常见名一旦降级启用就吸半个测试目录。
3. **对声明形状有假设**。靠列 0 顶层声明正则抽符号、靠"文件名=类名"约定(80/80 文件满足)。

而编译器索引就在本机白放着:每个 worktree 构建后,各自 DerivedData 里有 `Index.noindex/DataStore`(实测每个 43–48MB,v5,主检出 659 units/1162 records,随最近一次构建更新——`xcodebuild`/`test.sh`/`build.sh` 都产)。查询它的 `libIndexStore.dylib` 在 Xcode 工具链里(929KB;无公开头文件、无系统级副本)。

实测基线(2026-11-03):全量 632 例 ≈ 2:03,文本法子集 5.6s——选择器的优化空间在"把不该跑的 2 分钟砍掉",索引法再把"文本法漏选导致的全量回落"变成"精确子集"。

## 目标

- diff 出的 .swift 文件 → **编译器级反向引用闭包(传递)** → 受影响测试文件 → `test.sh --only`(既有出口语义不变)。
- **零新外部依赖**:单文件 Swift 脚本 `dlopen` 工具链 libIndexStore,C API 子集用 `@convention(c)` 函数指针自声明——API 全是不透明指针,不需要 SPM 包/C target/编译步骤(repo 已有 dlsym 先例:`SecKeychainSetUserInteractionAllowed`、SkyLight 委托)。
- **文本匹配保留为回落路径**,不是替换:索引缺失/陈旧/CLI 异常 → 走现有文本逻辑,单一出口语义(空→全量,宁多跑不漏跑)不变。

## 非目标

- 不动 `test.sh`、feat-done 测试门禁语义(锚点只认全量、零用例守卫、回落全量)。
- 不做 CI 索引共享(CI 不跑单测,索引只在开发机有意义)。
- 不处理非 Swift 变更(xcstrings/pbxproj/脚本——现行为保持:无 .swift 改动直接过)。
- 选择粒度仍是**测试类**(文件),不做 USR 级函数粒度过滤。
- 不清理想化边界(如删除 worktree 的化石 DerivedData)——那是 build 卫生问题,另议。

## 方案

### CLI:`scripts/index-affected.swift`(单文件,`swift scripts/index-affected.swift` 直跑)

- **加载**:`dlopen("<xcode-select -p>/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib")`;`$DEVELOPER_DIR` 优先(尊重自定义工具链),再回落 `xcode-select -p`。dlopen 失败 → exit 3。
- **自声明 C API 子集**(对照 indexstore-db 公开 `IndexStore.h` 校签名):store_create / records_apply / record_reader_create / record_reader_occurrences_apply / symbol_usr / occurrence_roles 等,全部 `@convention(c)` + `unsafeBitCast(dlsym(...))`。
- **算法(一次全扫描 + 内存 BFS)**:
  1. 遍历 DataStore 全部 record(record 名即源文件路径——探针任务先验证形状),只留仓库根下的(app+test 源;SPM checkout/SDK 剔除)。
  2. 每 record 收集两类事实:**该文件定义的 USR 集**(occurrence roles 含 definition)+ **该文件引用的 USR 集** → 内存两张表 `defs[file]→USRs`、`refs[usr]→files`。
  3. BFS:changed 文件的定义 USR 为起点 → `refs` 反查文件 → 新文件入受影响集 → 其 `defs` 入 frontier → 至不动点(文件级 visited 防环)。
  4. **stdout**:受影响文件(仓库相对路径)每行一个;**exit 0**。
- **健康语义**:任一 changed .swift 不在索引 record 集 / store 打不开 / 遍历中断 → **exit 3**(区别于"正常算完为空"),shell 侧见 3 即回落文本匹配。

### `affected-tests.sh` 接线(中段替换,两头不动)

- **定位本 worktree 的索引**:扫 `~/Library/Developer/Xcode/DerivedData/NemoNotch-*/info.plist` 的 `WorkspacePath`,与 `$root/NemoNotch.xcodeproj` 绝对路径精确匹配(实测:每个 worktree 一个 DerivedData,化石目录自然不匹配)。找不到 → 文本回落。
- 调 CLI 拿闭包 → ∩ `NemoNotchTests/*.swift` → 套件名 = 文件名(**只认 `*Tests.swift`**;未来出现非 Tests 后缀的测试辅助文件只记日志不进 --only,防零用例守卫假警报)+ 改动的测试文件自身照旧直接加入。
- CLI exit 3 / 无 DataStore / 输出含仓库外路径 → 文本匹配原路径(现有函数原样保留,不删)。
- 出口语义不变:类列表 → `test.sh --only`;**空闭包也回落全量**(v1 不信空——CLI 有 bug 时最坏是多跑,绝不会静默漏跑),打印闭包规模让异常可见。

### 新鲜度与安全边界

- 索引 = 该 worktree **最近一次构建**的快照。改完代码没构建就跑选择器:索引里是旧图,选集=旧引用者,方向偏安全(新符号未进索引 → 该文件大概率也不在 record 集?不——文件在、内容旧;此情形闭包按旧图算,选出的测试覆盖旧名引用,新名引用的测试可能漏)。**兜底**:这只发生在"改完从未构建"的窗口,而 affected-tests.sh 的下一步就是构建+跑测试(xcodebuild 会顺带刷新索引);且开发中至少构建过一次才有可行 worktree。风险窗口=「改代码→不构建→直接跑 affected-tests」,记录在脚本头注释,不额外加机制。
- 删除的文件:索引里旧 record 仍在,闭包按旧图算——安全方向。
- USR 天然消歧同名符号、精确到重载/协议见证——文本法的同名误吸/漏吸两头都消。

## 验收(全部梯级 4:真跑过)

1. **探针**(可行性闸门,plan 任务 1):对主检出真索引,① 列出仓库内 record 数;② 抽 `CompletionToastQueue.swift` 打印其定义 USR;③ 反查其中一个 USR 的引用文件,人工比对 `rg` 结果。
2. **端到端**:`affected-tests.sh --files NemoNotch/Services/CompletionToastQueue.swift` → 选出的测试类 ⊇ 文本法结果,且含间接引用者(如经 `CompletionFlashService` 传递链的测试)。
3. **回落分支真的走到**:临时移走 DataStore 路径(或 DEVELOPER_DIR 指向空)→ 确认走文本匹配而非静默失败;恢复后回索引路径。
4. **时长水位**:记录索引扫描耗时 + 子集测试耗时,写进评审记录(新流程度量)。

## 备选与弃用理由

- **IndexStoreDB SPM 依赖**:多一个网络依赖+版本漂移,而我们只需要 ~8 个 C 函数;弃。
- **自写 AST/SwiftSyntax**:只有单文件语法,引用解析需要 typecheck 才准(等于重造编译器前端);弃。
- **ripwire --affected**:Swift Testing 宏测试解析不了(tests=0 实测,已记录);弃。
- **保留文本匹配而非删除**:fresh worktree 未构建过、工具链搬走、CLI 损坏时必须仍有可用选择器;回落路径就是冷启动路径。
