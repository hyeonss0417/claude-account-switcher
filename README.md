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
- **Automatic session union-sync** — runs on a 30s timer, *and* the moment a session folder changes, *and* when Claude launches or quits. That last one matters: Claude only scans its session folder at launch, so syncing on quit guarantees the next launch sees everything.
- **Timestamped backups** before any change — snapshots the session folder + `~/.claude.json` (keeps the last 10).
- **Real account switching** — snapshots and restores the desktop's **web session** (the `sessionKey` cookies + Local/Session Storage that actually hold your login), plus the CLI identity (`~/.claude.json`) and Keychain credential. Once an account has been captured, switching to it logs you straight in — no manual login.
  - First time only: log into the account once, then hit **"현재 로그인 저장" (Save current login)**. From then on it's one click.
- **Empty-session protection** — a session index whose conversation log is gone (deleted worktree, etc.) is **never propagated**, and by default is **quarantined into backups on every sync**, so accounts keep identical session counts instead of drifting apart. Toggle with "빈 세션 자동 정리".
- **Launch at login** toggle, so sync is always running.
- **Dock icon** (on by default) — click it to pop the menu open at your cursor, for when the menu bar is too crowded to hit the status icon. Turn it off to go menu-bar-only.
- **Stable code signing** (`setup-signing.sh`) — so macOS's Keychain "Always Allow" actually sticks instead of re-prompting on every switch.
- **Un-shadow recycled-worktree sessions** — Claude Code reuses worktree directories, and the desktop list only shows the newest session per worktree, so older ones silently disappear from the list even though their logs are intact. "가려진 세션 복구" copies those logs back under the main repo and re-lists them as "… (복구)", leaving the originals untouched.
- **Headless modes** for debugging: `--diagnose`, `--sync`, `--find-shadowed`, `--unshadow`, `--clean-dead`.

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
bash setup-signing.sh  # once: stable self-signed cert so "Always Allow" persists
bash build.sh          # release build → ~/Applications/Claude Account Switcher.app
open ~/Applications/"Claude Account Switcher.app"
```

- On the first switch/capture, macOS shows a Keychain **"Always Allow"** prompt — click it once (with `setup-signing.sh` done, it won't come back).
- Switching **quits and relaunches Claude** (required to safely swap the web session), so save your work first.
- Enable **"Launch at login"** from the menu so sync runs whenever you're working.

## Usage

Open the menu-bar icon (two people in a circle) — or click the Dock icon, which pops the same menu up at your cursor:

```
Claude Account Switcher
──────────────────────────
● work@example.com — 506 sessions      ← active
○ personal@example.com — 506 sessions
──────────────────────────
Sync sessions now                (⌘S)
Auto-sync (30s)                   ✓
Launch at login                   ✓
Show Dock icon                    ✓
Auto-clean empty sessions         ✓
──────────────────────────
Save current login
Clean up empty sessions
Recover hidden sessions
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
.build/release/ClaudeSwitcher --clean-dead # quarantine indexes whose log is gone
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

- **Claude restarts on every switch.** Swapping the web session requires the app to be fully quit, so the switcher quits and relaunches it. Any Claude Code session running inside the desktop app will be interrupted.
- **One manual login per account, once.** Until an account's web session has been captured, switching to it can only get you to the login screen.
- **Run `setup-signing.sh`.** Without it the app is ad-hoc signed, its code identity changes on every rebuild, and macOS re-prompts for Keychain access on every switch.

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
- **세션 합집합 자동 동기화** — 30초 주기 + **폴더 변화 즉시** + **Claude 실행/종료 시점**. 특히 Claude 는 **시작할 때만** 세션 폴더를 스캔하므로, 종료 시 동기화해 두는 것이 다음 실행에서 전부 보이게 하는 핵심이다.
- **전환 전 자동 백업** — 세션 폴더 + `~/.claude.json` 타임스탬프 스냅샷(최근 10개 보관).
- **진짜 계정 전환** — 데스크탑 로그인의 실체인 **웹세션**(`sessionKey` 쿠키 + Local/Session Storage)을 계정별로 스냅샷·복원하고, CLI 식별(`~/.claude.json`)과 Keychain 자격증명도 함께 교체한다. 한 번 저장된 계정은 클릭 한 번으로 **바로 로그인된 상태**로 전환된다.
  - 최초 1회만: 그 계정으로 로그인한 뒤 메뉴의 **「현재 로그인 저장」** 을 누르면 끝.
