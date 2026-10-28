/* zcode-workflow
description: NemoNotch 开发执行环,双入口。①feature 入口(task/worktree/branch/planPath
  四参):实现子代理按 executing-plans 逐任务实现,双席评审并行(评审员按仓库清单+挑战者四镜头),findings 合并写
  .reviews,P1/P2 回流修复 ≤3 轮。②bug 入口(symptom 一参,与四参二选一):先诊断——只读复现+≤3
  假设并行探针(单变量,证据标梯级)+单席证据链挑战;复现确凿、证据链审计成立、修法机械、有确认探针且挑战者建议 proceed
  五者俱全才免闸直通,否则根因拍板闸停下问运行方(未复现的根因系推断,须用户确认);建环段自建 worktree+plan(首任务=失败测试)后合流
  feature 开发段,合流评审含 bug 专项镜头(失败测试必须由红转绿、修复与根因因果对应)。脑暴、合并与 push 留在主对话。
whenToUse: feature 类任务(主对话已 brainstorming 脑暴、git feat 建 worktree、writing-plans
  写好 plan)以四参启动;bug 类任务(有可观察症状、根因未知)以 symptom 启动,先诊断后修。investigation
  只读调查不启动本工作流。
args:
  branch:
    type: string
    description: feature 分支名(不含 feature/ 前缀),主对话已创建;feature 入口必填,bug 入口忽略
  planPath:
    type: string
    description: plan 文档路径(仓库相对,worktree 内 docs/superpowers/plans/ 下);feature 入口必填,bug 入口忽略
  symptom:
    type: string
    description: bug 入口:症状描述+期望 vs 实际(与四参二选一;给了 symptom 就走诊断段)
  task:
    type: string
    description: 任务描述,含脑暴澄清后的目标与约束;feature 入口必填,bug 入口忽略
  worktree:
    type: string
    description: 主对话已建好的 worktree 路径(仓库相对,如 .worktree/xxx);feature 入口必填,bug 入口忽略
*/
interface Implementation {
  /** 本轮实现的提交哈希(短哈希),按 plan 任务逐个提交。 */
  commits: string[];
  /** 自跑的命令与退出码证据,如 "lint.sh --staged 退出码 0"。 */
  checks: string[];
  /** 交接:完成了 plan 的哪些任务、与方案的偏差及原因(无偏差则说明)。 */
  summary: string;
  /** 实现者没把握、希望评审重点看的面。 */
  risks: string[];
}

interface Finding {
  /** P1 必须修 / P2 应修 / P3 可选。 */
  severity: "P1" | "P2" | "P3";
  /** 证据位置,file:line。 */
  where: string;
  /** 一句话说清问题本身(不是修法)。 */
  problem: string;
  /** 建议的修法,一句话。 */
  suggestion: string;
}

interface Review {
  /** 仓库门禁词表:APPROVED / REJECTED。 */
  verdict: "APPROVED" | "REJECTED";
  findings: Finding[];
  /** 重跑过的命令与退出码;评审席另记评审时的分支 head 短哈希(判决新鲜度)。 */
  evidence: string[];
}

interface ReproSurvey {
  /** 症状是否被真实复现或直接观察(true = 有梯级 4/5 证据)。 */
  reproduced: boolean;
  /** 观察到的事实,每条带证据(file:line / 日志行 / 命令+输出)。 */
  facts: string[];
  /** ≤3 个候选根因假设,各一句理由。 */
  hypotheses: { hypothesis: string; rationale: string }[];
  /** 复现/观察过程摘要:跑过什么、看到什么。 */
  evidence: string[];
}

interface ProbeResult {
  /** 本假设的判定:证实 / 证伪 / 无法判定。 */
  verdict: "confirmed" | "refuted" | "inconclusive";
  /** 证据链,每条注明梯级(1 自述…4 真跑过…5 运行中复现)。 */
  evidence: string[];
  /** 一句话结论。 */
  summary: string;
}

