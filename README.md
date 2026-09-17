# Lightroom MCP AI (`@pired/lightroom-mcp`) 🎞️✨

**Servidor MCP para Adobe Lightroom Classic con funciones de inteligencia artificial.** Conectá **Claude, DeepSeek o cualquier cliente MCP** con tu catálogo de fotos para buscar, organizar, revelar y exportar — **ver las fotos** (previsualización JPEG en la conversación), **reducir ruido con la IA de Adobe**, **eliminar manchas**, **crear máscaras locales y de IA** (Seleccionar sujeto/cielo/fondo/personas + rangos de luminancia/color/PROFUNDIDAD), ajustar **curvas tonales**, aplicar **Auto Tone / Auto WB oficiales**, **resetear** por herramienta o parámetro, cambiar la **versión de proceso**, crear **snapshots**, y organizar con **etiquetas, IPTC en lote, copias virtuales y colecciones inteligentes**, todo conversando.

> Publicado en npm como **`@pired/lightroom-mcp`** — `npm i -g @pired/lightroom-mcp` · `npx -y @pired/lightroom-mcp`.
> Fork extendido de [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp) (MIT).
> Mantiene **las 18 herramientas originales** y agrega **38 herramientas nuevas** (**56 en total**).

---

## Requisitos

| Componente | Detalle |
| --- | --- |
| Sistema operativo | **Windows 10/11** (el denoise nativo usa automatización de teclado de Windows) |
| Adobe Lightroom Classic | 13.x o superior recomendado (AI Denoise 12.3+; **máscaras de IA** 12.4+) |
| Node.js | 18 o superior (para correr el servidor MCP) |
| Cliente MCP | Claude Desktop (recomendado), Claude Code, Cursor, Windsurf, VS Code, **harness de DeepSeek incluido**… |

## Qué tiene de nuevo este fork

