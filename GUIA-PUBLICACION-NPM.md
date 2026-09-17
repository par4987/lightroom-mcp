# Guía de publicación en npm — `@pired/lightroom-mcp`

Este proyecto está **100 % listo para publicar**. El único paso que no se puede
automatizar es el `npm publish` en sí, porque npm exige autenticarse con una
cuenta real (usuario, contraseña y OTP de 2FA) y el scope `@pired` debe
pertenecer a **tu** cuenta. Esta guía cubre todo lo demás.

---

## 0. Por qué hay que publicar desde tu máquina

- `npm publish` requiere una sesión autenticada (`npm login`). No hay forma de
  publicar de forma anónima.
- La primera vez que se publica un paquete con scope (`@pired/...`), npm crea
  el scope bajo la cuenta que lo publica. Ese dueño tiene que ser vos.
- npm puede exigir 2FA (código de un solo uso) en el momento de publicar: solo
  vos podés generarlo.

## 1. Requisitos (una sola vez)

1. **Creá tu cuenta en npm** con el usuario `pired` (o el que prefieras):
   https://www.npmjs.com/signup — así el scope `@pired` queda bajo tu control.
   > Si tu usuario npm va a ser otro (por ejemplo `jperez`), el paquete puede
   > llamarse igualmente `@pired/lightroom-mcp` solo si creás una
   > **organización** llamada `pired` en npmjs.com y publicás como miembro de
   > ella. Alternativa simple: renombrarlo a `@tu-usuario/lightroom-mcp`
   > (pedímelo y lo ajusto en 2 minutos).
2. **Habilitá 2FA** en Account → Security (recomendado; npm puede requerirlo
   para publicar).
3. **Node 18 o superior** instalado (recomendado 24 LTS).

## 2. Publicar (≈ 2 minutos)

Desde la raíz del proyecto:

```bash
cd server
npm install            # solo la primera vez / si cambió package.json
npm run build          # compila y arma dist/ autosuficiente
npm login              # abre el navegador y autoriza
npm whoami             # debe responder: pired
npm publish            # publishConfig.access=public ya está configurado
```

Si tenés 2FA con OTP, `npm publish` te va a pedir el código de 6 dígitos.

### ¿Qué se sube exactamente?

Lo que muestra `npm pack --dry-run` (ya verificado):

- **`pired-lightroom-mcp-3.1.0.tgz`** — 99 archivos, 116 kB comprimidos
  (494 kB descomprimidos):
  - `dist/` — código TS compilado **+ `LightroomMCP.lrplugin` (plugin Lua)
    + `deepseek-harness/` + `configs/` de ejemplo** (paquete autosuficiente:
    quien instala por npm obtiene todo, sin clonar el repo).
  - `README.md` y `LICENSE`.
- **No se publican** fuentes TS, tests ni `node_modules` (comportamiento
  estándar de npm; el campo `files` de `package.json` filtra el contenido).

### Publicar sin clonar el repo (opción con el tarball ya generado)

Si preferís no instalar nada antes de publicar, podés publicar el tarball
directamente (incluido en el zip de entrega como
`pired-lightroom-mcp-3.1.0.tgz`):

```bash
npm login
npm publish pired-lightroom-mcp-3.1.0.tgz
```

## 3. Verificar la publicación

```bash
npm view @pired/lightroom-mcp          # debe listar la 3.1.0
npm install -g @pired/lightroom-mcp
pired-lightroom-mcp --version           # → 3.1.0
```

Prueba de humo real del protocolo (instala el plugin Lua que viene dentro del paquete):

```bash
npx -y @pired/lightroom-mcp install-plugin
```

Y en Claude Desktop (Windows), en `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "cmd",
      "args": ["/c", "npx", "-y", "@pired/lightroom-mcp"]
    }
  }
}
```

## 4. Publicar versiones futuras

```bash
node scripts/bump-version.mjs 3.2.0    # propaga la versión a los 5 targets
cd server
npm run build
npm publish
```

El script `bump-version.mjs --check` valida que todas las versiones
(package.json, Info.lua, version.ts, mcpb/manifest.json, README) coincidan.

## 5. Notas de seguridad

- **Nunca** pegues tokens de npm (`npm_token`) en chats, issues o repos
  públicos: son equivalentes a tu contraseña de publicación.
- Si en el futuro querés publicar desde CI (GitHub Actions), usá un
  **granular access token** restringido al paquete y guardado como secreto del
  repo, nunca en texto plano.
- El nombre `@pired/lightroom-mcp` fue verificado disponible en el registry
  (E404 al momento de la verificación). Si al publicar recibís `E403 Forbidden`,
  significa que otra cuenta creó el scope `pired` antes: en ese caso
  renombrá la organización o el paquete y volvé a empaquetar.