interface DiagnosisAudit {
  /** 根因结论是否站得住(无 2 级结论被当 4 级用、替代假设已穷尽)。 */
  sound: boolean;
  /** 修复是否机械(小、局部、无产品取舍)。 */
  mechanicalFix: boolean;
  /** 缺口与保留意见。 */
  gaps: string[];
  /** 建议动作。 */
  recommendation: "proceed" | "needs-user" | "not-a-bug" | "no-fix";
}

interface GateDecision {
  /** continue = 建环并进开发段;abort = 只交诊断报告,不修。 */
  action: "continue" | "abort";
  /** 运行方补充:如用户确认的推断根因、指定修法、或中止理由。 */
  note?: string;
}

interface Scaffold {
  /** 分支名(不含 feature/ 前缀)。 */
  branch: string;
  /** worktree 路径(仓库相对,如 .worktree/xxx)。 */
  worktree: string;
  /** plan 文档路径(仓库相对)。 */
  planPath: string;
  /** 交给实现者的任务描述(含根因与范围约束)。 */
  task: string;
}

// 分工铁律:脑暴与方案由主对话完成,环境由主对话备好;实现者只实现,
// 流程(评审、修复回流、收尾)由本脚本机械化——任何一侧都不做结构性判断。
// bug 入口是这条铁律的例外声明:根因未知时,诊断段先把未知变已知(只读),
// 拍板闸把「推断根因须用户确认」机械化,建环段产出与 feature 入口等价的四参。
const IMPLEMENTER_PERSONA =
  "你是 NemoNotch 仓库的实现者:环境与方案已由主对话备好,你只管实现,不管流程。" +
  "只在工作目录所在的给定 worktree 里改文件,绝不动主检出的任何文件;" +
  "先完整读取给定的 plan 文档,再按 superpowers executing-plans 纪律逐任务实现:" +
  "一次只做一个任务、做完即验证并单独提交(提交信息引用任务号)," +
  "必要处可参考 .zcode/skills/executing-plans/SKILL.md 的细则;" +
  "发现 plan 有错、有缺口或与仓库现实冲突时,升级说明并停下," +
  "不自行改设计、不扩范围、不顺手重构;" +
  "不建/不删 worktree 与分支,不运行 git feat-done,不 push;" +
  "全部任务完成后的判据是仓库固定脚本:sh scripts/lint.sh --staged --fix 并重新暂存," +
  "plan 涉及 Swift 变更时跑影响面测试 sh scripts/affected-tests.sh——测试类由它确定性选出," +
  "你不挑类名(手挑 --only 出过假绿);它映射为空会自动回落全量," +
  "报告只引用脚本真实退出码,绝不凭记忆复述;" +
  "plan 要求同步 README/AGENTS 文档时按 plan 办,plan 没提就不动。";

const REVIEWER_PERSONA =
  "你是 NemoNotch 仓库的独立评审员,未参与开发(judge ≠ author)。按仓库 sh scripts/review.sh " +
  "生成的清单评审:证据纪律(每个结论指到 file:line)、判别剃刀(测试有没有鉴别力)、" +
  "Swift 6 并发与隔离、最小改动、错误路径、AGENTS.md 坑总目录对照;" +
  "另核一层:实现是否忠实于给定 plan 文档(先完整读取;越出 plan 的改动算发现," +
  "除非明显必要且提交信息说明了理由;逐任务提交是否如 plan 所列)。" +
  "验证必须亲跑(lint/针对性测试/必要处变异),引用真实退出码;不得只信实现者的自述。" +
  "把 Findings(按 P1/P2/P3)与 Verdict 写入 worktree 的 .reviews/<分支>.md " +
  "(首轮先跑 sh scripts/review.sh <branch> 生成模板;后续轮次在既有记录上按轮次追加,**绝不重跑 review.sh 覆盖**——中间轮 findings 是证据链),并在记录里写明 Reviewed-Head: 行(评审时 git rev-parse --short HEAD 的输出,feat-done 门禁逐字核对)" +
  "(feat-done 前核对分支未 rebase——head 变了本 Verdict 不再描述补丁);" +
  "除该文件外不得修改任何文件,不得提交。" +
  "批准需要证据,反对要给出可复现的理由;无法验证就明说,不猜。";