| Herramienta | Qué hace |
| --- | --- |
| `ai_denoise` | **Reducción de ruido por IA híbrida**: dispara el *AI Denoise nativo* de Adobe (Foto ▸ Mejorar) automatizando el menú por teclado, verifica que aparezca el DNG nuevo y — si algo falla — aplica automáticamente una reducción manual inteligente según el ISO. Siempre informa qué método usó (`native` o `manual_fallback`). |
| `set_noise_reduction` | Sliders manuales de reducción de ruido y nitidez (LuminanceSmoothing, ColorNoiseReduction, detalle, máscaras de borde…). |
| `get_spots` / `add_spots` / `clear_spots` | **Eliminación de manchas** completa: leer, agregar (heal/clone con coordenadas normalizadas) y borrar spots, con verificación de escritura. |
| `add_local_adjustment` | **Máscaras locales** lineales (gradiente) o radiales con exposición, contraste, sombras/luces, saturación, temperatura y más, en unidades del módulo Revelar. |
| `read_local_adjustments` | Inspecciona las máscaras existentes (incluidas las de IA: sujeto, cielo, fondo…). |
| `set_flags` | Banderas pick / reject / ninguna para organizar descartes en lote. |
| `set_white_balance` | Balance de blanco por preset (As Shot, Auto, Daylight…) o Kelvin + matiz exactos. |
| `list_watermarks` | Lista las marcas de agua definidas en Lightroom. |
| `export_photos` (+) | Ahora acepta `watermark` para exportar con marca de agua. |
| `add_ai_mask` | **Máscaras de IA oficiales**: Seleccionar sujeto / cielo / fondo / objetos / personas / paisaje (SDK 12.4+), con ajustes opcionales aplicados a la máscara en la misma pasada. |
| `list_masks` / `remove_mask` | Inventario de máscaras: listarlas y borrarlas por id, con verificación. |
| `set_tone_curve` / `get_tone_curve` | **Curva tonal**: puntos [x,y] 0-255 en canal principal o RGB, presets (linear/medium/strong contrast), endpoints automáticos y verificación. |
| `apply_auto` | **Auto Tone y Auto WB oficiales** de Lightroom (mismo análisis que el botón Auto), con diff antes/después por foto. |
| `set_color_label` | Etiquetas de color (rojo…violeta, o ninguna) con verificación por foto. |
| `create_virtual_copies` | Copias virtuales (mismo archivo, revelado independiente — p. ej. una a color y otra en B&N). |
| `create_smart_collection` | **Colecciones inteligentes** por reglas (keywords, rating, fechas, cámara…), combinables con AND/OR. |
| `get_photo_preview` | **Renderiza un JPEG de la foto con sus ediciones y lo adjunta a la conversación** (Claude lo VE en línea; otros clientes reciben la ruta del archivo). Es la pieza que faltaba del patrón "preview gate": editás una foto, la mirás, y solo entonces aplicás el lote. |
| `get_develop_settings` | Lee los ajustes de revelado de una foto (`basic` = sliders comunes + curvas; `all` = todo). La mitad "antes" de cualquier comparación antes/después. |
| `reset_develop` | Resetea todo (botón Restablecer), por herramienta (recorte, transformaciones, spots, ojos rojos, curación, **todas las máscaras**…) o por parámetro individual, con diff antes/después. |
| `set_process_version` | Cambia la versión de proceso (`Version 3` = PV2012… `Version 6` = la más nueva): modernizá fotos viejas para desbloquear máscaras IA y sliders modernos. |
| `create_snapshot` | Punto de restauración con nombre (panel Instantáneas) antes de ediciones arriesgadas. |
| `select_photos` / `navigate_photo` | Controla la selección de la UI de Lightroom (por ids o modos: todo/ninguna/invertir) y navega el carrete foto por foto. |
| `get_photo_status` | Lee bandera + rating + etiqueta de color en una sola llamada (triage: "mostrame las sin bandera"). |
| `batch_metadata` | IPTC en lote (título, descripción, ubicación, ciudad, país, autor, copyright…), con verificación de lectura por foto. |
| `rotate_photo` | Rotación 90° izquierda/derecha en lote. |
| `remove_from_catalog` | Quita fotos del catálogo (NO borra archivos) — **exige `confirm: true`**. |
| `list_folders` / `list_keywords` | Inventario del catálogo: árbol de carpetas con conteos y palabras clave top con sus fotos. |
| `manage_view_filter` | Lee/establece/limpia el filtro de la vista Biblioteca (reglas = mismas que colecciones inteligentes). |
| `get_collection_photos` | Lista las fotos de una colección (incluidas las anidadas en conjuntos), paginado. |
| `create_collection_set` | Conjuntos que agrupan colecciones en el panel Catálogo. |
| `add_range_mask` | Máscaras de **rango** (luminancia/color/profundidad) con ajustes — límites honestos documentados. |
| `toggle_mask_overlay` | Prende/apaga el overlay rojo de máscaras en Revelar para revisión visual humana. |
| `search_photos` (+) | Ahora acepta `rules` avanzadas (cámara, lente, ISO, copyName, hasAdjustments…) con el mismo formato de las colecciones inteligentes. |
| `add_ai_mask` (+) | Acepta `adjustment_preset` (darken_sky, brighten_subject, blur_background, enhance_landscape) además de ajustes manuales. |
| `remove_mask` (+) | Ahora puede borrar **todas** las máscaras de una foto (`remove_all` + confirmación). |

Y **todas las herramientas originales**: `search_photos`, `get_selected_photos`, `get_photo_metadata`, `list_collections`, `create_collection`, `add_to_collection`, `set_keywords`, `set_rating`, `import_photos`, `export_photos`, `list_develop_presets`, `get_develop_preset`, `compare_develop_presets`, `create_develop_preset`, `export_develop_preset`, `apply_develop_preset`, `copy_develop_settings`, `set_develop_settings`.

---

## Instalación (Claude Desktop, paso a paso)

Hay dos formas de instalarlo; elegí una. En ambos casos el paquete **incluye el plugin de Lightroom y el harness de DeepSeek**, y después de la primera vez arranca solo.

### 1. Preparar el servidor

**Opción A — desde npm** (recomendada; requiere que el paquete esté publicado):

```powershell
npm install -g @pired/lightroom-mcp
```

**Opción B — desde el código fuente** (zip del repo):

```powershell
cd ruta\donde\descomprimiste\pired-lightroom-mcp\server
npm install
npm run build
```

> Si no tenés Node.js: descargalo de <https://nodejs.org> (LTS). Necesitás reiniciar el terminal después de instalarlo.

### 2. Instalar el plugin en Lightroom

Con la Opción A (instalación global):

```powershell
pired-lightroom-mcp install-plugin
```

Con la Opción B (desde fuente):

```powershell
node dist\index.js install-plugin
```

Eso copia el plugin a `%APPDATA%\Adobe\Lightroom\Modules\LightroomMCP.lrplugin`.

