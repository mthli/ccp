# ccp

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

헤드리스 모드 없이 구현한 Claude Code 헤드리스 자동화 👀

## 무엇인가

`ccp`는 `claude -p`처럼 Claude Code를 실행하지만(프롬프트를 넣으면 최종 답변이 stdout으로 나옵니다), **Agent SDK 크레딧 풀이 아니라 구독 요금제로 과금됩니다**.

이는 분리된 [tmux](https://github.com/tmux/tmux) 세션 안에서 실제 *대화형* Claude Code TUI를 구동함으로써 이루어집니다.
Claude를 실행하고, 프롬프트를 입력하고, 권한 프롬프트에 자동으로 응답한 뒤, 최종 답변을 스크레이핑합니다.
당신은 헤드리스의 편의성을 누리고, Claude는 자신이 평범한 대화형 세션이라고 생각합니다.

```text
claude -p     →  헤드리스 모드    →  Agent SDK 크레딧 풀
ccp.sh "..."  →  대화형 TUI       →  구독 풀 ✅
```

## 요구 사항

- [`claude`](https://code.claude.com/docs#get-started) (로그인된 상태)
- [`tmux`](https://github.com/tmux/tmux)
- [`jq`](https://jqlang.github.io/jq/)

## 설치

### Homebrew

```bash
brew install mthli/tap/ccp
```

이 명령은 `tmux`와 `jq`를 자동으로 함께 설치하고, `PATH`에 `ccp` 명령을 추가합니다(아래 예시에서 `./ccp.sh`라고 적힌 곳은 모두 `ccp`로 대체할 수 있습니다).
[`claude`](https://code.claude.com/docs#get-started)는 별도로 설치하고 로그인해 두어야 합니다.

### 소스에서 설치

```bash
git clone https://github.com/mthli/ccp.git
cd ccp
./ccp.sh "say hi"
```

## 사용법

```bash
./ccp.sh "<prompt>"
```

프롬프트를 넣으면 최종 답변이 stdout으로 나옵니다.

```bash
./ccp.sh "summarize README.md"
./ccp.sh "say hi" # 빠른 엔드투엔드 스모크 테스트.
```

### 권한 모드

기본적으로 모든 도구 호출은 자동으로 승인됩니다(`allow`).
`-p`로 도구 호출 처리 방식을 선택합니다.

```bash
./ccp.sh -p allow "refactor utils.py" # 모두 자동 승인(기본값).
./ccp.sh -p deny  "scan the repo"     # 모든 도구 호출 거부.
./ccp.sh -p ask   "edit config"       # TUI의 일반 프롬프트에 맡김.
```

> `allow` 모드에서도 되돌릴 수 없는 일부 Bash 명령(`rm -rf`, `mkfs`, `dd if=`, 포크 폭탄 등)은 항상 강제로 거부됩니다.

### 환경 변수 설정

`-e KEY=VALUE`(반복 지정 가능)는 실행된 세션에 환경 변수를 설정하며, Claude와 그것이 실행하는 모든 hook에 상속됩니다.

```bash
./ccp.sh -e FOO=bar -e DEBUG=1 "print the FOO env var"
```

### tmux 세션 이름 지정

기본적으로 각 실행은 고유한 `cc-<pid>` tmux 세션을 사용합니다. `-s`를 전달하면 세션 이름을 직접 지정할 수 있어, attach(`tmux attach -t <name>`)하거나 여러 개를 나란히 실행할 때 편리합니다.

```bash
./ccp.sh -s review "review the diff"
```

> 세션 이름에는 `.`이나 `:`를 포함할 수 없으며, 기존 세션과 같은 이름일 수도 없습니다(ccp는 자신이 만들지 않은 세션을 재사용하거나 종료하지 않습니다).

### claude에 옵션 전달하기

`--` 뒤의 모든 것은 그대로 하위의 `claude`로 전달되므로, claude 자체의 플래그가 그대로 동작합니다.

```bash
./ccp.sh "review the diff" -- --model opus --add-dir /tmp
./ccp.sh "audit deps"      -- --settings ./my-settings.json --mcp-config ./mcp.json
```

> `--settings`는 ccp 자체 settings에 깊은 병합(deep-merge)됩니다. claude의 `-p`/`--print`는 ccp가 바로 그 헤드리스 모드를 대체하는 것이므로 무시됩니다.

### 환경 변수 오버라이드

| 변수                 | 기본값 | 의미                                              |
| -------------------- | ------ | ------------------------------------------------- |
| `CCP_READY_TIMEOUT`  | `60`   | 입력창이 나타날 때까지 기다리는 초.               |
| `CCP_ANSWER_TIMEOUT` | `0`    | 답변을 기다리는 초. `0` = 무한정 대기.            |

전체 옵션 목록은 `./ccp.sh --help`로 확인하세요.

## 작동 방식

`ccp`는 순수 bash이며, 빌드 단계가 없고 위의 세 가지 도구 외에 의존성이 없습니다.

네 개의 파일이 협력합니다.

- **`ccp.sh`** - 오케스트레이터.
  일회용 settings 파일을 작성하고(당신의 실제 `~/.claude/settings.json`은 전혀 건드리지 않습니다),
  분리된 tmux 세션에서 `claude`를 실행하고, 프롬프트를 붙여넣고, 완료를 기다린 뒤 답변을 출력합니다.
- **`hooks/auto-permission.sh`** - 각 권한 프롬프트에 응답하는 `PreToolUse` hook으로,
  TUI가 y/n 확인창에서 멈추지 않게 합니다.
- **`hooks/dump-transcript.sh`** - transcript에서 최종 assistant 답변을 꺼내고
  오케스트레이터에 완료를 알리는 `Stop` hook.
- **`hooks/dump-failure.sh`** - API 오류로 턴이 끝날 때 실행되는 `StopFailure` hook으로,
  ccp가 멈춰 기다리지 않고 종료하게 합니다.

사용량이 소진되어도 ccp는 멈추지 않습니다. API 오류 턴은 `StopFailure` hook을 실행하며(종료 코드 `5`),
구독 사용량 한도 벽(TUI는 이를 표시하지만 턴을 끝내지 않아 어떤 hook도 실행되지 않습니다)은
pane을 스캔해 감지하여 종료 코드 `4`로 종료합니다. tmux 세션과 임시 파일은 종료할 때마다 정리됩니다.

## 라이선스

```text
MIT License

Copyright (c) 2026 Matthew Lee
```