- **빈 세션 방지 + 세션 수 일치** — 대화 로그가 사라진 인덱스는 **복사하지 않고**, 기본값으로 **동기화마다 백업 폴더로 자동 격리**한다. 그래서 계정 간 세션 수가 벌어지지 않는다(끄려면 「빈 세션 자동 정리」). 수동 정리는 「빈 세션 정리」.
- **로그인 시 자동 실행** 토글 — 동기화가 항상 돌게.
- **Dock 아이콘**(기본 켜짐) — 메뉴바가 꽉 차 상태 아이콘을 누르기 어려울 때, Dock 아이콘을 클릭하면 **마우스 위치에 메뉴가 바로 뜬다.** 끄면 메뉴바 전용으로 동작.
- **고정 코드서명**(`setup-signing.sh`) — Keychain "항상 허용"이 재빌드 후에도 유지되어 전환할 때마다 암호를 묻지 않는다.
- **가려진 세션 복구** — Claude Code 는 worktree 디렉터리를 재활용하는데, 데스크탑 목록은 **worktree 당 최신 세션 하나만** 보여준다. 그래서 로그가 멀쩡한데도 예전 세션이 목록에서 조용히 사라진다(동기화 문제가 아니다). 「가려진 세션 복구」가 그 로그를 본체 저장소 폴더로 복사해 「… (복구)」 항목으로 다시 띄운다. 원본은 그대로 둔다.
- **헤드리스 디버그 모드**: `--diagnose`, `--sync`, `--find-shadowed`, `--unshadow`, `--clean-dead`.

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
bash setup-signing.sh  # 최초 1회: 고정 자체서명 인증서 ("항상 허용"이 유지되도록)
bash build.sh          # 릴리스 빌드 → ~/Applications/Claude Account Switcher.app
open ~/Applications/"Claude Account Switcher.app"
```

- 첫 전환/저장 때 Keychain **"항상 허용"** 창이 한 번 뜬다 → 한 번만 눌러주면 (setup-signing.sh 를 했다면) 다시 뜨지 않는다.
- 전환하면 **Claude 가 종료됐다 다시 켜진다**(웹세션을 안전하게 교체하려면 필수) — 작업 저장 후 진행할 것.
- 메뉴에서 **"로그인 시 자동 실행"** 을 켜면 동기화가 상시 동작한다.

### 사용

메뉴바 아이콘(원 안의 두 사람)을 열거나, **Dock 아이콘을 클릭**하면(마우스 위치에 같은 메뉴가 뜬다):

```
Claude 계정 전환기
──────────────────────────
● work@example.com — 506 세션           ← 활성
○ personal@example.com — 506 세션
──────────────────────────
지금 세션 동기화                  (⌘S)
자동 동기화 (30초)                ✓
로그인 시 자동 실행               ✓
Dock 아이콘 표시                  ✓
빈 세션 자동 정리                 ✓
──────────────────────────
현재 로그인 저장
빈 세션 정리
가려진 세션 복구
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
.build/release/ClaudeSwitcher --clean-dead # 로그 없는 인덱스 격리
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

- **전환할 때마다 Claude 가 재시작된다.** 웹세션 교체는 앱이 완전히 종료된 상태에서만 안전하므로 종료→복원→재기동한다. 데스크탑 앱 안에서 돌던 Claude Code 세션은 중단된다.
- **계정당 최초 1회 수동 로그인 필요.** 그 계정의 웹세션이 저장되기 전까지는 전환해도 로그인 화면까지만 간다.
- **`setup-signing.sh` 를 꼭 실행.** 안 하면 ad-hoc 서명이라 재빌드마다 코드 신원이 바뀌어 전환 때마다 Keychain 창이 다시 뜬다.

### 라이선스

[MIT](LICENSE)
