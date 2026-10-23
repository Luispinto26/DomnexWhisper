# DomnexWhisper

App de ditado e de notas de reuniões para macOS. A voz é transcrita no próprio Mac e o texto pode ser limpo com o Claude.

Manténs uma tecla premida, falas e largas. A app transcreve localmente com o WhisperKit, limpa o texto com o Claude (opcional) e cola-o na app onde estás a escrever.

## Compilar

```bash
./scripts/build-app.sh
open ~/Applications/DomnexWhisper.app
```

A app é assinada com o primeiro certificado *Apple Development* do Porta-chaves (ou com `DOMNEXWHISPER_SIGN_IDENTITY`). Assinar sempre com o mesmo certificado mantém as permissões entre compilações.

## Ícones

O ícone da app (`Resources/AppIcon.icns`) é gerado a partir do símbolo da Domnex em `Resources/Symbol.svg`. O mesmo símbolo é usado na barra de menus. Para gerar de novo depois de mudar o símbolo:

```bash
swift scripts/make-icons.swift
```

## Primeira utilização

1. **Microfone**: aceita o pedido do macOS.
2. **Acessibilidade**: em Definições do Sistema › Privacidade e Segurança › Acessibilidade, ativa o *DomnexWhisper*. É necessária para detetar a tecla e para colar (⌘V).
3. **Modelo de voz**: na primeira vez, descarrega o modelo escolhido (632 MB ou 216 MB) do Hugging Face (`argmaxinc/whisperkit-coreml`) para `~/Library/Application Support/DomnexWhisper/Models`. Depois o Core ML prepara-o para o teu chip, o que pode demorar alguns minutos. O estado aparece no menu do ícone da Domnex, na barra de menus.
4. **Chave do Claude** (opcional): em Definições…, cola a tua chave da API da Anthropic. Fica guardada no Porta-chaves. Sem chave, a transcrição é colada tal como sai.

A tecla por omissão é o **⌥ Option direito**. Se a usares num atalho (por exemplo ⌥2 = @), o ditado é cancelado.

## Reuniões

Menu 🎙 › **Gravar reunião**. O DomnexWhisper ouve o teu microfone ("Eu") e o som do computador ("Outros", os participantes da chamada), sem bots na reunião. A transcrição aparece numa janela de 30 em 30 segundos. Em **Parar e criar notas**, o Claude escreve o resumo, as decisões e os próximos passos, e tudo é guardado em `~/Documents/DomnexWhisper/Reuniões/*.md`.

- Na primeira vez, o macOS pede autorização para gravar o áudio do sistema.
- O áudio fica só na memória, em bocados de ~30 s, e é apagado assim que é transcrito. Só o texto é guardado e enviado ao Claude.
- Com colunas em vez de auscultadores, as vozes dos outros também chegam ao microfone e podem aparecer como "Eu".
- Enquanto uma reunião está a ser gravada, o ditado fica em pausa.
- Avisa sempre os participantes de que a reunião está a ser transcrita.

## Testes sem interface

```bash
B=$(swift build -c release --show-bin-path)
say -v Joana -o /tmp/teste.aiff "Olá, isto é um teste do ditado."
"$B/DomnexWhisper" --test-transcribe /tmp/teste.aiff
ANTHROPIC_API_KEY=... "$B/DomnexWhisper" --test-format "hum então tipo amanhã às três não às quatro"
```

## Estrutura

| Ficheiro | Função |
|---|---|
| `HotkeyMonitor.swift` | Tecla global (CGEventTap), carregar para falar |
| `AudioRecorder.swift` | Microfone → 16 kHz mono |
| `Transcriber.swift` | WhisperKit local |
| `ClaudeFormatter.swift` | Limpeza do texto via API do Claude (HTTP) |
| `Paster.swift` | Área de transferência + ⌘V, repõe o conteúdo anterior |
| `DictationController.swift` | Liga tudo |
| `SystemAudioCapture.swift` | Som do sistema (Core Audio process tap) → 16 kHz mono |
| `MeetingSession.swift` | Reunião: cortes de ~30 s, transcrição em fila, linhas "Eu"/"Outros" |
| `MeetingNotes.swift` | Notas com o Claude e ficheiro Markdown |
| `MeetingWindow.swift` | Janela da reunião ao vivo |
| `ClaudeClient.swift` | Pedidos à API do Claude e contagem de tokens |
| `Overlay.swift` | Barra flutuante "A ouvir…" |
| `AppDelegate.swift`, `SettingsView.swift` | Menu na barra de menus e definições |

## Privacidade

- O áudio nunca sai do Mac.
- Com a formatação ligada, só o texto transcrito é enviado à Anthropic.
- O histórico (`history.jsonl`) guarda apenas texto, localmente.