const CHALLENGER_PERSONA =
  "你是 NemoNotch 仓库的挑战者,未参与开发,对抗立场,不带清单,专职攻击(pstack interrogate 思想)。四个镜头:" +
  "①并发与时序:观察追踪、主线程阻塞、HookServer 的持有/超时/连接生命周期、窗口重建," +
  "专找竞态、状态机漏洞与重建即误判类坑;" +
  "②错误路径与协议边界:坏输入、超时、授权缺失、CLI 版本差异下的行为,静默失败优先揪;" +
  "③注释审判(comment-sicko):白名单(法律头/外部依赖强加的坑/公共 API 契约文档/规则本身有毛病的 lint 抑制)" +
  "之外的注释全杀;注释里声称的约束标 MUST KILL——要求改成命名/类型/结构让它不言自明;只标记,不改码;" +
  "④影响面(blast-radius):对不信任的小 diff 用 ripwire(--callers/--impact)跑真代码证明影响面," +
  "不接受纯文字分析。" +
  "每个结论指到 file:line 或命令+真实退出码;无法验证就明说,不猜。" +
  "你不写 .reviews、不改任何文件、不提交,只把发现(P1/P2/P3 + MUST KILL 清单)交给调用方汇总。" +
  "对手越强留下的代码越硬,但反对必须有可复现证据,不为反对而反对。" +
  "校准:没有 P1/P2 级发现就给 APPROVED——REJECTED 必须伴随至少一条可行动的 P1/P2。";

const DETECTIVE_PERSONA =
  "你是 NemoNotch 的复现侦探,只读诊断。仓库文件一律不改,探针脚本/产物只写 /tmp;" +
  "证据源优先级:~/.NemoNotch/logs 真实日志(注意时间戳是本地时)、rtk grep/rg、ripwire(调用关系)," +
  "必要时真机观察(运行中的 app、screencapture、ps/lsof)。" +
  "任务:①竭尽全力复现或直接观察到症状(期望 vs 实际的差);②如实记录观察到的事实," +
  "每条带证据(file:line / 日志行 / 命令+真实输出);③提出不超过 3 个最可能的根因假设,各配一句理由。" +
  "观测不成律:复现不了就如实说复现不了,绝不脑补因果;你产出的事实清单是后续探针的唯一输入。" +
  "无法验证就明说,不猜。";

const PROBE_PERSONA =
  "你是假设探针:拿到一个根因假设,设计最小的单变量实验去证实或证伪它。" +
  "只读纪律:仓库文件不改,探针脚本/产物只写 /tmp;可用日志、rtk grep、ripwire、构建产物," +
  "必要时只读地观察运行中的 app。一次只动一个变量;证伪与证实同样有价值;" +
  "每条证据注明梯级(1 自述 / 2 file:line / 3 走失败路径 / 4 真跑过 / 5 运行中复现);" +
  "无法判定就如实 inconclusive,不猜。";

const DIAG_AUDIT_PERSONA =
  "你是诊断挑战者,未参与任何侦察与探针,只凭交给你的证据链审一件事:根因结论站不站得住。" +
  "检查:①有没有 2 级结论被当成 4 级用(读代码推出来的不等于跑过的);" +
  "②替代假设是否穷尽——还有没有更简单的解释没被排除;" +
  "③证据与结论的因果对应是否成立。" +
  "另判断修法是否机械(小、局部、无产品取舍——涉及取舍就交给用户)。" +
  "宁严勿松,但不为反对而反对;给出建议动作。";

