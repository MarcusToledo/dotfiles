# dotfiles

Configuração pessoal compartilhada entre Mac, VPS e notebook Ubuntu.

O conteúdo antigo (zsh + powerlevel10k de 2022) está preservado na tag
[`legacy-2022`](https://github.com/MarcusToledo/dotfiles/tree/legacy-2022).

## Instalação

Máquina nova ou já configurada (idempotente: rodar de novo não muda nada):

```bash
curl -fsSL https://raw.githubusercontent.com/MarcusToledo/dotfiles/master/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/MarcusToledo/dotfiles/master/install.sh | bash -s -- --profile ubuntu
~/dotfiles/install.sh [--profile <perfil>] [--dry-run] [--only herdr,omp]
```

| Flag | Efeito |
|---|---|
| `--profile mac\|ubuntu\|vps` | Força o perfil (padrão: detectado) |
| `--dry-run` | Mostra o que mudaria, sem escrever; também não faz `git pull` |
| `--only m1,m2` | Roda só esses módulos, sempre na ordem fixa (`herdr`, `omp`) |

Qualquer outro argumento aborta.

O que o `install.sh` faz:

1. Confere `git` e `curl`. No macOS sem git, abre o instalador das Command Line
   Tools (`xcode-select --install`) e para: rode de novo quando terminar. No
   Linux com `apt-get`, instala os comandos ausentes (pede senha via `sudo`).
2. Repo em `${DOTFILES_DIR:-~/dotfiles}`: ausente → `git clone` via https (funciona
   antes de existir chave SSH; também sob `--dry-run`); presente e limpo →
   `git pull --ff-only` (se falhar, avisa e segue com o local); com mudanças
   locais → avisa e segue com o estado local.
3. Re-executa o `install.sh` do repo, para rodar sempre a versão mais nova.
4. Mostra SO, perfil e modificador dos atalhos, e roda cada módulo como
   `<módulo>/install.sh --profile <perfil> [--dry-run]`. Para no primeiro que
   falhar, dizendo qual.

| Perfil | Quando é detectado | Modificador dos atalhos |
|---|---|---|
| `mac` | macOS | `cmd` |
| `ubuntu` | Linux com desktop (`DISPLAY`/`WAYLAND_DISPLAY`/`XDG_CURRENT_DESKTOP` ou `graphical.target`) | `alt` |
| `vps` | Linux sem desktop | `cmd` (quem digita é o Ghostty do Mac, via SSH) |

### Módulos

- `herdr`: instala o binário, gera a config (base + perfil, com `{{mod}}`
  trocado pelo modificador do perfil), instala os plugins fixados, lazygit e,
  no macOS, fish via Homebrew (caminho resolvido para Intel/Apple Silicon).
- `omp`: instala bun, Node.js (≥ 18.14.1, sem sudo no Linux) e o omp na versão
  fixada, clona `~/.omp` do repo privado `my-omp` via SSH, instala os plugins,
  liga o `CLAUDE.md` por symlink, instala as skills, roda a integração com o
  herdr, compila o MCP server design-inspiration (commit fixado + patch local) e
  configura o cliente do ai-memory e o túnel até a VPS.
  Detalhes em `~/.omp/README.md`.

### O que continua manual

- Chave SSH cadastrada no GitHub (o módulo `omp` clona `my-omp` via SSH).
- Tailscale instalado e logado (o túnel do ai-memory passa por ele).
- `/login` no omp.
- Segredos em `~/.omp/agent/.env`.

Os módulos avisam (`!`) no fim o que não dá para automatizar; nada disso é simulado.

### Adicionar um módulo

Crie `<módulo>/install.sh` aceitando `[--profile <p>] [--dry-run]` (fazendo
`source` de `lib/common.sh` e `parse_args "$@"`, idempotente, sem escrever nada
sob `--dry-run`) e acrescente o nome em `MODULES`, no topo do `install.sh`.

## herdr

| Arquivo | Conteúdo |
|---|---|
| `herdr/config.base.toml` | Config comum a todas as máquinas |
| `herdr/profiles/<perfil>.toml` | O que muda por máquina (`mac`, `vps`, `ubuntu`) |
| `herdr/plugins.txt` | Plugins fixados por commit e estado (enabled/disabled) |
| `herdr/plugin-config/<id>/` | Config de cada plugin, copiada para `~/.config/herdr/plugins/config/<id>/` |

O `~/.config/herdr/config.toml` é **gerado**: base + perfil, concatenados. Um perfil
só pode declarar tabelas que a base não declara (hoje: `[terminal]` e `[ui.toast]`).

Todo perfil começa com `# keymap-modifier: cmd|alt`. Na base, os atalhos diretos
são escritos como `{{mod}}+<tecla>`, e o install troca `{{mod}}` pelo modificador
do perfil. O perfil Mac resolve `{{fish_shell}}` pelo prefixo do Homebrew.

```bash
herdr/install.sh [--profile <perfil>] --dry-run   # mostra o diff e o que mudaria, sem escrever
herdr/install.sh [--profile <perfil>]             # valida, faz backup do config atual e instala
```

Sem `--profile`, o perfil é detectado (tabela acima).

O script valida a config com `herdr config check` antes de instalar, instala ou
atualiza os plugins no commit fixado, aplica enabled/disabled e recarrega o
servidor se ele estiver rodando.

Mudou algo pela UI do herdr ou editou `config.toml` direto? Leve a mudança para a
base ou para o perfil. O `--dry-run` mostra a divergência.

Para atualizar um plugin, troque o commit em `plugins.txt` (`herdr plugin list`
mostra o commit instalado) e rode o install em cada máquina.
