# homelab-dev-tools

개인 홈랩(homelab) 및 개발 환경에서 사용하는 CLI 도구 모음입니다.
Git 작업 보조, 로컬 LLM 기반 커밋 메시지 생성, 각종 쉘 유틸리티를 포함합니다.

## 주요 특징

- 단일 스크립트로 설치 / 제거 가능합니다.
- Git 커밋 및 PR 작업을 빠르게 도와주는 헬퍼 명령어를 제공합니다.
- 로컬 LLM(llama.cpp 서버)을 이용해 커밋 메시지를 자동 생성합니다.
- macOS / Linux / Windows(Git Bash) 환경을 지원합니다.

## 구성 요소

- bin/ : 사용자가 직접 호출하는 CLI 엔트리포인트입니다.
  - gc  : LLM 기반 커밋 메시지 생성
  - gpr : PR 관련 Git 헬퍼
  - gpm : 기타 Git 유틸
  - llm : 로컬 LLM 서버 관리 (up / down / status)
- git-tools/ : Git 관련 내부 스크립트입니다.
- lib/       : 공통으로 사용하는 쉘 라이브러리입니다.
- llm/       : 로컬 LLM 서버용 Docker Compose 설정입니다.
- prompts/   : LLM 프롬프트 (system / user)입니다.

## 요구 사항 (Dependencies)

필수:

- bash
  - Linux
  - Windows: Git Bash
- macOS는 zsh 환경을 전제로 동작합니다.
  - macOS 기본 쉘(zsh) 기준
  - bash 환경은 공식 지원하지 않습니다.
- tar

기능별 의존성 (수동 설치 필요):

> install.sh는 의존성을 설치하지 않습니다. 아래 도구들은 사용자가 직접 설치해야 합니다.

- jq: JSON 파싱 도구 (gc에서 사용)
- eza: 디렉토리 트리 출력 도구 (tree 대체, 일부 Git 헬퍼에서 사용)
- Docker: 로컬 LLM 기능 (llm up) 사용 시 필요

### OS별 의존성 설치 예시

Windows (Git Bash)

Scoop 설치 (PowerShell):

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
irm get.scoop.sh | iex
```

Git Bash:

```bash
scoop install jq eza
```

macOS (zsh)

```bash
brew install jq eza
```

Linux (예시)

Debian / Ubuntu

```bash
sudo apt install -y jq
```

Fedora

```bash
sudo dnf install -y jq eza
```

Arch

```bash
sudo pacman -S jq eza
```

## 설치

```bash
./install.sh
```

설치 위치:

```
~/.homelab-dev-tools
```

설치 시 아래 구문이 쉘 설정 파일에 추가됩니다.

```bash
[ -f "$HOME/.homelab-dev-tools/lib/env.sh" ] && . "$HOME/.homelab-dev-tools/lib/env.sh"
```

- macOS   : ~/.zshrc
- Linux   : ~/.bashrc 또는 ~/.bash_profile
- Windows : ~/.bashrc (Git Bash)

설치 후 터미널을 다시 열거나 rc 파일을 reload 해야 합니다.

## 제거

```bash
./uninstall.sh
```

아래 항목이 제거됩니다.

- ~/.homelab-dev-tools
- 쉘 rc 파일 내 homelab-dev-tools 관련 source 구문

## 빠른 시작

```bash
which llm
llm up
gc
```

## 레포 구조

```
.
├── bin/
├── git-tools/
├── lib/
├── llm/
├── prompts/
├── .gitignore
├── LICENSE
├── README.md
├── install.sh
├── uninstall.sh
└── VERSION
```

## 보안 주의 (절대 커밋 금지)

다음 파일들은 절대 Git에 커밋하면 안 됩니다.

- llm/.env
- llm/models/*.gguf
- *.pem, *.key, *.pfx, *.keystore
- .env, .env.*

실수로 커밋했다면 즉시 토큰 및 키를 폐기(rotate)해야 합니다.

## 라이선스

LICENSE 파일을 참고합니다.
