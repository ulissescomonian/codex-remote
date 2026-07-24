# Codex Remote — arquitetura

## Decisao principal

O app usa SwiftUI para a barra de menus e separa a integracao com o Codex em servicos testaveis. A UI nunca conhece paths internos, `Process` ou JSON bruto.

## Componentes

```text
MenuBarExtra / Settings / Pairing
                |
        RemoteControlViewModel
                |
       RemoteControlServicing
        /        |          \
 ProcessRunner  DaemonProbe  CodexLocator
                              |
                         UserDefaults
```

- `ProcessRunner`: executa um binario diretamente, aplica timeout, garante o encerramento do processo pai sem depender do EOF herdado por descendentes e retorna stdout/stderr/exit code.
- `CodexLocator`: resolve override, `~/.local/bin`, Homebrew, `/usr/local/bin`, app ChatGPT e PATH.
- `DaemonStatusProbe`: executa `codex app-server daemon version`; exit zero com JSON valido significa daemon respondendo, erro de conexao/socket ausente significa parado e outras falhas ficam como desconhecidas.
- `RemoteControlService`: traduz Start/Stop/Pair em argumentos do CLI, separa o payload opaco do codigo manual e compoe Restart.
- `PairingQRCodeGenerator`: gera localmente um QR nativo, nitido e com nivel de correcao M, sem rede ou dependencias externas.
- `StaleUpdaterRecovery`: tenta Stop oficial e, somente apos uma falha especifica ou timeout de Start com daemon ainda parado, valida e encerra com SIGTERM um `pid-update-loop` de release antiga ou um updater standalone gerenciado travado com filho app-server zumbi comprovado.
- `RemoteControlViewModel`: serializa acoes, acompanha as fases locais e remotas do Restart, representa sucesso parcial como aviso, reconcilia a politica de recuperacao automatica e descarta pairing codes quando solicitado.
- `AppLifecycleCoordinator`: inicia em `applicationDidFinishLaunching`, compartilha ViewModel e LoginItemController com a UI, mantem uma unica task de polling e rele as preferencias a cada ciclo.
- `LoginItemService`: adapta `SMAppService.mainApp`.
- `LoginItemController`: registra o app no primeiro uso com default ativo, persiste a escolha do usuario e representa os quatro estados reais do `SMAppService`.

## Estados

```text
unknown -> checking -> stopped
                    -> running
                    -> failure

stopped -> starting -> running | failure
running -> stopping -> stopped | failure
running -> restart-stopping -> restart-starting -> restart-connecting -> running | warning | failure
running -> pairing -> running + pairing code | failure
```

Somente uma operacao mutavel roda por vez. A verificacao periodica nao deve substituir um estado transitorio.

Com a recuperacao automatica ligada, cada ciclo de polling reconcilia o estado desejado. Um daemon parado e iniciado novamente com intervalo minimo de 30 segundos entre tentativas. Se uma tentativa automatica falhar com o daemon parado, uma unica segunda tentativa e agendada pelo proprio ViewModel depois desse intervalo, independentemente do polling visual. A task pendente e cancelada ao recuperar, desativar auto-start ou executar Stop manual. Stop manual suprime a recuperacao durante a sessao atual do app; Start manual ou uma nova abertura remove essa supressao.

## Contrato de processo

Cada chamada recebe URL do executavel, array de argumentos, ambiente minimo opcional e timeout. O app nao executa `/bin/zsh -c`, nao interpola strings e nao herda dados secretos deliberadamente.

No timeout, o runner envia SIGTERM e aguarda o encerramento do processo pai, com fallback SIGKILL depois de 500 ms. A conclusao por timeout nao espera EOF de stdout/stderr, porque um descendente pode manter os pipes herdados abertos indefinidamente; callbacks tardios nao podem completar a mesma continuation duas vezes.

Comandos do MVP:

```text
codex remote-control start --json
codex remote-control stop --json
codex remote-control pair --json
```

Restart executa Stop e Start sequencialmente. Saida JSON de Pair deve ser analisada de forma tolerante a nomes de campo conhecidos. `pairingCode` e um valor opaco, separado de `manualPairingCode`, e vira o parametro `pairing_code` de `https://chatgpt.com/codex/pair` por composicao segura de URL. O QR codifica essa URL completa; ele nunca e derivado do codigo manual. Texto bruto jamais e exibido ou persistido.

