/* zcode-workflow
description: NemoNotch 开发执行环(pstack 融入版):主对话脑暴澄清(提问分类器)、writing-plans 写 plan、git
  feat 建环境后启动;实现子代理按 executing-plans
  逐任务实现;评审双席并行——评审员(仓库清单)+挑战者(对抗镜头:并发时序/错误路径/注释审判/ripwire 影响面),findings 合并写入
  .reviews(后续轮追加不覆盖),P1/P2 回流修复(≤3 轮,回流携带上轮意见)。脑暴、规划、环境、合并与 push 留在主对话。
whenToUse: 仅 feature 类任务。主对话已完成:①brainstorming
  脑暴(提问分类器:可实验回答的做探针,只问产品/偏好取舍);②git feat 建 worktree、plan 文档写入
  docs/superpowers/plans/。investigation 只读调查不启动本工作流;bug 类 plan 首任务=落失败测试。以
  task/worktree/branch/planPath 四参启动。
args:
  branch:
    type: string
    description: feature 分支名(不含 feature/ 前缀),主对话已创建
    required: true
  planPath:
    type: string
    description: 主对话按 writing-plans 惯例写好的 plan 文档路径(仓库相对,worktree 内的
      docs/superpowers/plans/ 下,随分支提交)
    required: true
  task:
    type: string
    description: 任务描述,含主对话脑暴澄清后的目标与约束
    required: true
  worktree:
    type: string
    description: 主对话已用 git feat 建好的 worktree 路径(仓库相对,如 .worktree/xxx)
    required: true
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

const task = String(args.task);
const worktree = String(args.worktree);
const branch = String(args.branch);
const planPath = String(args.planPath);

// 分工铁律:脑暴与方案由主对话完成,环境由主对话备好;实现者只实现,
// 流程(评审、修复回流、收尾)由本脚本机械化——任何一侧都不做结构性判断。
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
    `任务:${task}`,
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
    `任务「${task}」已在 feature/${branch} 实现并通过 ${finalReview.verdict} 双席评审` +
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
    `实现者自跑:${impl.checks.join(";")}`,
    `评审员复跑抽查:${finalReview.evidence.join(";")}`,
    `评审记录(含 head 短哈希):${recordPath}`,
    `plan 文档:${planPath}`,
  ],
  notCovered: [
    "全量测试套件与 doc-audit 门禁在 feat-done 合并时才跑,本工作流只跑了针对性测试",
    "脑暴、plan 撰写、worktree 创建、合并、部署与 push 均在主对话,不在本工作流范围",
  ],
};