const SCAFFOLD_PERSONA =
  "你是建环者:把已拍板的根因转成 feature 入口等价的环境与 plan。" +
  "①在主检出跑 git feat <分支名>(分支名按根因 kebab 命名,fix- 前缀;命令幂等,已在则复用);" +
  "②在新 worktree 里写 plan 文档落 docs/superpowers/plans/YYYY-MM-DD-<分支名>.md 并提交到分支" +
  "(提交信息 docs(plan): …)。plan 必含:症状与期望 vs 实际、根因报告(证据链逐条带梯级;" +
  "若诊断未能复现,plan 首部必须写明『根因系代码审阅推断,已经用户确认』)、任务清单" +
  "(首任务=落失败测试,引用真实失败输出,red→green 可重放;后续任务按最小修复排)、" +
  "验证命令(sh scripts/affected-tests.sh,不手挑类名)、范围纪律。" +
  "不改任何代码、不跑 feat-done、不 push。" +
  "返回 branch(不含 feature/ 前缀)、worktree(仓库相对路径)、planPath(仓库相对)、" +
  "task(给实现者的一段任务描述:根因+修复范围+约束)。";

const symptom = typeof args.symptom === "string" ? args.symptom : "";
let task = typeof args.task === "string" ? args.task : "";
let worktree = typeof args.worktree === "string" ? args.worktree : "";
let branch = typeof args.branch === "string" ? args.branch : "";
let planPath = typeof args.planPath === "string" ? args.planPath : "";

if (!symptom && (!task || !worktree || !branch || !planPath)) {
  return {
    conclusion:
      "入口缺参:feature 入口需要 task/worktree/branch/planPath 四参,bug 入口需要 symptom 一参。什么都没跑。",
    findings: [],
    verified: [],
    notCovered: ["未启动任何阶段——参数校验即返回"],
  };
}

