# Las dos skills de este repo

Este servidor trae **dos skills**. No son versiones de lo mismo ni se
solapan: cubren necesidades distintas y se eligen según de dónde parte la
tarea.

| | `photo-edit-loop` | `photo-edit-advisor` |
| --- | --- | --- |
| **Responde a** | "editá estas fotos" | "¿esto está roto? ¿hasta dónde puedo subirlo?" |
| **Parte de** | Una foto que alguien quiere editar | Una medición del archivo |
| **Termina en** | Una edición aplicada y verificada | Un número y una propuesta acotada |
| **Necesita librerías** | No — solo instrucciones | Sí — `numpy` y `pillow` |
| **Verifica** | Mirando el render (`get_photo_preview`) | Midiendo sobre un export a resolución completa |
| **Invocable como** | `/lightroom-classic-ai:photo-edit-loop` | `/lightroom-classic-ai:photo-edit-advisor` |

La regla práctica: si ya sabés qué querés cambiar, usá `photo-edit-loop`. Si
no sabés cuánto se puede mover, o querés saber si un defecto es polvo,
usá `photo-edit-advisor` primero.

Ambas parten en modo **propose**: describen y esperan un sí. No aplican nada
hasta que lo piden explícitamente.

---

## photo-edit-loop

### Qué cubre

El bucle de verificar. Este servidor puede renderizar un JPEG de la foto **con
sus ediciones actuales** y adjuntarlo en línea, así que el agente puede mirar
lo que hizo en vez de asumir que funcionó. Eso solo sirve si mira, y si mira
algo confiable — y la diferencia suele ser un campo de la respuesta.

### Cuándo la necesitas

- "Subile la exposición a esta foto y decime si quedó bien"
- "Aplica este look a las 40 de la carpeta"
- "Sacá las sombras de este retrato"
- Cualquier edición donde el resultado deba verse antes de confiarse

### El bucle

1. **Mirar antes de tocar nada.** `get_photo_preview` en `large`, más
   `get_develop_settings` y `get_photo_metadata` para ver qué hay ya aplicado.
   Estas fotos llegan con perfil de cámara y contraste no nulo: proponé
   **deltas desde lo que hay**, nunca desde cero. Editar una exposición `+0.7`
   que ya está en `+0.7` no da `+1.4`.
2. **Nombrar el cambio y su número**, con qué esperás que haga.
3. **Aplicarlo.**
4. **Renderizar y mirar** en `medium`, comprobando `size_usable` primero.
5. **Decir lo que viste**, no lo que querías.
6. **Corregir o parar.** Dos pasadas suelen bastar; si la tercera no converge,
   decirlo en vez de insistir.
7. **Solo entonces, el lote.**

### La trampa: `size_usable`

```
size_usable: false
```

significa que Lightroom sirvió una rendition que **no** es la edición que
acabas de hacer: un thumbnail cacheado de antes, o el original a resolución
completa. La imagen parecerá sin cambios, y la conclusión obvia —"la
herramienta no funcionó"— es falsa. El trabajo sí ocurrió; estás mirando caché.

Antes de concluir nada de una preview:

- `size_usable` en `false` → el render no es evidencia. Re-renderizar, o leer
  los ajustes con `get_develop_settings`.
- `rendered_width` mucho mayor que `size_px` → recibiste el original. Sirve
  para composición, no para comprobar una edición.
- `rendered_width` mucho menor que `size_px` → es un thumbnail, y para una
  edición recién aplicada puede ser anterior a ella.

Si una preview contradice una edición que sabés aplicada, **creele a los
ajustes** y re-renderizá antes de volver a tocar la edición. Reaplicar un
cambio que ya entró es cómo una foto acaba graduada dos veces.

### El lote

```json
copy_develop_settings { "source_id": <aprobada>, "target_ids": [<el resto>] }
```

`target_ids` **no** debe incluir `source_id`. Copiar sobre la fuente es lo que
hace que una foto parezca doblemente graduada.

Tres cosas que muerden en lote:

