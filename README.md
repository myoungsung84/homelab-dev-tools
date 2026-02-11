# homelab-dev-tools

Personal CLI toolkit for homelab workflows.
Git helpers, a local LLM commit assistant, and shell utilities.

## Highlights

- One-line install/uninstall
- Git helpers for commits and PR workflow
- Local LLM helper for commit messages

## Contents

- bin/ : user-facing CLI entrypoints
  - gc  : generate commit message (LLM)
  - gpr : PR helper
  - gpm : misc git helper
  - llm : manage local llama.cpp server (up/down/status)
- git-tools/ : git-related scripts
- lib/       : shared shell libraries
- llm/       : docker compose for local LLM server
- prompts/   : LLM prompts (system/user)

## Requirements

- bash (Git Bash on Windows, or Linux/macOS)
- tar
- Docker (optional, for LLM)

## Install

```bash
./install.sh
```

Installs to `~/.homelab-dev-tools` and appends the following line to your shell rc file:

```bash
[ -f "$HOME/.homelab-dev-tools/lib/env.sh" ] && . "$HOME/.homelab-dev-tools/lib/env.sh"
```

Restart your terminal or reload your rc file to apply.

## Uninstall

```bash
./uninstall.sh
```

Removes:
- ~/.homelab-dev-tools
- rc entries referencing homelab-dev-tools

## Quickstart

```bash
which llm
llm up
gc
```

## Repo layout

```
.
├── bin/
├── git-tools/
├── lib/
├── llm/
├── prompts/
├── .gitignore
├── README.md
├── install.sh
├── uninstall.sh
└── VERSION
```

## Security (do not commit)

These files must never be committed:

- llm/.env
- llm/models/*.gguf
- any *.pem, *.key, *.pfx, *.keystore
- .env, .env.*

Rotate secrets immediately if committed by mistake.

## License

MIT License © 2026