O CLI pode manter Start aberto por ate 10 segundos enquanto espera a conexao remota. Durante Restart, o ViewModel faz probes locais somente de leitura; quando o socket responde, muda a apresentacao de `iniciando` para `reconectando` sem liberar acoes conflitantes. Se o CLI terminar com a assinatura especifica de conexao remota em erro, mas o probe confirmar o daemon ativo, o resultado e sucesso parcial e fica registrado como aviso amarelo do ultimo inicio. Outras falhas continuam sendo erros. Esse aviso usa tempo passado, nao equivale a um probe remoto e nao descreve o estado atual da conexao.

Uma falha de Start contendo simultaneamente `app server did not become ready` e `app-server-control.sock` permite uma unica tentativa de reparo. O reparo tenta primeiro `remote-control stop --json`, mas Stop com exit zero nao e prova de que o updater saiu: a inspecao segura ainda procura um candidato excepcional. Se nao houver candidato seguro, o sucesso do Stop basta para permitir novo Start; se o Stop falhar, a ausencia de candidato seguro continua sendo falha.

Nos dois caminhos, o CLI que falhou deve ser o standalone `current`; o PID file precisa ser regular, pequeno, sem symlink e do usuario atual; PID, UID, inicio, argumentos, executavel carregado e raiz de releases precisam coincidir. O caminho com `app-server.pid` zumbi e avaliado primeiro e aceita o pai carregado por qualquer release standalone gerenciada, inclusive durante a transicao em que o executavel real ainda e antigo mas o argv ja aponta diretamente para a release `current`. O filho precisa estar em estado `Z`, pertencer ao mesmo UID, ter o updater como PPID, preservar o horario de inicio e estar com o socket `~/.codex/app-server-control/app-server-control.sock` ausente. Como um zumbi nao pode retomar execucao, esse caminho usa duas revalidacoes imediatas. Sem zumbi, um updater carregado por release diferente de `current` exige o mesmo fingerprint estavel por pelo menos 30 segundos. Nao ha SIGKILL, exclusao de PID file nem repeticao do sinal para o mesmo fingerprint.

O stderr de Start pode anexar historico antigo do app-server. A camada de servico substitui essa assinatura por uma mensagem curta e, nas demais falhas, remove ANSI, paths absolutos e valores com formato de credencial antes de entregar o texto a UI.

## Deteccao de status

O probe principal e `codex app-server daemon version`. Ele conecta ao socket de controle local e, quando o daemon responde, retorna JSON com as versoes do CLI e app-server. Socket ausente ou conexao recusada significam daemon parado; JSON invalido, timeout e outros erros ficam como estado desconhecido.

PID, `ps` e `settings.json` nao sao autoridade de status: o updater pode permanecer vivo e `remoteControlEnabled=true` pode persistir quando o app-server esta parado. `ps` e metadados de PID sao usados somente na reparacao excepcional, depois da falha especifica, como parte de uma identidade validada junto com `libproc`; nunca entram no polling. `codex doctor --json` e reservado para uma acao futura de diagnostico porque executa verificacoes mais amplas e pode levar segundos.

O MVP mede se o daemon esta respondendo. Isso nao equivale a provar que a conexao remota esta `connected`; a UI deve usar "Daemon ativo" ate existir um adaptador para `remoteControl/status/read`.

## Persistencia

UserDefaults pode guardar apenas:

- caminho customizado do Codex;
- auto-start e recuperacao automatica do daemon;
- preferencia de launch at login, independente do auto-start do daemon;
- intervalo de atualizacao.

Pairing codes, payload/URL do QR, stdout integral e credenciais nao sao persistidos.

## Testes

- Runner falso para validar argumentos, sequencia e erros.
- Runner falso e fixtures para daemon respondendo, socket ausente, timeout e JSON invalido.
- Fixtures JSON para Pair, incluindo payload opaco, codigo manual opcional e expiracao.
- Geracao e decodificacao offline do QR com payload sintetico.
- View model em `@MainActor`, usando servico falso.
- Fases observaveis do Restart e classificacao entre sucesso parcial de conexao e falha real.
- Retry automatico independente do polling, cancelamento por Stop/opt-out/sucesso e ausencia de duplicatas.
- Stop oficial bem-sucedido com e sem updater antigo validado.
- Updater gerenciado atual ou antigo com filho zumbi validado, inclusive argv direto em `current`, alem de rejeicoes por estado, PPID, inicio, socket ou identidade divergentes.
- Sanitizacao de stderr historico, ANSI, paths locais e valores com formato de credencial.
- Timeout real com descendente mantendo pipes abertos e captura normal separada de stdout/stderr.
- Nenhum teste de unidade invoca o CLI real.