// bug 入口:诊断段只读把「根因未知」变成「根因已知」,拍板闸机械化
// 「推断根因须用户确认」,建环段产出与 feature 入口等价的四参后合流下方开发段。
let bugDiagnosis = "";
if (symptom) {
  phase("复现优先:真机观察与假设盘点");
  const survey = await agent("复现侦探", { system: DETECTIVE_PERSONA }).ask<ReproSurvey>(
    `症状(期望 vs 实际):${symptom}\n\n` +
      "先读 AGENTS.md 的坑总目录排已知坑,再按你的纪律复现与盘点。"
  );
  report(survey);
  log(
    `复现:${survey.reproduced ? "确凿" : "未能复现(根因将标推断)"};` +
      `事实 ${survey.facts.length} 条;假设 ${survey.hypotheses.length} 个`
  );

  phase("并行假设探针(单变量,证据标梯级)");
  const hypotheses = survey.hypotheses.slice(0, 3);
  const probes = await Promise.all(
    hypotheses.map((h, i) =>
      agent(`探针-${i + 1}`, { system: PROBE_PERSONA }).ask<ProbeResult>(
        `假设:${h.hypothesis}(理由:${h.rationale})\n\n` +
          `已知事实(侦察产出,可直接引用):${JSON.stringify(survey.facts)}\n` +
          `症状:${symptom}`
      )
    )
  );
  probes.forEach((p) => report(p));
  const confirmed = probes.find((p) => p.verdict === "confirmed");

  phase("证据链挑战与根因拍板(单席,只审梯级与穷尽性)");
  const audit = await agent("诊断挑战者", { system: DIAG_AUDIT_PERSONA }).ask<DiagnosisAudit>(
    `症状:${symptom}\n复现:${survey.reproduced ? "确凿" : "未复现"}\n` +
      `侦察事实:${JSON.stringify(survey.facts)}\n` +
      `探针结果:${JSON.stringify(probes)}\n` +
      "(你看不到侦察与探针的原始上下文,只凭以上证据审——这正是你的价值。)"
  );
  report(audit);

  // 免闸五合取:挑战者的建议动作必须被消费——sound+机械+复现+确认探针俱全
  // 但建议 not-a-bug / no-fix / needs-user 时,否决表态不能被静默丢弃。
  const autoProceed =
    audit.sound &&
    survey.reproduced &&
    audit.mechanicalFix &&
    audit.recommendation === "proceed" &&
    confirmed !== undefined;
  let proceed = autoProceed;
  let gateNote = "";
  if (!autoProceed) {
    const gate = await hole<GateDecision>(
      "根因拍板闸",
      `症状:${symptom}\n` +
        `复现:${survey.reproduced ? "确凿" : "未复现——根因系代码审阅推断,按 AGENTS 须用户确认才能修"}\n` +
        `确认的探针:${confirmed ? confirmed.summary : "无(全部证伪或无法判定)"}\n` +
        `挑战者审计:${JSON.stringify(audit)}\n` +
        `全部探针:${JSON.stringify(probes)}\n\n` +
        `继续(action:"continue",可带 note:用户确认的根因/指定修法)= 建环并进开发段;` +
        `中止(action:"abort")= 只交诊断报告。请与用户确认后填 GateDecision。`
    );
    proceed = gate.action === "continue";
    gateNote = typeof gate.note === "string" ? gate.note : "";
    log(`根因拍板闸:${gate.action}${gateNote ? `(note: ${gateNote})` : ""}`);
  }

  if (!proceed) {
    return {
      conclusion:
        `bug「${symptom}」在根因拍板闸中止,未修复。诊断结论:` +
        `${confirmed ? confirmed.summary : "无确认根因(探针:" + probes.map((p) => p.verdict).join("/") + ")"}` +
        `;挑战者:${audit.recommendation}(${audit.gaps.join(";") || "无保留意见"})。` +
        "诊断 findings 已随本报告交付;若用户后续确认根因,重跑本工作流从诊断段重新开始(无跨 run 记忆)。",
      findings: probes.map((p) => ({
        where: "诊断",
        what: `${p.summary}`,
        evidence: p.evidence.join(";"),
        status: p.verdict === "confirmed" ? ("verified" as const) : ("unconfirmed" as const),
        severity: "medium" as const,
      })),
      verified: survey.evidence,
      notCovered: ["修复未进行(拍板闸中止)", "全量测试与 feat-done 门禁未跑(无代码改动)"],
    };
  }

  phase("建 worktree 与 plan(首任务=失败测试)");
  const scaffold = await agent("建环者", { system: SCAFFOLD_PERSONA }).ask<Scaffold>(
    `症状:${symptom}\n` +
      `根因(探针确认):${confirmed ? confirmed.summary : "无确认探针——按拍板闸 note 的根因走"}\n` +
      `证据链:${JSON.stringify(confirmed ? confirmed.evidence : probes.map((p) => p.summary))}\n` +
      `挑战者审计:${JSON.stringify(audit)}\n` +
      `拍板闸补充:${gateNote || (autoProceed ? "(免闸直通:复现确凿+证据链成立+修法机械+探针确认+挑战者放行)" : "(拍板闸放行,无补充说明)")}\n` +
      `复现状态:${survey.reproduced ? "真机/日志确凿" : "未复现——plan 首部必须写明根因系推断且已经用户确认"}`
  );
  if (!scaffold.branch || !scaffold.worktree || !scaffold.planPath || !scaffold.task) {
    return {
      conclusion:
        `建环者输出不完整(branch/worktree/planPath/task 有空值),已中止在衔接段——` +
        `诊断结论:${confirmed ? confirmed.summary : "见 findings"}。修复未开始,无代码改动。`,
      findings: probes.map((p) => ({
        where: "诊断",
        what: p.summary,
        evidence: p.evidence.join(";"),
        status: p.verdict === "confirmed" ? ("verified" as const) : ("unconfirmed" as const),
        severity: "medium" as const,
      })),
      verified: survey.evidence,
      notCovered: ["建环失败中止(输出缺参,建环者可重试)", "开发段与评审未进入"],
    };
  }
  task = scaffold.task;
  worktree = scaffold.worktree;
  branch = scaffold.branch;
  planPath = scaffold.planPath;
  bugDiagnosis = `bug 入口(症状→诊断→建环 ${branch});根因:${confirmed ? confirmed.summary : gateNote};`;
  log(`bug 入口衔接:feature/${branch} @ ${worktree},plan:${planPath}`);
}