- **Instalación manual alternativa**: copiá la carpeta `plugin\LightroomMCP.lrplugin` a `%APPDATA%\Adobe\Lightroom\Modules\` (creá la carpeta `Modules` si no existe).
- Si ya tenías el `lightroom-mcp` original instalado, este lo **reemplaza** (usa los mismos puertos; no pueden convivir).

### 3. Activar el plugin en Lightroom

1. **Cerrá y volvé a abrir Lightroom Classic** (del todo: Alt+F4).
2. Menú **Archivo ▸ Administrador de complementos** (Plug-in Manager).
3. En la lista izquierda, elegí **Lightroom MCP AI**.
4. Clic en **Start Server**. Deberías ver "Server running".

### 4. Registrar el MCP en Claude Desktop

Editá el archivo de configuración de Claude Desktop:

- Ruta: `%APPDATA%\Claude\claude_desktop_config.json`

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

> Con la Opción B (fuente) usá `"command": "node"` y la ruta **absoluta** real de tu máquina (con `\\` dobles o `/`), p. ej. `C:\\ruta\\pired-lightroom-mcp\\server\\dist\\index.js`.
> Después de guardar, **reiniciá Claude Desktop** por completo.

### 5. Probarlo

Abrí Claude Desktop y escribí:

> *"Listá mis colecciones de Lightroom."*

O probá las funciones nuevas:

> *"Buscá las fotos ISO 6400 del catálogo y aplicales denoise IA a la primera."*
> *"Aplicale una máscara de sujeto a la foto 283615 con exposición +0.4 y mostrame la vista previa."*
> *"Marcá como rechazadas las fotos que tienen keyword 'descartar'."*

---

## Clientes: Claude, DeepSeek y otros

El servidor es **MCP estándar sobre stdio** — funciona con cualquier cliente MCP, no solo Claude:

| Cliente | Cómo |
| --- | --- |
| **Claude Desktop** | Configuración del paso 4 de arriba; ejemplos listos en `examples/configs/claude-desktop.json` (y dentro del paquete npm: `dist/configs/`). |
| **Claude Code** | `claude mcp add lightroom -- npx -y @pired/lightroom-mcp` (o `examples/configs/claude-code.mcp.json`). |
| **DeepSeek** | **Harness incluido**: `examples/deepseek-harness/` en el repo, o `dist/deepseek-harness/` dentro del paquete npm — script sin dependencias que conecta la API de DeepSeek con el servidor MCP y ejecuta function calling en bucle. Ver su README. |
| **Cherry Studio / 5ire / Cline / Roo Code / Cursor / Windsurf / VS Code** | Comando stdio `npx -y @pired/lightroom-mcp` (desde fuente: `node <ruta>/server/dist/index.js`); ver `examples/configs/generic-stdio-client.json`. |
| **Open WebUI / LibreChat** (MCP sobre HTTP) | Puente con `mcp-proxy --port 8808 -- npx -y @pired/lightroom-mcp`; ver `examples/configs/mcp-proxy-http.json`. |

### Verificación visual: quién puede "ver" las fotos

`get_photo_preview` adjunta el JPEG a la respuesta de la herramienta: **Claude Desktop lo ve en línea** (visión nativa) y puede autocorregigir su edición sin que intervengas. Los modelos sin visión (como `deepseek-chat`) reciben la **ruta del archivo** para que la abras tú — el patrón preview-gate sigue funcionando, pero el control de calidad lo hacés vos. Elegí en consecuencia para lotes grandes.

### Filtrar herramientas (`LIGHTROOM_MCP_TOOLS`)

Con 56 herramientas el listado consume ~8–12k tokens por turno. Para modelos o clientes con presupuesto ajustado, limitá las expuestas:

```json
"env": { "LIGHTROOM_MCP_TOOLS": "search_photos,get_photo_preview,set_develop_settings,copy_develop_settings" }
```

Los nombres desconocidos se avisan por stderr y no rompen nada; si ningún nombre coincide, se expone el set completo.

---

## Cómo funciona cada función nueva

### `ai_denoise` — denoise IA híbrido

Adobe **no expone el AI Denoise en el SDK** de Lightroom, así que la herramienta lo resuelve en dos capas:

1. **Capa nativa (IA real de Adobe)**: la herramienta selecciona la foto en la interfaz de Lightroom y ejecuta un pequeño script de PowerShell que activa la ventana de Lightroom y reproduce una secuencia de teclas que abre **Foto ▸ Mejorar…** y confirma el diálogo. El resultado es un **DNG nuevo, real**, junto al original. La herramienta vigila la carpeta hasta verlo aparecer y devuelve su `new_photo_id`.
2. **Capa de respaldo (fallback manual)**: si la capa nativa no puede verificarse (el atajo no coincide con tu idioma/menú, otra ventana robó el foco, el diálogo no se confirmó, timeout), se aplica automáticamente una reducción de ruido manual con valores inteligentes según el ISO (luminancia 35–65, color 25) y la respuesta indica exactamente qué pasó y qué se aplicó.

Configuración por llamada (`native_automation`):

| Parámetro | Default | Qué es |
| --- | --- | --- |
| `window_title` | `"Lightroom Classic"` | Título (parcial) de la ventana a activar. |
| `menu_keys` | `"%pe"` | Secuencia SendKeys que abre **Foto ▸ Mejorar…**: `%` = Alt, así que `%p` abre el menú Foto (en inglés) y `e` elige Enhance. |
| `confirm_keys` | `"{ENTER}"` | Tecla que confirma el diálogo de Mejorar. |
| `key_delay_ms` | `600` | Pausa entre las teclas del menú y la confirmación. |
| `verify_timeout_s` | `90` | Segundos máximos esperando el DNG antes de caer al fallback. |

**Consejos**:

- Mantené Lightroom en primer plano mientras se ejecuta.
- Si tu Lightroom está **en español**, el menú "Foto" puede abrirse con otra tecla: probá `menu_keys: "%fe"` o navegá con flechas (`"%f{DOWN 3}{ENTER}"`). Ajustá hasta que la primera llamada devuelva `method: "native"`.
- Solo funciona sobre archivos **RAW/DNG**; sobre JPEG/TIFF va directo al fallback manual (y te avisa).
- El `set_noise_reduction` manual es 100% confiable y no requiere foco de ventana: es tu opción "silenciosa".

### Spots (`get_spots` / `add_spots` / `clear_spots`)

Las coordenadas son **normalizadas 0..1** (x hacia la derecha, y hacia abajo; la esquina superior izquierda es `0,0`). Para convertir píxeles: `x = px / ancho`, `y = py / alto` (pedile a Claude las dimensiones con `get_photo_metadata`).

```json
{
  "photo_id": "283615",
  "spots": [
    { "x": 0.32, "y": 0.18, "radius": 0.02, "type": "heal" },
    { "x": 0.71, "y": 0.55, "radius": 0.03, "type": "clone" }
  ]
}
```

- Los spots existentes **nunca se reescriben**; los nuevos se agregan.
- Después de escribir, la herramienta **relee el estado** y te confirma si Lightroom lo aceptó. Si tu versión lo rechaza, el mensaje te sugiere dibujar un spot a mano una vez para que el formato de tu versión sirva de plantilla.
- El punto de origen (source) se calcula solo; Lightroom suele optimizarlo automáticamente.

### Máscaras locales (`add_local_adjustment` / `read_local_adjustments`)

- **Lineal (gradiente)**: `center_x`, `center_y`, `angle` (0 = el efecto crece hacia arriba, 90 = hacia la derecha), `span` (largo total del degradado).
- **Radial**: `center_x`, `center_y`, `radius_x` / `radius_y` (o `radius` para ambas), `feather`, `invert` (para afectar fuera de la elipse).
- Sliders en unidades del módulo Revelar: `exposure` en EV (-5..5), el resto -100..100 (`contrast`, `highlights`, `shadows`, `whites`, `blacks`, `clarity`, `dehaze`, `saturation`, `sharpness`, `noise_reduction`, `temperature`, `tint`).

```json
{
  "photo_id": "283615",
  "mask_type": "radial",
  "center_x": 0.5, "center_y": 0.4,
  "radius": 0.35, "feather": 60,
  "exposure": 0.7, "saturation": 15
}
```

La escritura se **verifica releyendo** la foto. Las máscaras existentes (incluidas las de IA tipo Seleccionar sujeto/cielo) no se tocan; `read_local_adjustments` te muestra exactamente cómo las guarda tu versión.

> Estado: el formato interno de máscaras no está documentado por Adobe; el handler clona la estructura que ya usa tu Lightroom y verifica la escritura. Probalo primero sobre una **copia virtual**.

### Banderas, balance de blanco y marcas de agua

- `set_flags` usa los comandos de selección de la UI y **verifica foto por foto**; si alguna quedó fuera (p. ej. no está en la fuente visible: usá "Todas las fotografías"), te lo informa e indica reintento.
- `set_white_balance` con `preset: "Auto"` calcula el blanco automático al momento (SDK 13+). En archivos no-RAW el efecto es limitado y te avisa.
- Creá tus marcas de agua en Lightroom (**Editar ▸ Editar marcas de agua…**) y después usalas por nombre: `list_watermarks` → `export_photos` con `"watermark": "Copyright Juan"`.

### Máscaras de IA (`add_ai_mask` / `list_masks` / `remove_mask`)

Usan la **API oficial de máscaras** del SDK (`LrDevelopController.createNewMask("aiSelection", …)`), la misma que usa el botón *Seleccionar sujeto* de la interfaz. La IA corre **en tu máquina** (no sube nada a la nube) y requiere Lightroom Classic 12.4+.

```json
{
  "photo_ids": ["283615"],
  "selection_type": "subject",
  "adjustments": { "exposure": 0.4, "clarity": 10, "vibrance": 15 }
}
```

- `selection_type`: `subject`, `sky`, `background`, `objects`, `people`, `landscape` (personas/paisaje dependen de la versión y del contenido de la foto).
- Los `adjustments` se aplican **a la máscara nueva** en la misma pasada (temperatura/matiz local van por `add_local_adjustment`, que maneja sus unidades propias).
- `list_masks` lista las máscaras de la foto (el formato de cada entrada varía según la versión) y `remove_mask` borra por id verificando el conteo antes/después.
- Estas herramientas **manejan el módulo Revelar por vos** (cambian a Revelar y seleccionan cada foto); Lightroom tiene que estar abierto.

### Curva tonal (`set_tone_curve` / `get_tone_curve`)

La curva se define como puntos `[x, y]` en espacio 0-255 con x estrictamente creciente; los extremos (0,0) y (255,255) **se agregan solos** si faltan (y el resultado te avisa con `endpoints_added`).

```json
{
  "photo_id": "283615",
  "channel": "main",
  "points": [[64, 56], [192, 202]]
}
```

- `channel`: `main` (luminancia) o `red` / `green` / `blue`. Sin puntos, podés pedir un `preset`: `linear`, `medium_contrast`, `strong_contrast` (aproximaciones de los nombres del dropdown de Lightroom; se guarda el nombre UI correspondiente).
- La escritura **se verifica releyendo** la curva guardada (el motor de tono puede redondear valores).

### Auto oficial (`apply_auto`)

Ejecuta los comandos **Auto Tone y/o Auto WB** del SDK — el mismo análisis que el botón *Auto* del módulo Revelar, foto por foto:

```json
{ "photo_ids": ["283615", "283616"], "operations": ["tone", "white_balance"] }
```

La respuesta incluye por foto un **diff antes/después** de los sliders principales (qué cambió y de qué valor a cuál). Si Auto no cambia nada, te lo dice (ya estaba óptimo o el tipo de archivo no lo soporta).

### Etiquetas, copias virtuales y colecciones inteligentes

- `set_color_label`: etiqueta de color por foto con verificación de lectura (tolera sets de etiquetas personalizados).
- `create_virtual_copies`: `count` copias virtuales por foto (1-20); devuelve los ids nuevos — ideales para probar ediciones sin tocar el original.
- `create_smart_collection`: reglas con el formato interno de Lightroom, combinables con `intersect` (Y) o `union` (O):

```json
{
  "name": "Lo mejor del casamiento",
  "combine": "intersect",
  "rules": [
    { "criteria": "keywords", "operation": "all", "value": "casamiento" },
    { "criteria": "rating", "operation": ">=", "value": 3 }
  ]
}
```

### Vista previa, control de estado y seguridad (v3)

- **`get_photo_preview`**: pide a Lightroom un JPEG de la foto (tamaño `small/medium/large` o píxeles exactos 32–2048). El servidor lo adjunta como imagen MCP: **Claude la ve directamente**; los clientes sin visión reciben la ruta del archivo. Se conservan las últimas 60 vistas previas (se limpian solas).
- **`get_develop_settings`** te muestra el estado (`basic`), `reset_develop` lo devuelve a cero — todo, por herramienta (`crop`, `masking`, `gradient`…) o por parámetro — y `set_process_version` moderniza fotos viejas a la versión de proceso actual (desbloquea máscaras IA y sliders nuevos).
- **`create_snapshot`** guarda un punto de restauración con nombre antes de experimentar.
- **Operaciones destructivas con confirmación explícita**: `remove_from_catalog` exige `confirm: true` (y NO borra archivos del disco); `remove_mask` con `remove_all: true` también. Un modelo no puede dispararlas por accidente.
- **`add_range_mask`** (luminancia/color/profundidad): creá la máscara de rango con ajustes; el SDK no permite fijar los límites del rango (se ajustan a mano en la UI) y la descripción de la herramienta lo advierte para que el modelo no prometa lo que no se puede.

### Selección, navegación e inventario (v3)

- `select_photos` cambia la selección de Lightroom (ids o modo `all/none/inverse/deselect_others`) — es lo que usa todo comando de UI; `navigate_photo` avanza/retrocede el carrete y te dice qué foto quedó activa.
- `get_photo_status` lee bandera/rating/etiqueta en un llamado (triage rápido); `batch_metadata` escribe IPTC en lote con verificación.
- `list_folders`, `list_keywords`, `get_collection_photos`, `create_collection_set` y `manage_view_filter` completan el inventario y la organización del catálogo.
- `search_photos` acepta `rules` avanzadas: `cameraModel`, `lens`, `isoSpeedRating`, `copyName`, `hasAdjustments`… (mismo formato que las colecciones inteligentes).

### Recetario de looks (para pedirle a Claude)

Estas recetas están calibradas a partir de las skills oficiales de Adobe para edición por lotes; combinalas con `set_develop_settings` (o presets tuyos con `apply_develop_preset`):

| Look | Receta (`set_develop_settings`) |
| --- | --- |
| **Cálido y dorado** | `Temperature` +300 sobre As Shot, `Vibrance` +15 |
| **Brillante y aireado** | `Exposure2012` +0.35, `Blacks2012` +15, `Saturation` −10, `Vibrance` +10 |
| **Sombrío y cinematográfico** | `Temperature` −200 (frío), `Saturation` −20, `Contrast2012` +25, curva `strong_contrast` |
| **Fresco y frío** | `Temperature` −400, `Vibrance` +10 |
| **Vibrante y potente** | `Vibrance` +30, `Saturation` +15, `Contrast2012` +10 |
| **Apagado tipo película** | `Saturation` −35, `Vibrance` −10, `Contrast2012` +10, `GrainAmount` 20 |

Y el toque selectivo: aplicá el look global y después un `add_ai_mask` de `subject` con `clarity: -10` para suavizar piel, o de `sky` con `exposure: -0.5` para dramatizar cielos.

### Patrón recomendado: previsualizá antes de editar en lote

Para lotes grandes, seguí el patrón de las skills oficiales de Adobe ("preview gate") — **ahora con visión real**:

1. Editá **solo la primera foto** (`set_develop_settings`, `apply_auto`, máscaras…).
2. Generá la vista previa con `get_photo_preview`: **Claude ve la imagen en la conversación** (en clientes sin visión, la respuesta incluye la ruta del JPEG para que la abras).
3. Ajustá lo que no te guste y repetí hasta aprobar.
4. Pedí **copiar los ajustes** al resto: `copy_develop_settings` de la foto modelo hacia las demás.

> Tip: creá antes un `create_snapshot` ("antes del lote") para poder volver, o una `create_virtual_copies` de prueba.

### Tabla de exportación social (recetas listas)

| Plataforma | Formato | Dimensiones | Cómo |
| --- | --- | --- | --- |
| Instagram (cuadrado) | Feed | 1080×1080 | `export_photos` con `max_width`/`max_height` 1080 |
| Instagram (vertical) | Feed / Reels | 1080×1350 / 1080×1920 | recorte 4:5 en Revelar + export |
| TikTok | Vertical | 1080×1920 | recorte 9:16 + export |
| LinkedIn | Portada/Feed | 1200×627 | export directo |
| X/Twitter | Feed | 1200×675 | export directo |
| YouTube | Miniatura | 1280×720 | export directo |
| Pinterest | Pin | 1000×1500 | recorte 2:3 + export |

> El recorte previo se puede hacer con `set_develop_settings` (claves `CropTop/CropLeft/CropBottom/CropRight`) o pidiéndole a Claude que lo calcule para la foto.

---

## Arquitectura

```
┌─────────────┐    stdio    ┌──────────────────┐  TCP :58763 →   ┌──────────────────┐
│  Claude      │ ◄─────────► │   Servidor MCP    │ ──────────────► │ Plugin Lua       │
│  Desktop     │             │  (Node/TypeScript)│ ←────────────── │ (LightroomMCP)  │
└─────────────┘             └──────────────────┘   ← TCP :58764  └──────────────────┘
                                                                          │
                                                                          ▼
                                                                catálogo (SDK de Adobe)
