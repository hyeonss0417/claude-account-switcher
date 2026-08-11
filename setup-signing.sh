#!/bin/bash
# 안정적인 자체서명 코드서명 인증서를 1회 생성해 로그인 키체인에 넣는다.
#
# 왜 필요한가: ad-hoc 서명(`codesign -s -`)은 **빌드할 때마다 앱의 코드 식별자가 바뀐다.**
# Keychain ACL 은 "이 코드 식별자를 허용" 방식이라, 식별자가 바뀌면 이전에 누른
# "항상 허용"이 무효가 되어 **전환할 때마다 비밀번호 창이 다시 뜬다.**
# 고정 인증서로 서명하면 식별자가 유지되어 "항상 허용"이 계속 유효하다.
set -euo pipefail

CN="ClaudeSwitcher Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "✓ 이미 존재: $CN"
  exit 0
fi

echo "==> 자체서명 코드서명 인증서 생성: $CN"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 코드서명 정책을 통과하려면 keyUsage=digitalSignature 가 반드시 있어야 한다
# (없으면 identity 는 보이지만 "Invalid Key Usage for policy" 로 서명 불가).
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

# macOS 의 PKCS12 임포터는 OpenSSL 3.x 기본(AES/SHA-256 MAC)을 못 읽는다.
# → 레거시 PBE(3DES/SHA-1)로 내보내야 `security import` 가 성공한다.
openssl pkcs12 -export -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout pass:switcher >/dev/null 2>&1

# 개인키를 codesign 이 프롬프트 없이 쓸 수 있도록 -T 로 허용, -A 는 전체 허용
security import "$TMP/id.p12" -k "$KEYCHAIN" -P switcher \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# 코드서명용 신뢰 설정. `-d`(관리자 도메인)는 권한이 필요하므로 **사용자 도메인**으로 넣는다.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 \
  || echo "  (신뢰 설정 건너뜀 — 서명은 대개 그대로 동작)"

# codesign 이 개인키에 접근할 때 프롬프트가 뜨지 않도록 파티션 목록 갱신
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "✓ 생성 완료 — 이제 build.sh 가 이 인증서로 서명합니다."
else
  echo "⚠ 인증서는 만들었지만 codesigning identity 로 인식되지 않았습니다."
  echo "  build.sh 는 ad-hoc 서명으로 계속 동작합니다(전환 시 허용 창이 뜰 수 있음)."
fi