- **La fuente se queda quieta.** Todo lo demás cambia respecto a ella.
- **Las herramientas en lote reportan por foto**, no todo-o-nada. `set_rating`,
  `set_flags`, `set_keywords` y `add_ai_mask` devuelven contadores
  `updated` / `missing` / `mismatching`. Un éxito parcial es el caso normal:
  una foto enmascarada falla y las otras cuarenta y nueve entran.
- **`updated: 0` con lista en `missing` significa que no coincidió nada.** No es
  un no-op silencioso: o los ids están viejos o las fotos no están en el
  catálogo.

### Verificar leyendo, no suponiendo

El valor de retorno de una escritura no es prueba. Después de cualquier cosa
que reescriba ajustes almacenados:

- `get_develop_settings` — qué se aplica, parámetro por parámetro
- `list_masks` — que la máscara existe, y su id
- `reset_develop` — devuelve un diff antes/después; ese diff es la evidencia

`add_ai_mask` en particular: la llamada underlying del SDK devuelve `nil`
incluso cuando funciona desde la UI. Nunca reportes una máscara como creada
por el valor de retorno — confirmá con `list_masks`.

### Qué tarda de verdad

| Tool | Timeout | Por qué |
| --- | --- | --- |
| `export_photos`, `import_photos`, `ai_denoise` | 300s | render en lote, o un render DNG real |
| `add_ai_mask` | 120s | IA en el dispositivo, segundos por foto |
| `add_local_adjustment`, `remove_mask` | 120s | fuerzan un recompute antes de verificar |
| `set_flags` | 120s | lotes grandes pasan por la UI, uno a uno |
| `create_virtual_copies` | 120s | medido 26–36s para 7–8 copias |

`get_photo_preview` es asíncrono: Lightroom construye las previews en segundo
plano, así que una foto nunca previsualizada puede tardar. Un primer render
lento no es un error.

### Rollback

`create_snapshot` antes de empezar, siendo honesto sobre lo que compra: el SDK
puede crear snapshots pero no listarlos ni restaurarlos, así que la persona
restaura desde el panel de Lightroom.

El rollback que **sí** podés hacer vos es `reset_develop`, y no es parcial:
`scope: "params"` con los nombres, `scope: "tools"` para crop / spots /
enmascarado / degradados, o `scope: "all"` que es el botón Reset y descarta
todo. Nombrá exactamente cuál vas a correr. Si la persona ya tenía trabajo en
el módulo Revelar antes de que empezaras, `reset_develop` es la herramienta
equivocada y hay que decirlo antes de correrla.

`create_virtual_copies` es la red de seguridad más barata cuando el riesgo es
el lote: las copias son entradas de catálogo apuntando a los mismos archivos,
así que se puede practicar y después sacarlas del catálogo sin tocar nada en
disco.

### Herramientas destructivas

`remove_from_catalog` y `remove_mask` con `remove_all: true` exigen
`confirm: true` explícito. Ese flag no es un formalismo: es lo único entre la
llamada y las entradas de catálogo borradas. Preguntá antes de ponerlo, y no
lo pongas en el mismo aliento que la propuesta.

### Detalles que cuestan un viaje de ida y vuelta

- `get_develop_settings` toma `fields: "basic" | "all"` — no `"full"`, y el
  error no lo dice. Leer el filtro completo necesita `fields: "all"` **y**
  `max_depth: 16`.
- `get_photo_preview`'s `size` toma `"small"` (240px), `"medium"` (640),
  `"large"` (1024) o píxeles exactos 32–2048.
- Las herramientas en lote toman `photo_ids` en plural;
  `get_photo_metadata`, `get_develop_settings` y `list_masks` toman `photo_id`
  singular.
- `import_photos` toma `{ "source_path": ... }` y necesita un archivo que
  Lightroom sepa leer.

---

## photo-edit-advisor

### Qué cubre

Dos mediciones que un agente **no puede hacer mirando una preview**: dónde está
el polvo, y cuánto pueden subir las sombras antes de que el ruido rompa la
foto. Las dos necesitan píxeles a resolución completa; las dos están mal si se
hacen a ojo sobre un JPEG reducido.

### Cuándo la necesitas

- "Limpiame los puntos de la foto"
- "¿Puedo subir las sombras de esta?"
- "Proponé una edición para este retrato"
- Antes de una elevación grande de exposición, para saber el techo

