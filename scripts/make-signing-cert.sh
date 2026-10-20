#!/bin/sh
# 生成本地部署签名用自签证书,导入登录钥匙串(build.sh 的签名身份)。
# 为什么自签、为什么 CI 刻意保持 ad-hoc:见 AGENTS.md
# 「Build & Release → Local-deploy signing」。
# 使用场景:首次启用;证书丢失/过期/换开发机后重建。
# 同名身份已存在时拒绝 — 先删旧的再重建(删除后 TCC/Keychain 授权会按新
# 身份重新授予一次,这是身份切换的一次性成本,预期内)。
#
# Usage: sh scripts/make-signing-cert.sh
set -u

IDENTITY="NemoNotch Local Code Signing"
DAYS=3650   # 10 年:过期 = 锚定其上的全部授权集体孤儿化,宁长勿短
# security login-keychain 的输出带前导空格和引号(实测:"    \"<path>\""),两者都剥掉
KEYCHAIN=$(security login-keychain | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# 用 codesign 本身探身份是否可用(真源判据):find-identity -p codesigning
# 对没有信任设置的自签证书不显示(实测 2026-10-20),拿它当存在性检查会
# 漏判 → 重复导入同名身份 → codesign 二义报错。
identity_usable() {
  p=$(mktemp) && printf 'probe' > "$p"
  codesign -f -s "$IDENTITY" "$p" >/dev/null 2>&1
  rc=$?
  rm -f "$p"
  return $rc
}

if identity_usable; then
  echo "✋ 身份 '$IDENTITY' 已可用 — 不重复生成。" >&2
  echo "   确要重建:先在钥匙串访问里删除该证书,再跑本脚本。" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM

# 自签 leaf:codeSigning EKU + digitalSignature。不需要加进系统信任设置 —
# codesign 用证书签名不要求证书被信任;信任链只在别人验证时被评估,而
# Gatekeeper 对分发包的验证本来就要求公证,自签过不了(与 ad-hoc 等价)。
cat > "$workdir/codesign.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_cs
prompt = no
[dn]
CN = NemoNotch Local Code Signing
O = NemoNotch
[v3_cs]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成密钥 + 自签证书(RSA 3072,${DAYS} 天)..."
openssl req -x509 -newkey rsa:3072 -nodes \
  -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
  -days "$DAYS" -config "$workdir/codesign.cnf"

# 导入走「私钥 PEM + 证书 PEM 分开导入」:钥匙串按公钥自动配对成身份。
# 不打包 p12 —— 实测(2026-10-20)PATH 里的 Homebrew OpenSSL 4 产出的
# p12 默认加密格式,macOS 的 security import 报「MAC verification failed」;
# 分开导入与 openssl 版本无关。
echo "==> 导入私钥与证书到登录钥匙串(允许 /usr/bin/codesign 直接使用私钥)..."
security import "$workdir/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$workdir/cert.pem" -k "$KEYCHAIN"

echo "==> 验证(codesign 实签一个探针目标)..."
if identity_usable; then
  p=$(mktemp) && printf 'probe' > "$p"
  codesign -f -s "$IDENTITY" "$p" 2>/dev/null
  codesign -dv "$p" 2>&1 | grep -i '^Authority' || true
  rm -f "$p"
  echo "✅ 身份已就绪: $IDENTITY(有效期 ${DAYS} 天,活在登录钥匙串)"
  echo ""
  echo "   备份建议(私钥丢了 = 全部授权重新授予):"
  echo "     security export -k '$KEYCHAIN' -t identities -p '$IDENTITY' -o ~/NemoNotch-signing-backup.p12"
  echo "   说明:find-identity -p codesigning 不显示本证书属预期(自签未设信任;"
  echo "   如需它出现在 Xcode 签名身份列表,可在钥匙串访问里把该证书的"
  echo "   Code Signing 信任设为「始终信任」— 本地部署链路不依赖这一点)。"
  echo "   下一步: ./build.sh 用它签名部署;第一次替换 ad-hoc 版本后,"
  echo "   TCC/Keychain 会按新身份重新授予一次(预期内的一次性成本)。"
else
  echo "❌ codesign 解析不到身份 — 检查上方 security import 的报错" >&2
  exit 1
fi
