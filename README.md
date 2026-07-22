# Claude Account Switcher

A tiny macOS **menu-bar app** for people who juggle multiple Claude accounts (e.g. rotating between accounts as credits/limits reset) and want to **keep the exact same sessions and context no matter which account they're on.**

> **English** · [한국어](#한국어)

---

## The problem it solves

Claude Desktop stores its Claude Code **session list in per-account folders**:

```
~/Library/Application Support/Claude/claude-code-sessions/<accountUUID>/<orgUUID>/local_*.json
```

When you switch to another account, its folder is empty — so **all your sessions look like they vanished.** They didn't: the actual conversation logs live in `~/.claude/projects/*.jsonl` and are **shared across every account**. Those `local_*.json` files are just per-account *indexes* pointing at them, and they contain **no account identifier** — so they're safe to copy between account folders.

**This app keeps every account's session index in union-sync**, so whichever account you log into, your full session list is always there.

## Features

- **Menu-bar status** — each account with its live session count and which one is active.
- **Automatic session union-sync** (every 30s) — the "disappearing sessions" bug never bites again.
- **Timestamped backups** before any change — snapshots the session folder + `~/.claude.json` (keeps the last 10).
- **Account switching**:
  - *Auto* — swaps the saved OAuth credential (Keychain) + `~/.claude.json`, instantly switching the **CLI (`claude` in Terminal)** account.
  - *Guided fallback* — the desktop app manages its account via its own web login, so the tool backs up, syncs, relaunches Claude, and you pick the account once in the app. After that, that account is captured for one-click switching too.
- **Launch at login** toggle, so sync is always running.
- **Headless modes** for debugging: `--diagnose`, `--sync`.

## How it works

| Data | Per-account? | Location |
|---|---|---|
| Conversation logs | ❌ shared | `~/.claude/projects/*/*.jsonl` |
| Memory | ❌ shared (per project) | `~/.claude/projects/<project>/memory/` |
| **Session index** | ✅ per-account | `claude-code-sessions/<account>/<org>/local_*.json` |
| CLI credential | ✅ one active | Keychain `Claude Code-credentials` |
| CLI identity | ✅ one active | `~/.claude.json` → `oauthAccount` |
| Desktop login | ✅ (web session) | `~/Library/Application Support/Claude/` (Cookies, etc.) |

Because logs and memory are already shared, the **only** thing needed for context continuity across a switch is keeping the session index in union-sync. That's the heart of this app.

## Requirements

- macOS 13 (Ventura) or later
- Xcode / Swift 6 toolchain (for building)

## Install

```bash
git clone https://github.com/hyeonss0417/claude-account-switcher.git
cd claude-account-switcher
bash build.sh          # release build → ~/Applications/Claude Account Switcher.app
open ~/Applications/"Claude Account Switcher.app"
```

- On the first switch/capture, macOS shows a Keychain **"Always Allow"** prompt once — allow it.
- Enable **"Launch at login"** from the menu so sync runs whenever you're working.

## Usage

Open the menu-bar icon (two people in a circle):

```
Claude Account Switcher
──────────────────────────
● work@example.com — 506 sessions      ← active
○ personal@example.com — 506 sessions
──────────────────────────
Sync sessions now                (⌘S)
Auto-sync (30s)                   ✓
Launch at login                   ✓
──────────────────────────
Capture current account
Open backups folder
Open log
──────────────────────────
Quit                             (⌘Q)
```

Click an account to switch to it (you'll get a confirm dialog; it backs up + syncs first, then relaunches Claude).

### Headless / debug

```bash
.build/release/ClaudeSwitcher --diagnose   # print accounts, active, session counts (read-only)
.build/release/ClaudeSwitcher --sync       # run one union-sync pass
```

## Data & backup locations

- Profiles: `~/.claude-account-switcher/profiles.json` — **no tokens stored here** (credentials stay in the macOS Keychain)
- Backups: `~/.claude-account-switcher/backups/`
- Log: `~/.claude-account-switcher/switcher.log`

## Safety & privacy

- Session sync is **union-only** (copies missing files), with atomic writes, JSON validation, and a 3-second quiet period to avoid files being actively written.
- Every account switch **backs up first**.
- Credential blobs are never written to disk — they live only in the macOS Keychain.
- The app reads only local Claude state on your machine; it makes no network calls.

## Caveats

- **CLI vs Desktop:** the auto-switch reliably flips the **CLI** account. The **desktop app** decides its account from its own web login, so a desktop switch relaunches Claude and you select the account in its UI once. (No fragile cookie surgery — by design.)
- **Ad-hoc signing:** `build.sh` signs the app ad-hoc, so after each rebuild the Keychain "Allow" prompt appears once more. Fine for a personal build; sign with a Developer ID if you want it to persist.

## License

[MIT](LICENSE)

---

## 한국어

여러 Claude 계정을 오가며(예: 크레딧/한도가 리셋될 때마다 계정 교체) **어느 계정에 있든 똑같은 세션과 컨텍스트로 작업을 이어가고 싶은 사람**을 위한 작은 macOS **메뉴바 앱**.

### 무엇을 해결하나

Claude 데스크탑은 Claude Code **세션 목록을 계정별 폴더**에 저장한다:

```
~/Library/Application Support/Claude/claude-code-sessions/<계정UUID>/<조직UUID>/local_*.json
```

다른 계정으로 바꾸면 그 폴더가 비어 있어 **세션이 전부 사라진 것처럼** 보인다. 실제로는 사라진 게 아니다 — 대화 로그는 `~/.claude/projects/*.jsonl` 에 **모든 계정 공유**로 저장되고, 위 `local_*.json` 은 그걸 가리키는 계정별 *인덱스*일 뿐이다. 인덱스에는 **계정 식별자가 없어** 폴더 간 복사가 안전하다.

**이 앱은 모든 계정의 세션 인덱스를 합집합으로 동기화**해서, 어느 계정으로 로그인하든 전체 세션 목록이 항상 보이게 한다.

### 기능

- **메뉴바 상태** — 계정별 세션 수 + 현재 활성 계정 표시.
- **세션 합집합 자동 동기화** (30초 주기) — 세션이 다시는 "사라지지" 않는다.
- **전환 전 자동 백업** — 세션 폴더 + `~/.claude.json` 타임스탬프 스냅샷(최근 10개 보관).
- **계정 전환**:
  - *자동* — 저장된 OAuth 자격증명(Keychain) + `~/.claude.json` 을 교체해 **터미널 `claude`(CLI)** 계정을 즉시 전환.
  - *가이드 폴백* — 데스크탑 앱은 자체 웹 로그인으로 계정을 관리하므로, 백업·동기화·재기동 후 앱에서 해당 계정을 한 번 고르면 된다. 이후엔 그 계정도 원클릭 전환된다.
- **로그인 시 자동 실행** 토글 — 동기화가 항상 돌게.
- **헤드리스 디버그 모드**: `--diagnose`, `--sync`.

### 동작 원리

| 데이터 | 계정별? | 위치 |
|---|---|---|
| 대화 로그 | ❌ 공유 | `~/.claude/projects/*/*.jsonl` |
| 메모리 | ❌ 공유(프로젝트별) | `~/.claude/projects/<project>/memory/` |
| **세션 인덱스** | ✅ 계정별 | `claude-code-sessions/<계정>/<조직>/local_*.json` |
| CLI 자격증명 | ✅ 활성 1개 | Keychain `Claude Code-credentials` |
| CLI 식별 정보 | ✅ 활성 1개 | `~/.claude.json` → `oauthAccount` |
| 데스크탑 로그인 | ✅ (웹 세션) | `~/Library/Application Support/Claude/` (Cookies 등) |

로그와 메모리는 이미 공유되므로, 전환 시 컨텍스트 유지에 필요한 건 **세션 인덱스 합집합 동기화**뿐이다. 그게 이 앱의 핵심이다.

### 요구 사항

- macOS 13 (Ventura) 이상
- Xcode / Swift 6 (빌드용)

### 설치

```bash
git clone https://github.com/hyeonss0417/claude-account-switcher.git
cd claude-account-switcher
bash build.sh          # 릴리스 빌드 → ~/Applications/Claude Account Switcher.app
open ~/Applications/"Claude Account Switcher.app"
```

- 첫 전환/포착 때 Keychain **"항상 허용"** 창이 한 번 뜬다 → 허용.
- 메뉴에서 **"로그인 시 자동 실행"** 을 켜면 동기화가 상시 동작한다.

### 사용

메뉴바 아이콘(원 안의 두 사람)을 열면:

```
Claude 계정 전환기
──────────────────────────
● work@example.com — 506 세션           ← 활성
○ personal@example.com — 506 세션
──────────────────────────
지금 세션 동기화                  (⌘S)
자동 동기화 (30초)                ✓
로그인 시 자동 실행               ✓
──────────────────────────
현재 계정 포착
백업 폴더 열기
로그 열기
──────────────────────────
종료                             (⌘Q)
```

계정을 클릭하면 전환한다(확인창 → 백업·동기화 후 Claude 재기동).

#### 헤드리스 / 디버그

```bash
.build/release/ClaudeSwitcher --diagnose   # 계정·활성·세션수 출력 (읽기 전용)
.build/release/ClaudeSwitcher --sync       # 합집합 1회 동기화
```

### 데이터 / 백업 위치

- 프로필: `~/.claude-account-switcher/profiles.json` — **토큰은 저장하지 않음**(자격증명은 macOS Keychain 에 보관)
- 백업: `~/.claude-account-switcher/backups/`
- 로그: `~/.claude-account-switcher/switcher.log`

### 안전 · 프라이버시

- 세션 동기화는 **합집합(누락분만 복사)** + 원자적 쓰기 + JSON 유효성 검사 + 3초 quiet period(쓰는 중 파일 회피).
- 모든 전환은 **먼저 백업**한다.
- 자격증명 원문은 파일에 저장하지 않고 macOS Keychain 에만 둔다.
- 네트워크 호출 없이 로컬 Claude 상태만 읽는다.

### 유의점

- **CLI vs 데스크탑:** 자동 전환은 **CLI** 계정을 확실히 바꾼다. **데스크탑 앱**은 자체 웹 로그인으로 계정을 정하므로, 데스크탑 전환은 Claude 를 재기동한 뒤 앱 UI 에서 한 번 계정을 고르는 방식이다(불안정한 쿠키 조작 없음 — 의도된 설계).
- **애드혹 서명:** `build.sh` 는 애드혹 서명이라, 재빌드마다 Keychain "허용" 창이 한 번씩 다시 뜬다. 개인용으로는 충분하며, 영구화하려면 Developer ID 로 서명.

### 라이선스

[MIT](LICENSE)