```

El plugin abre dos sockets `LrSocket` en localhost (58763 pedidos / 58764 respuestas) con JSON delimitado por líneas y un **token de 256 bits** (`~/.config/lightroom-mcp/token`) que autentica cada mensaje. Solo escucha en localhost: no hay superficie de ataque remota. El denoise nativo es la única parte que sale del SDK: un script PowerShell efímero en `%TEMP%` que envía pulsaciones de teclas a la ventana de Lightroom.

## Variables de entorno

| Variable | Default | Uso |
| --- | --- | --- |
| `LIGHTROOM_MCP_REQUEST_PORT` | `58763` | Puerto de pedidos del plugin. |
| `LIGHTROOM_MCP_RESPONSE_PORT` | `58764` | Puerto de respuestas del plugin. |
| `LIGHTROOM_MCP_TOKEN_PATH` | `~/.config/lightroom-mcp/token` | Archivo del token de autenticación. |
| `LIGHTROOM_MCP_TOOLS` | `all` | Subconjunto de herramientas expuestas, separadas por comas (útil para clientes/mo­delos con presupuesto de contexto ajustado, p. ej. el harness de DeepSeek). |
| `LIGHTROOM_MCP_LOCK_WAIT_MS` | `15000` | Cuánto espera una instancia nueva a que la anterior libere el candado de puertos antes de rendirse (reinicio del cliente, probe efímero). |
| `LIGHTROOM_MCP_HANDSHAKE_TIMEOUT_MS` | `5000` | Ventana para que el cliente MCP complete el handshake tras arrancar. Si nadie lo hace, el puente se cierra solo y libera el plugin (mata los "probe zombies" de clientes como Claude Desktop). `0` lo desactiva. |
| `LIGHTROOM_MCP_IDLE_YIELD_MS` | `600000` | Inactividad del cliente (sin ningún mensaje) a partir de la cual un puente **en uso** acepta cederle el candado a una instancia nueva que lo pida. `0` desactiva la cesión. |
| `LIGHTROOM_MCP_PROBE_YIELD_MS` | `10000` | Igual que el anterior, pero para un puente al que su cliente nunca le pidió una herramienta (probes/sondeos): cede mucho antes. |
| `LIGHTROOM_MCP_PLUGIN_DOWN_EXIT_MS` | `600000` | Si el plugin estuvo desconectado este tiempo (habiendo conectado antes), el puente se cierra solo para no retener el candado siendo inútil. `0` lo desactiva. |

Si cambiás puertos del lado del servidor, cambialos también en el **Administrador de complementos** para que coincidan.

## Solución de problemas

| Problema | Qué hacer |
| --- | --- |
| "Plugin not connected" | Verificá que Lightroom esté abierto con **Start Server** activado en el Administrador de complementos. Cerrá y reabrí Lightroom por completo. |
| `ai_denoise` siempre cae a `manual_fallback` | Mirá el campo `native_error` de la respuesta. Ajustá `menu_keys` a tu idioma de menú, verificá el `window_title` y que Lightroom quede en primer plano. Si quedó un diálogo abierto, cerralo. |
| `failed to open localhost:58763` tras "Recargar complemento" | Una tarea vieja retiene el puerto. Cerrá Lightroom (Alt+F4) y volvé a abrirlo. |
| **Todo da timeout justo después de "Recargar complemento"** | Hasta la v3.1.2 el reload dejaba viva la instancia anterior del módulo *con su propio token*, mientras la nueva publicaba otro en `~/.config/lightroom-mcp/token` — que es el que manda el puente. El plugin rechazaba cada mensaje en silencio (no puede responder desde `onMessage`), así que el síntoma era un timeout, o peor, el mensaje de "otro proceso retiene la conexión". El log lo delata: `Auth failed (token mismatch)` en `LightroomMCP.log`. Ya no debería pasar: el plugin acepta el token publicado y la instancia superada se aparta. Si volvés a verlo, cerrá Lightroom por completo y arrancá el servidor una sola vez (destildá "Auto-start server on Lightroom launch" si también pulsás **Start Server** a mano: son dos arranques). |
| Spots/máscaras: `applied: false` | Tu versión de Lightroom rechazó la escritura interna. Dibujá un spot o máscara a mano una vez en esa foto y reintentá: la estructura existente se usa como plantilla. |
| Timeouts en catálogos grandes | Agregá filtros (`rating`, `filename`, `keywords`, fechas) a `search_photos` para acotar el escaneo. |
| **"Another Lightroom MCP bridge is already running" / "Server disconnected" al reiniciar Claude Desktop** | Algunos clientes (Claude Desktop incluido) lanzan procesos de sondeo y reinician el puente con frecuencia; los procesos abandonados retenían el candado y quedaban zombis, de modo que las instancias siguientes fallaban. Desde la **v3.1.2** el puente se autocura en tres capas: (1) un puente cuyo archivo de candado dejó de refrescarse (builds ≤ 3.1.1 o colgado) se le roba el candado en el acto; (2) una instancia nueva que espera le pide al titular ceder el paso, y un titular sin cliente activo (nunca usado, o ≥ 10 min sin mensajes) cede y libera; (3) un puente sin conexión al plugin durante 10 min se cierra solo. Solo un puente con un cliente genuinamente activo retiene el candado, y en ese caso el mensaje de timeout nombra el pid: `Stop-Process -Id <pid> -Force` en PowerShell y reabrí el cliente. |
| Logs | Plugin: `Documentos\LrClassicLogs\LightroomMCP.log` · Claude Desktop: `%APPDATA%\Claude\Logs\mcp*.log` |

## Desarrollo

```bash
npm install && npm run build && npm test     # en server/ (TypeScript + Jest)
mise run lua:test                             # specs busted del plugin (requiere mise/lua)
node manual-test.mjs                          # sonda TCP directa (sin MCP)
```

Estructura del repo:

- `server/` — servidor MCP en TypeScript (contratos de las 56 herramientas en `src/tool-contracts.ts`).
- `plugin/LightroomMCP.lrplugin/` — plugin Lua (handlers `Handler*.lua`, dispatcher en `PluginInfoProvider.lua`).
- `examples/deepseek-harness/` — harness DeepSeek sin dependencias (MCP→function calling).
- `examples/configs/` — configuraciones listas para Claude Desktop, Claude Code, clientes stdio genéricos y puente HTTP.
- `skills/` — skill de presets incluida del proyecto original.
- `server/scripts/sync-bundle.mjs` — copia plugin + harness + configs dentro de `server/dist/` al compilar, para que el paquete npm sea autosuficiente.
- `scripts/run_lua_specs.py` — runner alternativo de los specs Lua (shim de busted sobre lupa) para entornos sin Lua.

**Agregar una herramienta nueva**:

1. Creá `Handler*.lua` en `plugin/LightroomMCP.lrplugin/`.
2. Registrala en la tabla `DISPATCH` de `PluginInfoProvider.lua`.
3. Agregá el contrato en `server/src/tool-contracts.ts` (el test de consistencia Lua↔TS lo exige).
4. Declará globals nuevas del SDK en `lightroom.yml` (selene).

## Créditos y licencia

- **@pired/lightroom-mcp** (antes *lightroom-mcp-ai*) es un fork de [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp) de Marcin Skalski, con investigación de formatos XMP basada en exiftool y en el SDK oficial de Adobe Lightroom Classic. La arquitectura de doble socket sigue el patrón de [MIDI2LR](https://github.com/rsjaffe/MIDI2LR).
- La v2.0 incorpora ideas de [znznzna/lightroom-cli](https://github.com/znznzna/lightroom-cli) (MIT): máscaras de IA vía `LrDevelopController`, Auto Tone/WB oficial y el manejo del módulo Revelar; adaptadas a las convenciones de este plugin. El recetario de looks y el patrón de previsualización se calibraron a partir de las skills oficiales de Adobe ([adobe/skills](https://github.com/adobe/skills), Apache-2.0).
- La v3.0 completa la funcionalidad con otro tanto de lightroom-cli (MIT): selección/navegación, carpetas y palabras clave, filtro de vista, metadatos en lote, rotación, snapshots, versión de proceso, resets por herramienta, máscaras de rango y presets de ajuste — más el render de vistas previas y el filtro `LIGHTROOM_MCP_TOOLS` propios de este fork.
- Licencia **MIT** — ver [LICENSE](LICENSE). El fork mantiene la atribución original.

*Hecho para fotógrafos que prefieren conversar con su catálogo. 📷*
