# Codex Remote

## Contexto do produto

Codex Remote e um utilitario nativo de barra de menus para macOS que controla o daemon iniciado por `codex remote-control`. O app deve mostrar o estado atual, iniciar, parar, reiniciar e gerar um codigo temporario de pareamento sem exigir que o usuario abra o Terminal.

Antes de mudancas relevantes, leia `docs/01-product-plan.md` e `docs/02-architecture.md`.

## Contratos estabilizados

- Nome exibido: `Codex Remote`.
- Bundle identifier: `com.ulisses.codexremote`.
- Plataforma minima: macOS 14.
- Build: SwiftPM; o bundle `.app` e montado pelo `Makefile`.
- Interface: SwiftUI `MenuBarExtra`, com `LSUIElement=true` e sem icone no Dock.
- Acoes publicas: `codex remote-control start|stop|pair --json`.
- Restart e composto por `stop` seguido de `start`.
- O executavel Codex deve ser chamado por `Process` com argumentos separados. Nunca monte um comando de shell.
- O estado rapido usa `codex app-server daemon version`, que testa o socket local e imprime JSON quando o daemon responde. Encapsule esse probe atras de protocolo porque o grupo `app-server daemon` pode mudar.
- O codigo de pairing existe somente em memoria. Nunca grave pairing code, tokens ou conteudo de `~/.codex/auth.json` em logs.

## Estrutura e ownership

- `Sources/CodexRemote/Domain`: modelos e protocolos puros.
- `Sources/CodexRemote/Services`: processos, localizacao do Codex, estado do daemon e login item.
- `Sources/CodexRemote/App` e `Sources/CodexRemote/Views`: lifecycle e SwiftUI, sempre isolados em `@MainActor` quando mantiverem estado de interface.
- `Tests/CodexRemoteTests`: testes sem executar o Codex real e sem alterar daemons do usuario.
- `Package.swift`, `Makefile`, `Resources`, `README.md` e `docs/` sao hotspots compartilhados; somente o integrador da onda os altera.

Um caminho gravavel tem somente um owner por onda. Mudancas concorrentes no mesmo arquivo devem ser serializadas.

## Regras de implementacao

- Prefira tipos pequenos, dependencias injetadas e protocolos testaveis.
- Toda operacao de processo deve ter timeout, capturar stdout/stderr separadamente e produzir erro amigavel.
- Nao presuma que `~/.local/bin/codex` sempre existe; use descoberta com
  override persistido e caminhos conhecidos.
- Nao use `codex doctor --json` nem PID/`ps` em polling frequente. O updater pode continuar vivo com o daemon parado; use o probe de socket por `app-server daemon version` e reserve Doctor para diagnostico sob demanda.
- Uma falha de status nao deve travar o menu. Represente-a como estado desconhecido ou erro recuperavel.
- Desabilite acoes conflitantes enquanto uma operacao estiver em andamento.
- Alteracoes de launch-at-login devem usar `SMAppService`, sem editar LaunchAgents manualmente.

## Validacao obrigatoria

```bash
swift build
swift test
make bundle
plutil -lint CodexRemote.app/Contents/Info.plist
```

Testes nunca devem chamar `remote-control start`, `stop` ou `pair` de verdade. Use runners e file systems falsos.