phase("按 plan 文档逐任务实现(自测并提交)");
const implementer = agent("实现者", { system: IMPLEMENTER_PERSONA });
const impl = await implementer.ask<Implementation>(
  `任务:${task}\n\nworktree(你的工作目录):${worktree}\n分支:feature/${branch}\n\n` +
    `plan 文档(先用文件工具完整读取,再逐任务实现,矛盾处升级):\n${planPath}\n\n` +
    "按 plan 任务清单实现:一任务一验证一提交;全部完成后跑 lint 与 plan 要求的针对性测试。" +
    "返回提交哈希、命令与退出码证据、完成的任务与偏差说明、你没把握的风险点。"
);
log(`实现完成:${impl.commits.length} 个提交`);

let final: Review | undefined;
let previousFindings: Finding[] = [];
for (let round = 1; round <= 3; round += 1) {
  // 双席并行:清单评审与对抗挑战各一双新鲜眼睛,findings 汇总后一起回流修复。
  phase("双席评审与挑战(未参与开发,写 .reviews 记录)");
  const [review, challenge] = await Promise.all([
    agent(`评审员-第${round}轮`, { system: REVIEWER_PERSONA }).ask<Review>(
      `评审 worktree ${worktree} 的分支 feature/${branch}(对照 develop:git diff develop...feature/${branch})。\n` +
        `任务背景:${task}\n` +
        `plan 文档(先完整读取,核验忠实度与任务覆盖):\n${planPath}\n\n` +
        `实现者交接:${impl.summary}\n风险点:${JSON.stringify(impl.risks)}\n` +
        `实现者自跑的证据(你必须抽查复跑):${JSON.stringify(impl.checks)}\n` +
        (symptom
          ? "\nbug 修复专项:核验失败测试确实由红转绿、修复与根因因果对应、无越出根因的顺手改动。\n"
          : "") +
        (round > 1
          ? `这是第 ${round} 轮:重点核验上一轮意见是否修到位,并回归检查。\n上轮意见:\n${JSON.stringify(previousFindings)}`
          : "")
    ),
    agent(`挑战者-第${round}轮`, { system: CHALLENGER_PERSONA }).ask<Review>(
      `攻击 worktree ${worktree} 的分支 feature/${branch}(对照 develop:git diff develop...feature/${branch})。\n` +
        `任务背景:${task}\nplan 文档:\n${planPath}\n\n` +
        `实现者自述(别信,抽查):${impl.summary}\n` +
        (round > 1
          ? `第 ${round} 轮:上一轮的 MUST KILL 与影响面问题修了吗?回归扫一遍。\n上轮意见:\n${JSON.stringify(previousFindings)}`
          : "")
    ),
  ]);
  const merged: Review = {
    verdict:
      review.verdict === "APPROVED" && challenge.verdict === "APPROVED" ? "APPROVED" : "REJECTED",
    findings: [...review.findings, ...challenge.findings],
    evidence: [...review.evidence, ...challenge.evidence],
  };
  final = merged;
  report(merged);
  log(
    `第 ${round} 轮双席:评审员 ${review.verdict}(${review.findings.length} 条)` +
      ` + 挑战者 ${challenge.verdict}(${challenge.findings.length} 条) → ${merged.verdict}`
  );
  const blockingNow = merged.findings.filter((f) => f.severity === "P1" || f.severity === "P2");
  previousFindings = merged.findings;
  // 没有可行动意见就出环:REJECTED 而无 P1/P2 是校准失败,不为它空转一轮;
  // verdict 原样带出,conclusion 如实说明。
  if (blockingNow.length === 0) break;
  if (round === 3) break;

  phase("按评审意见修复并自测");
  await implementer.ask(
    `评审未通过,修复以下全部 P1/P2 意见后自测并提交(P3 自行判断,接受要在提交信息里说明理由;\n` +
      `MUST KILL 标记的注释按建议改为结构表达):\n${JSON.stringify(merged.findings)}\n` +
      "修复保持最小改动、不越出 plan 范围;完成后同样返回退出码证据。"
  );
}

