# Codex Remote — validacao do MVP

Validado inicialmente em 17 de julho de 2026, revalidado para distribuicao em
21 de julho de 2026 e para a correcao de recuperacao em 24 de julho de 2026
com macOS arm64, Xcode 26.6, Swift 6.3.3 e Codex CLI 0.145.0.

## Resultados

- `swift build`: passou.
- `swift test`: 84 testes em 7 suites, todos passaram.
- `make bundle`: produziu `CodexRemote.app` release.
- `plutil -lint`: `Info.plist` valido.
- `codesign --verify --deep --strict`: bundle valido com assinatura ad-hoc local.
- `AppIcon.icns`: integrado ao bundle.
- `AppIcon.png`: fonte 1024 x 1024 com canal alpha e cantos transparentes;
  `Scripts/make_icon.sh` regenera o ICNS usado pelo bundle.
- Polling silencioso: verificacoes de status preservam o ultimo simbolo conhecido na barra de menus.
- O status item usa painel `.window`, sem crash do backend `NSMenu`, com timestamp estatico.
- Launch at login usa `SMAppService.mainApp`, preserva opt-out e exibe estados de aprovacao do macOS.
- O polling religa o daemon depois de uma parada inesperada, com retry controlado, mas respeita Stop manual durante a sessao atual.
- A recuperacao de update tenta Stop oficial e pode encerrar somente um updater comprovadamente antigo ou um updater gerenciado com filho zumbi validado.
- Pair preserva separadamente os artefatos opaco e manual, gera a URL oficial com encoding seguro e renderiza localmente um QR nitido com quiet zone.
- Restart distingue Stop, Start e reconexao, detecta o daemon local durante a espera do CLI e registra falha remota transitoria como aviso historico quando o daemon esta ativo.
- A confirmacao de updater antigo roda em 30 segundos sem depender do polling; Stop bem-sucedido nao oculta updater antigo e timeout nao fica preso em pipes herdados.
- Updater standalone gerenciado pode ser recuperado imediatamente somente quando seu app-server registrado e um filho zumbi validado duas vezes; timeout de Start entra na mesma verificacao depois de um probe, o polling inicia pelo lifecycle do app e erros nao exibem o historico bruto do app-server.
- Icones da barra de menus agora distinguem daemon ativo, parado e estado desconhecido sem animacao durante o polling.
- Registro real confirmado no Background Task Management: `CodexRemote`, URL `/Applications/CodexRemote.app`, disposition `enabled, allowed, notified`.
- Smoke test seguro: app permaneceu ativo com auto-start temporariamente desativado e nao alterou o daemon.
- Teste funcional: o app instalado e aberto com configuracao padrao iniciou o Remote Control sem um comando Start no shell; `codex app-server daemon version` respondeu `status=running`.
- Recuperacao funcional: depois de `remote-control stop --json` externo retornar `status=stopped`, o app detectou a queda no polling e restaurou `status=running` automaticamente.
- Diagnostico de update: um `pid-update-loop` orfao da versao 0.144.2 bloqueou ate `remote-control stop`; depois de encerrar o processo antigo, a reconciliacao do app iniciou automaticamente o daemon atualizado 0.144.3.
- Incidente 0.144.4 -> 0.144.5 reproduzido: updater antigo permaneceu com PID/UID/inicio/path/argumentos validos e bloqueou o socket. SIGTERM seguro restaurou o daemon 0.144.5; os testes de regressao cobrem a confirmacao automatica em duas observacoes.
- Incidente 0.145.0 reproduzido: updater gerenciado permaneceu com filho app-server zumbi e socket ausente; SIGTERM encerrou o pai imediatamente e o lifecycle do app iniciou novos updater/app-server e restaurou o probe. A regressao cobre pai antigo com argv direto na release `current`, alem do pai atual.

## Cobertura automatizada

- parsing das versoes do daemon;
- socket ausente interpretado como daemon parado;
- Restart serializado como Stop seguido de Start;
- parsing separado do payload QR, codigo manual opcional e expiracao Unix;
- encoding seguro da URL oficial e compatibilidade com resposta antiga apenas manual;
- geracao nativa do QR, quiet zone e decodificacao exata do payload sintetico via Vision;
- resposta invalida de Pair nao vaza stdout bruto no erro.
- auto-start com daemon parado e opt-out com auto-start desligado;
- recuperacao de transicoes `running -> stopped` e `unknown -> stopped`;
- supressao depois de Stop manual, retomada por Start e intervalo minimo entre retries;
- fases observaveis do Restart, probe local exclusivo desse fluxo e acoes bloqueadas ate o termino;
- falha especifica da conexao remota classificada como aviso do ultimo inicio somente com daemon confirmado, sem ocultar falhas reais nem sugerir status remoto atual;
- retry de recuperacao em 30 segundos independente do polling, com cancelamento por Stop, opt-out, sucesso e corrida com reconciliacao;
- Stop oficial bem-sucedido ainda inspeciona updater antigo e preserva confirmacao temporal antes de SIGTERM;
- timeout aguarda o pai morrer, mas nao EOF herdado por descendentes, com fallback SIGKILL testado em processo sintetico;
- gatilho exato da recuperacao, uma unica tentativa e preservacao do erro original quando o reparo falha;
- updater gerenciado atual ou antigo elegivel imediatamente somente com filho zumbi validado; sem zumbi, release antiga preserva confirmacao temporal e bloqueio de sinal repetido;
- rejeicao por UID, horario de inicio, argumentos, path ou alvo `current` divergentes;
- rejeicao do caminho zumbi por estado, PPID, inicio, socket ou registro divergentes;
- mensagens de erro sem historico gerenciado, ANSI, paths absolutos ou valores com formato de credencial;
- launcher `current` com release antiga carregada, CLI customizado rejeitado e confirmacao temporal de 30 segundos;
- lifecycle independente da renderizacao do `MenuBarExtra`, task unica, cancelamento no encerramento e preferencias relidas por ciclo;
- PID file por symlink rejeitado sem tocar em processos reais.

Os testes usam doubles e nao executam Start, Stop ou Pair reais.

## Distribuicao 1.0

- `Scripts/package_app.sh`: produziu `.build/CodexRemote.app` Release arm64.
- Bundle identifier: `com.ulisses.codexremote`, consistente com o app instalado
  usado na validacao de launch at login.
- Versao/build: `1.0` (`1`).
- `plutil -lint`: passou no plist empacotado.
- `codesign --verify --deep --strict`: passou com assinatura ad-hoc local.
- `Scripts/package_dmg.sh`: criou e verificou o DMG comprimido com app e atalho
  `/Applications`.
- Montagem somente leitura confirmou `Codex Remote.app`, bundle identifier,
  versao, build, requisito macOS 14 e assinatura interna.
- Artefato: `CodexRemote-1.0-arm64.dmg`.
- SHA-256:
  `b374dd88e79b71ea025f9e5ea83147c72cfd0379ca64bac63cec7a0306441c46`.
- Sidecar: `CodexRemote-1.0-arm64.dmg.sha256`, validado com `shasum -c`.

O app e assinado localmente para integridade do bundle, sem identidade Apple ou
Team ID. O app e o DMG nao sao notarizados. O DMG permanece fora do Git e deve
ser publicado junto com o checksum nos assets da GitHub Release `v1.0`.

## Pendente para distribuicao

- assinatura Developer ID;
- notarizacao Apple;
- teste de instalacao limpa e abertura pelo Gatekeeper em outra conta/macOS;
- teste manual de Pair e de `SMAppService` a partir do app instalado.
