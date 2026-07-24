# Codex Remote — plano do produto

## Visao

Transformar `codex remote-control` em uma experiencia nativa e visivel no macOS. O usuario deve saber, de relance, se o Remote Control esta funcionando e deve conseguir controla-lo sem abrir o Terminal.

## Usuario e problema

O usuario usa o Codex CLI no Mac e quer que o Remote Control esteja disponivel depois do login. Hoje ele precisa lembrar comandos, abrir um terminal e nao tem um indicador persistente do estado.

## Escopo do MVP

- Icone na barra de menus com estados parado, iniciando, ativo, parando e erro.
- Acoes Start, Stop e Restart.
- Acao Pair com QR Code para a camera do celular, exibicao e copia do codigo manual temporario.
- Atualizacao automatica do estado.
- Localizacao automatica do binario `codex` e override nas configuracoes.
- Preferencia para iniciar o Remote Control ao abrir o app e recuperar paradas inesperadas.
- Recuperacao segura de updater antigo ou updater standalone gerenciado travado com filho app-server zumbi comprovado.
- Preferencia `Abrir ao iniciar sessao` usando a API nativa do macOS.
- Ultimo erro ou aviso historico de inicializacao visivel, sem registrar segredos.
- Atalhos para atualizar estado, abrir configuracoes e sair.

## Fora do escopo inicial

- Implementar um cliente remoto ou protocolo proprio.
- Ler tokens, sessoes ou `auth.json` do Codex.
- Distribuicao pela Mac App Store.
- Telemetria e analytics.
- Atualizador automatico.
- Depender de endpoints privados do ChatGPT.

## Experiencia principal

1. O app abre como agente de menu bar, sem Dock.
2. Ele resolve o binario Codex e verifica o daemon local.
3. Se `Iniciar e manter o Remote Control ativo` estiver ligado e o daemon estiver parado, executa Start.
4. Se o daemon cair depois, o polling tenta recupera-lo com intervalo minimo entre tentativas; a acao manual Stop pausa essa recuperacao ate Start ou a proxima abertura do app.
5. Se Start falhar pela assinatura especifica de app-server ou expirar sem que o probe encontre o daemon ativo, o app tenta Stop oficial e so encerra um updater quando comprova uma release antiga ou um updater standalone gerenciado com filho zumbi registrado, mesmo UID/PPID/inicio e socket ausente.
6. Updater antigo exige confirmacao estavel em 30 segundos, sem depender do polling visual; o filho zumbi, que nao pode voltar a executar, usa dupla revalidacao imediata e idempotente.
7. Restart informa separadamente quando esta parando, iniciando e aguardando a reconexao remota.
8. Se o daemon voltar, mas o CLI reportar falha da conexao remota, o menu registra o fato como aviso do ultimo inicio, em tempo passado, sem apresenta-lo como status remoto atual ou afirmar que o daemon falhou.
9. O menu mostra estado, acoes coerentes e a hora da ultima verificacao.
10. Pair mostra o QR oficial e o codigo manual em uma pequena janela, oferece Copiar para o codigo manual e descarta os dois ao fechar.

## Roadmap

### Fase 1 — fundacao

- SwiftPM, bundle local, modelos, runner de processo e testes.
- Menu bar com status e comandos basicos.
- Documentacao de build e operacao.

### Fase 2 — confiabilidade

- Preferencias e selecao do binario.
- Login item e auto-start.
- Diagnostico sob demanda com `codex doctor --json`.
- Logs locais com redacao e limite de tamanho.

### Fase 3 — distribuicao

- Icone final com transparencia e DMG reproduzivel com checksum: concluidos na
  baseline 1.0.
- Assinatura Developer ID e notarizacao: pendentes de Apple Developer Program.
- Teste em reinicio/login real.
- Compatibilidade com atualizacoes do Codex CLI.

## Criterios de aceitacao do MVP

- `swift build` e `swift test` passam.
- `make bundle` produz `CodexRemote.app` valido.
- O app nao aparece no Dock.
- Start, Stop e Restart nao bloqueiam a interface.
- Restart diferencia as fases locais da espera pela conexao remota e nao mostra falha vermelha quando o daemon ja esta ativo.
- Uma atualizacao normal do Codex nao deixa a recuperacao presa ao desenho do icone nem exige intervencao manual para remover um updater antigo ou destravar um updater gerenciado com filho zumbi validado.
- Erros do menu nao exibem o historico bruto do app-server, sequencias ANSI, paths locais absolutos nem valores com formato de credencial.
- O status distingue daemon parado, daemon respondendo e falha desconhecida pelo probe local de socket.
- Pairing code nao aparece em logs, UserDefaults ou mensagens de erro persistidas.
- O QR usa o `pairingCode` opaco na URL oficial de pareamento; nunca transforma o codigo manual em QR.
- Binario ausente gera instrucao clara para configurar o caminho.
- Testes nao alteram o daemon real do usuario.

## Riscos conhecidos

- `remote-control` ainda e experimental e pode mudar.
- Nao existe hoje um subcomando `remote-control status`; o MVP usa o probe local `codex app-server daemon version`, isolado em um adaptador substituivel.
- Daemon ativo nao prova que a conexao remota esta conectada. O MVP deve rotular esse estado com precisao e tratar o retorno do Start como evento historico; a leitura da conexao remota fica para uma integracao posterior.
- `SMAppService` precisa ser validado no app empacotado, idealmente instalado em `/Applications`.
