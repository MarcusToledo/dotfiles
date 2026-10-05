# dotfiles

Configuração pessoal compartilhada entre Mac, VPS e notebook Ubuntu.

O conteúdo antigo (zsh + powerlevel10k de 2022) está preservado na tag
[`legacy-2022`](https://github.com/MarcusToledo/dotfiles/tree/legacy-2022).

## herdr

| Arquivo | Conteúdo |
|---|---|
| `herdr/config.base.toml` | Config comum a todas as máquinas |
| `herdr/profiles/<perfil>.toml` | O que muda por máquina (`mac`, `vps`, `ubuntu`) |
| `herdr/plugins.txt` | Plugins fixados por commit e estado (enabled/disabled) |
| `herdr/plugin-config/<id>/` | Config de cada plugin, copiada para `~/.config/herdr/plugins/config/<id>/` |

O `~/.config/herdr/config.toml` é **gerado**: base + perfil, concatenados. Um perfil
só pode declarar tabelas que a base não declara (hoje: `[terminal]` e `[ui.toast]`).

```bash
herdr/install.sh <perfil> --dry-run   # mostra o diff e o que mudaria, sem escrever
herdr/install.sh <perfil>             # valida, faz backup do config atual e instala
```

O script valida a config com `herdr config check` antes de instalar, instala ou
atualiza os plugins no commit fixado, aplica enabled/disabled e recarrega o
servidor se ele estiver rodando.

Mudou algo pela UI do herdr ou editou `config.toml` direto? Leve a mudança para a
base ou para o perfil. O `--dry-run` mostra a divergência.

Para atualizar um plugin, troque o commit em `plugins.txt` (`herdr plugin list`
mostra o commit instalado) e rode o install em cada máquina.
