# DeepSeek harness para @pired/lightroom-mcp

Este harness te permite **usar Lightroom Classic con DeepSeek en lugar de (o además de) Claude**.
Es un cliente MCP autocontenido: habla el protocolo MCP con el servidor `@pired/lightroom-mcp`
(a través de stdio, JSON-RPC), convierte las 56 herramientas al formato de *function calling*
de la API de DeepSeek y ejecuta en bucle las llamadas que el modelo pida.

**No tiene dependencias**: solo necesitas Node 18 o superior (usa `fetch` global) y una clave
de API de DeepSeek.

## Requisitos

1. Lightroom Classic (Windows) abierto, con el plugin instalado y **Start Server** pulsado
   en Plug-in Manager (igual que para Claude Desktop; ver el README principal).
2. Node 18+.
3. Clave de API de DeepSeek ([platform.deepseek.com](https://platform.deepseek.com)).

## Uso

**A — con el paquete instalado desde npm** (recomendado):

```bash
npm install -g @pired/lightroom-mcp
node "$(npm root -g)/@pired/lightroom-mcp/dist/deepseek-harness/deepseek-mcp-harness.mjs"
```

En PowerShell (Windows):

```powershell
npm install -g @pired/lightroom-mcp
$env:DEEPSEEK_API_KEY = "sk-..."
node "$(npm root -g)\@pired\lightroom-mcp\dist\deepseek-harness\deepseek-mcp-harness.mjs"
```

**B — desde el código fuente** (zip / repo):

```bash
cd pired-lightroom-mcp/server        # el servidor ya compilado (server/dist)
npm install && npm run build         # solo la primera vez

DEEPSEEK_API_KEY=sk-... node ../examples/deepseek-harness/deepseek-mcp-harness.mjs
```

En PowerShell (Windows):

```powershell
cd pired-lightroom-mcp\server
$env:DEEPSEEK_API_KEY = "sk-..."
node ..\examples\deepseek-harness\deepseek-mcp-harness.mjs
```

Escribes instrucciones en español natural y DeepSeek irá llamando a las herramientas
(`search_photos`, `set_develop_settings`, `add_ai_mask`…) hasta responder. Escribe `salir`
para terminar.

## Variables de entorno

| Variable | Obligatoria | Default | Descripción |
|---|---|---|---|
| `DEEPSEEK_API_KEY` | sí | — | Clave de la API de DeepSeek |
| `DEEPSEEK_MODEL` | no | `deepseek-chat` | Modelo (`deepseek-reasoner` también funciona) |
| `DEEPSEEK_BASE_URL` | no | `https://api.deepseek.com` | Endpoint alternativo (p. ej. compatibles) |
| `LIGHTROOM_MCP_SERVER` | no | auto | Ruta del servidor MCP: `server/dist/index.js` del repo, el `dist` empaquetado en npm o la instalación global |
| `LIGHTROOM_MCP_TOOLS` | no | `all` | Subconjunto de herramientas expuestas al modelo, separadas por comas |

### Filtrar herramientas (recomendado si el contexto pesa)

Con 56 herramientas el listado consume ~8–12 mil tokens de contexto por turno. Si tu
presupuesto es ajustado, expón solo las que necesites:

```bash
LIGHTROOM_MCP_TOOLS="search_photos,get_photo_preview,set_develop_settings,copy_develop_settings" \
DEEPSEEK_API_KEY=sk-... node ../examples/deepseek-harness/deepseek-mcp-harness.mjs
```

El filtro se aplica dentro del servidor MCP (`tools/list`), así que también sirve para
cualquier otro cliente que respete esa variable.

## El patrón "preview gate" con DeepSeek

El prompt del sistema ya instruye al modelo para que:

1. edite **una sola foto de muestra**,
2. genere la vista previa con `get_photo_preview`,
3. te pida revisar el JPEG (la ruta se imprime en la respuesta) y
4. solo tras tu aprobación replique los ajustes al lote con `copy_develop_settings`.

**Diferencia honesta con Claude:** deepseek-chat no acepta imágenes por la API, así que el
modelo no puede "mirar" la vista previa él mismo — te indica la ruta del archivo para que la
abras tú. Con Claude Desktop (visón nativa) el asistente sí ve la imagen en línea. Si esa
verificación automática te importa, usa Claude para los lotes grandes; el mismo servidor
sirve a ambos.

## Otros clientes (sin script)

El servidor es MCP estándar sobre stdio, por lo que funciona con cualquier cliente MCP:

- **Claude Desktop**: ver `examples/configs/claude-desktop.json` (y el README principal).
- **Claude Code**: `examples/configs/claude-code.mcp.json`.
- **Cherry Studio / 5ire / Cline / Roo Code**: `examples/configs/generic-stdio-client.json`.
- **Open WebUI / LibreChat** (necesitan MCP sobre HTTP): puente con
  `pip install mcp-proxy && mcp-proxy --port 8808 -- node server/dist/index.js` y registra
  la URL — ver `examples/configs/mcp-proxy-http.json`.

## Solución de problemas

| Síntoma | Causa probable |
|---|---|
| `No encuentro el servidor MCP` | Ni el paquete instalado (`npm i -g @pired/lightroom-mcp`) ni el repo compilado (`cd server && npm install && npm run build`) |
| Las herramientas responden "plugin not connected" | Lightroom no está abierto o no pulsaste **Start Server** en el Plug-in Manager |
| `DeepSeek API 401` | Clave inválida o sin saldo |
| El modelo "no ve" las fotos | deepseek-chat no tiene visión; revisa tú las rutas de preview que imprime |