// 循环保证 final 至少赋值一次;这行只是让类型收紧,无运行时作用。
const finalReview: Review = final!;

phase("交付评审记录与报告");
const recordPath = `${worktree}/.reviews/${branch}.md`;
try {
  await artifact.file("review-record", recordPath, {
    title: `评审记录:${branch}`,
    description: `Verdict: ${finalReview.verdict},共 ${finalReview.findings.length} 条意见,随分支留存。`,
  });
} catch {
  log("评审记录文件未能发布(可能未写入),以评审结果字段为准");
}
await artifact.markdown(
  "review-report",
  [
    `# ${branch} 实现与评审`,
    "",
    `${bugDiagnosis ? bugDiagnosis + "\n" : ""}任务:${task}`,
    `分支:feature/${branch}(${impl.commits.join(", ")})`,
    `plan 文档:${planPath}`,
    `双席评审:${finalReview.verdict}(共 ${finalReview.findings.length} 条意见)`,
    "",
    ...finalReview.findings.map((f) => `- **${f.severity}** ${f.where} — ${f.problem}`),
    "",
    `证据:${finalReview.evidence.join(";")}`,
  ].join("\n"),
  { title: "实现与评审报告", description: `${finalReview.verdict}。`, primary: true }
);

const blocking = finalReview.findings.filter((f) => f.severity === "P1" || f.severity === "P2");
return {
  conclusion:
    `${bugDiagnosis}任务「${task}」已在 feature/${branch} 实现并通过 ${finalReview.verdict} 双席评审` +
    (finalReview.verdict === "APPROVED"
      ? blocking.length === 0
        ? ",无未决 P1/P2。"
        : `,但仍有 ${blocking.length} 条 P1/P2 未决(评审轮数已用尽),合并前必须人工处理。`
      : ",评审未批准,不要合并。") +
    " 合并(feat-done 前核对 head 未 rebase)、评审记录与 plan 文档的提交、push 留给主对话执行。",
  findings: finalReview.findings.map((f) => ({
    where: f.where,
    what: f.problem,
    evidence: `${f.suggestion}(单席产出未经第三席复验;双席合计 Verdict: ${finalReview.verdict})`,
    status: "verified" as const,
    severity: f.severity === "P1" ? ("high" as const) : f.severity === "P2" ? ("medium" as const) : ("low" as const),
  })),
  verified: [
    ...(bugDiagnosis ? [`bug 诊断段:${bugDiagnosis}`] : []),
    `实现者自跑:${impl.checks.join(";")}`,
    `评审员复跑抽查:${finalReview.evidence.join(";")}`,
    `评审记录(含 head 短哈希):${recordPath}`,
    `plan 文档:${planPath}`,
  ],
  notCovered: [
    "全量测试套件与 doc-audit 门禁在 feat-done 合并时才跑,本工作流只跑了针对性测试",
    "脑暴、plan 撰写(feature 入口)、worktree 创建(feature 入口)、合并、部署与 push 均在主对话,不在本工作流范围",
  ],
};