### Requisitos

```bash
pip install -r requirements.txt   # numpy>=1.24, pillow>=10.0 (NO scipy)
```

### Polvo: dos etapas, la segunda no es opcional

**Etapa 1 — candidatos, por foto.**

```bash
python scripts/detect_dust.py exported.jpg --crop 0.078,0.922,0,1
```

Devuelve manchas oscuras, redondas y suaves en zonas brillantes lisas. **No
distingue polvo de una piedrita oscura sobre arena clara**, y en fotos reales
las piedritas dieron más puntaje que el polvo. Tratá la salida como
candidatos, nunca como "el polvo de esta foto".

**Etapa 2 — veredicto, entre fotos.**

```bash
python scripts/correlate_dust.py manifest.json
```

```json
[{"image": "/tmp/dust/DSC02993.jpg", "scene": "falls",
  "lens": "E PZ 16-50mm F3.5-5.6 OSS", "crop": [0.078, 0.922, 0.0, 1.0]}]
```

La mugre cae en la misma coordenada del sensor en todas las fotos; lo que está
en la escena no. Un candidato solo es `persistent` si reaparece en al menos
dos **escenas distintas**.

**Las etiquetas de escena llevan todo el argumento.** Dos fotos son de la misma
escena cuando la cámara apuntaba a lo mismo, sin importar la hora. Diecisiete
minutos aparte desde un mismo punto de vista comparten horizonte y nubes, y
etiquetarlas como dos escenas convirtió cinco huecos de nube en cinco falsos
positivos confidentes en una corrida real.

Cada entrada `persistent` trae `background_similarity`. Cerca de cero es lo que
se ve desde puntos de vista independientes. Sobre 0.5 la entrada también trae
`warning`, y en la mala corrida esos valores dieron 0.67, 0.70 y 0.80. Es una
pista, no un filtro.

**Dos cosas que nunca hay que decir.** No comparar coordenadas entre
lentes distintas: Lightroom aplica un perfil de distorsión por lente antes de
exportar, y en un par medido eso movió un punto fijo radialmente hasta 0.024
del ancho del encuadre — exactamente la firma de "el punto se movió, así que
está en el objetivo". Y no llamar a un punto mugre de sensor en vez de del
objetivo: ambos son fijos en coordenadas de sensor, y distinguirlos exige
neutralizar el perfil del lente. `persistent` es la palabra honesta.

**Remoción.** El Distraction Removal (Dust) de Lightroom lo hace bien y no hay
llamada del SDK — es solo UI. Decile a la persona dónde están los puntos y que
lo corra. Para verificar después, re-exportar y correr la etapa 1 otra vez.

No intentes leer posiciones de polvo desde `FilterList`: sus cajas son teselas
de procesamiento, no puntos. Ver `reference/dust-attribution.md`.

### Ruido

```bash
python scripts/estimate_noise.py exported.jpg
```

Da ruido por banda y `headroom_stops` — cuánto pueden subir las sombras antes
de que el grano se vuelva molesto. Usalo para acotar `Exposure` y `Shadows`
**antes** de proponerlos, y cuando el headroom se agote, subir
`set_noise_reduction` luminance **junto con** la elevación, no después.

Si `headroom_stops` es `null`, la foto no tiene zona de sombra plana que
medir. Decilo; no sustituyas una estimación del ISO.

### Los límites honestos

- Los dos scripts necesitan un **export a resolución completa**, no
  `get_photo_preview`.
- El polvo solo es observable en zonas lisas y brillantes. Una foto sin cielo
  ni altas luces planas no devuelve nada, y eso no es evidencia de que no haya
  polvo.
- **Una sola foto nunca puede determinar** si una mancha es polvo.

---

## Cómo se invocan

### Desde el plugin de Claude Code

```
/lightroom-classic-ai:photo-edit-loop
/lightroom-classic-ai:photo-edit-advisor
```

### En lenguaje natural

Claude decide cargarlas por la `description` del frontmatter. Frases que
disparan cada una:

- **loop** — "subile la exposición", "aplicá este look a la carpeta", "sacale
  las sombras", "editá estas fotos"
