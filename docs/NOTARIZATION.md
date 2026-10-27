# Notarização da app macOS

## Decisão atual

**Não avança por agora, sem conta Apple Developer.** O Thoth continua a ser
distribuído sem notarização. Nem `scripts/build.sh` nem o release no GitHub
assinam nem notarizam a app. Na primeira abertura, o macOS bloqueia a app, e a
landing e o README explicam como a abrir. Este documento fica como referência,
caso a decisão mude.

## Requisitos

- **Apple Developer Program** (individual ou organização). Numa conta individual,
  o nome legal do titular aparece como programador.
- **Certificado Developer ID Application**, criado pelo titular da conta e válido
  5 anos. O certificado local autoassinado que existe hoje não serve.
- **Hardened Runtime** (`codesign --options runtime`) e carimbo temporal
  (`--timestamp`), ambos obrigatórios para a notarização.
- **Entitlements:** nenhum. A app não usa sandbox, JIT, plug-ins nem Apple Events
  e só liga a bibliotecas do sistema. Não se deve ativar a App Sandbox, porque
  partiria a leitura de `~/.claude/` e o LaunchAgent de «Abrir ao iniciar sessão».
- **Credenciais do `notarytool`** guardadas num perfil do Keychain com
  `xcrun notarytool store-credentials`, com uma palavra-passe específica da app
  ou uma chave da API do App Store Connect. Nunca as guardar no repositório.

## Custo anual

- Apple Developer Program: 99 USD por ano (o valor em euros aparece na inscrição).
- Ferramentas (`codesign`, `notarytool`, `stapler`) e notarizações: gratuitas.
- Manutenção: renovar a inscrição todos os anos, renovar o certificado a cada
  5 anos e guardar em segurança o `.p12` com a chave privada.

## Fluxo resumido

```bash
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <Nome> (<TEAM_ID>)" build/Thoth.app
ditto -c -k --keepParent build/Thoth.app /tmp/Thoth-submit.zip
xcrun notarytool submit /tmp/Thoth-submit.zip --keychain-profile <perfil> --wait
xcrun stapler staple build/Thoth.app
# voltar a gerar build/Thoth-<versão>-mac.zip a partir da .app já agrafada
```

Para verificar: `spctl --assess --type execute -vv build/Thoth.app` deve mostrar
`source=Notarized Developer ID`.

## Impacto real no utilizador

- **Desaparece o bloqueio** da primeira abertura: deixa de ser preciso ir a
  Definições do Sistema → Privacidade e Segurança → «Abrir mesmo assim», usar o
  botão direito → Abrir ou o comando `xattr`.
- **Continua a confirmação «Abrir»** que o macOS mostra para qualquer app
  descarregada da Internet. O aviso não desaparece por completo.
- A app aparece com o nome do programador, e as autorizações de pastas
  protegidas tendem a manter-se entre versões.
- A funcionalidade não muda. A notarização só verifica malware conhecido e
  requisitos técnicos.

## Release no GitHub

O workflow `.github/workflows/release.yml` **não usa `scripts/build.sh`**. Repete
a montagem da app e publica o zip sem assinatura. Se um dia se avançar, é preciso
fazer uma de duas coisas: assinar e notarizar no CI (certificado `.p12` e chave
da API como secrets, num keychain temporário), ou notarizar localmente e
substituir o anexo do release.

## Textos a mudar se um dia avançar

Só depois de existir um release notarizado:

- `landing/src/i18n.js` (PT e EN):
  - `install.quick.steps[2]`: trocar a frase sobre a app não notarizada por
    «Na primeira vez, o macOS pede confirmação: escolhe «Abrir»».
  - `install.quick.firstOpen`: remover as instruções para macOS 14 e macOS 15.
- `landing/src/components/Install.jsx`: remover o componente `FirstOpen` e o
  comando `UNQUARANTINE_CMD` (`xattr -dr com.apple.quarantine …`).
- `README.md`, secção de instalação: substituir o parágrafo «The app isn't
  notarised, so Gatekeeper blocks the first launch…» por uma frase a dizer que a
  app é notarizada e que basta confirmar «Open».
- `RELEASE_NOTES/`: referir a mudança na primeira versão notarizada.