- **advisor** — "limpiá el polvo", "cuánto puedo subir las sombras", "proponé
  una edición"

### Instalación

```bash
claude --plugin-dir /ruta/a/lightroom-mcp
```

También funcionan como skills sueltas en Claude Desktop, sin el plugin.

---

## Los evals del advisor

El advisor tiene evals; el loop no, porque el loop se verifica mirando
renderes y eso necesita Lightroom corriendo.

**Tier A** — posiciones de polvo, conteos de veredicto, orden de headroom.
Tienen respuestas correctas, medidas contra Lightroom Classic 15.4.
`scripts/run_evals.py` pasa o falla.

**Tier B** — si una propuesta editada es buena. No hay respuesta correcta; se
juzga contra `evals/rubric.md`.

Nueve casos: siete de Tier A, dos de Tier B.

**Por qué no está en CI.** Las fotos viven en el disco del fotógrafo y se
re-exportan por corrida. Empaquetar JPEGs convertiría la suite en un lock de
regresión sobre un pipeline de export y añadiría megabytes de binarios al
repo, así que `cases.json` nombra fotos por id de catálogo y ruta. Los unit
tests (`mise run skill:test`) sí corren en todas partes.

### Los cuatro criterios que hunden una propuesta

Los "below the line" — cualquiera que falle tumba la propuesta, por buena que
sea el resto:

1. **No excede el presupuesto de ruido.** Proponer dos pasos de elevación en
   una foto medida en 0.5 es lo peor que este skill puede hacer, porque la
   persona lo va a aplicar y no verá el daño hasta después.

2. **No promete lo que el SDK no puede hacer.** Ningún reclamo de máscara
   creada por el valor de retorno; ninguna promesa de correr Distraction
   Removal, que es UI-only; ningún ofrecimiento de restaurar un snapshot, que
   el SDK no puede listar ni aplicar. Decir "hacé esto en el panel Revelar"
   pasa. Decir "creé la máscara del cielo" sin `list_masks` falla.

3. **No da polvo sin confirmar por confirmado.** Un candidato de una sola foto
   es candidato. Una entrada con `background_similarity` en warning no está
   confirmada. Atribución al sensor entre lentes distintas falla.

4. **Propone deltas desde el estado real de la foto.** Una propuesta que lee
   como si todos los sliders estuvieran en cero no miró.

---

## Cómo se mantienen honestas

Ambas skills son solo instrucciones: no hay hook que intercepte una llamada.
Eso hace que **el texto sea el mecanismo**, y por eso tiene el mismo trato que
un manifiesto:

- `skills/photo-edit-loop/tests/test_skill_contract.py` — 13 tests
- `skills/photo-edit-advisor/tests/test_skill_contract.py` — 39 tests

Fallo si alguien ablanda un gate, quita `size_usable`, deja de nombrar las
herramientas mutantes, o permite que el loop se coma al advisor.

```bash
cd skills/photo-edit-loop && python -m unittest discover -s tests
```

El guard del `size_usable` está probado por el método que importa: borrando la
línea que lo afirma, el test falla. Un guard que no puede fallar no protege
nada.

### En el lado del plugin Lua

`Tool["inputSchema"]` en SDK v2 es JSON Schema crudo con la unión recursiva
`JSONValue` inlineada, que TypeScript expande eager y rechaza en cuanto ve
`oneOf`/`anyOf`/`not`. Esos son shapes válidos de `JSONValue`, así que la
fricción es del compilador, no del contrato: un cast documentado vive en
`asInputSchema()` y el schema llega al cliente byte a byte.

Y una trampa que costó tres commits: `LrTasks.execute` cede el hilo, y un
`pcall` de Lua plano es una función C — así que el yield se rechaza con
`Yielding is not allowed within a C or metamethod call`. `LrTasks.pcall` es la
llamada del SDK que sí lo permite. Los tres handlers que lanzan PowerShell lo
usan — `HandlerOrganization` (remove), `HandlerAI` (denoise) y
`HandlerAIMasks` (captura del banner) — y un spec lee el fuente de los tres
para que revertirlo falle en verde.
