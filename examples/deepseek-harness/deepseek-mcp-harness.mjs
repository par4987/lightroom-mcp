#!/usr/bin/env node
/**
 * deepseek-mcp-harness.mjs — usa @pired/lightroom-mcp con DeepSeek (function calling).
 *
 * Un "harness" MCP mínimo y sin dependencias: habla el protocolo MCP sobre
 * stdio (JSON-RPC) con el servidor de @pired/lightroom-mcp, convierte las
 * herramientas al formato de function-calling de la API de DeepSeek y ejecuta
 * en bucle las llamadas que el modelo pida. Solo necesita Node 18+ (fetch
 * global) y DEEPSEEK_API_KEY.
 *
 * Uso:
 *   cd pired-lightroom-mcp/server          # el servidor debe estar compilado (dist/)
 *   DEEPSEEK_API_KEY=sk-... node ../examples/deepseek-harness/deepseek-mcp-harness.mjs
 *
 *   (instalación npm: npm i -g @pired/lightroom-mcp y luego)
 *   node "$(npm root -g)/@pired/lightroom-mcp/dist/deepseek-harness/deepseek-mcp-harness.mjs"
 *
 * Variables de entorno:
 *   DEEPSEEK_API_KEY    (obligatoria)  clave de la API de DeepSeek
 *   DEEPSEEK_MODEL      (opcional)     default "deepseek-chat" (deepseek-reasoner también sirve)
 *   DEEPSEEK_BASE_URL   (opcional)     default https://api.deepseek.com
 *   LIGHTROOM_MCP_SERVER (opcional)    ruta a dist/index.js del servidor MCP
 *                                      (default: repo server/dist, dist empaquetado o npm -g)
 *   LIGHTROOM_MCP_TOOLS  (opcional)    subconjunto de herramientas expuestas, p. ej.
 *                                      "search_photos,get_photo_preview,set_develop_settings"
 *
 * Requisito previo: Lightroom Classic abierto con el plugin arrancado
 * ("Start Server" en Plug-in Manager), igual que con Claude Desktop.
 */

import { spawn, execSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

// El harness vive en dos sitios: examples/deepseek-harness/ en el repo y
// dist/deepseek-harness/ dentro del paquete npm. Probamos ambas rutas (y la
// instalación global de npm) antes de rendirnos.
const candidates = [
  process.env.LIGHTROOM_MCP_SERVER,
  path.resolve(here, "..", "..", "server", "dist", "index.js"), // repo: examples/deepseek-harness/
  path.resolve(here, "..", "index.js"),                          // npm:  dist/deepseek-harness/
].filter(Boolean);

let serverPath = candidates.find((p) => existsSync(p));
if (!serverPath) {
  // Instalación global: npm root -g → @pired/lightroom-mcp/dist/index.js
  try {
    const root = execSync("npm root -g", { encoding: "utf8" }).trim();
    const globalPath = path.join(root, "@pired", "lightroom-mcp", "dist", "index.js");
    if (existsSync(globalPath)) serverPath = globalPath;
  } catch {
    // npm no disponible en PATH — caemos al error de abajo.
  }
}

if (!serverPath) {
  console.error(`No encuentro el servidor MCP (busqué: ${candidates.join(" ; ")})`);
  console.error("Instalá el paquete (npm i -g @pired/lightroom-mcp) o compilá desde fuente (cd server && npm install && npm run build), o apunta LIGHTROOM_MCP_SERVER a dist/index.js.");
  process.exit(1);
}

if (!process.env.DEEPSEEK_API_KEY) {
  console.error("Falta DEEPSEEK_API_KEY (obtén una en https://platform.deepseek.com).");
  process.exit(1);
}

const MODEL = process.env.DEEPSEEK_MODEL || "deepseek-chat";
const BASE_URL = (process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com").replace(/\/$/, "");
const MAX_TOOL_ROUNDS = 15;

// ---------------------------------------------------------------- MCP client

const child = spawn(process.execPath, [serverPath], {
  stdio: ["pipe", "pipe", "pipe"],
  env: { ...process.env },
});

let nextId = 1;
const pending = new Map();

child.stdout.setEncoding("utf8");
readline.createInterface({ input: child.stdout }).on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    console.error(`[mcp] línea no-JSON ignorada: ${line.slice(0, 120)}`);
    return;
  }
  if (msg.id !== undefined && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) reject(new Error(msg.error.message || JSON.stringify(msg.error)));
    else resolve(msg.result);
  }
  // Las notificaciones del servidor no se usan en este harness.
});

child.stderr.setEncoding("utf8");
child.stderr.on("data", (d) => process.stderr.write(`[mcp] ${d}`));
child.on("exit", (code) => {
  console.error(`[mcp] servidor terminado (código ${code}).`);
  process.exit(code ?? 0);
});

function request(method, params) {
  const id = nextId++;
  const message = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.stdin.write(message);
  });
}

async function mcpInitialize() {
  const result = await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "deepseek-mcp-harness", version: "1.0.0" },
  });
  child.stdin.write(
    JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n",
  );
  return result;
}

async function mcpListTools() {
  return request("tools/list", {});
}

async function mcpCallTool(name, args) {
  return request("tools/call", { name, arguments: args ?? {} });
}

// ------------------------------------------------------ DeepSeek API client

async function deepseekChat(messages, tools) {
  const body = { model: MODEL, messages, stream: false };
  if (tools && tools.length > 0) {
    body.tools = tools;
    body.tool_choice = "auto";
  }
  const res = await fetch(`${BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${process.env.DEEPSEEK_API_KEY}`,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`DeepSeek API ${res.status}: ${text.slice(0, 400)}`);
  }
  return (await res.json()).choices[0].message;
}

// ------------------------------------------------------------------ helpers

/** MCP tool → formato de tools de la API de DeepSeek. */
function toDeepseekTool(tool) {
  return {
    type: "function",
    function: {
      name: tool.name,
      description: tool.description || "",
      parameters: tool.inputSchema || { type: "object", properties: {} },
    },
  };
}

/**
 * El resultado de una herramienta MCP llega como bloques de contenido. Los
 * bloques de texto se concatenan; los de imagen (get_photo_preview) se
 * anotan con su ruta porque deepseek-chat no acepta imágenes — el humano
 * las abre desde el path mientras decide si continuar con el lote.
 */
function toolResultToText(content) {
  const parts = [];
  for (const block of content ?? []) {
    if (block.type === "text") {
      parts.push(block.text);
    } else if (block.type === "image") {
      parts.push(
        "[El servidor adjuntó una imagen de la vista previa. Ábrela desde la ruta " +
          "indicada arriba para revisarla antes de aplicar el lote.]",
      );
    }
  }
  return parts.join("\n") || "(sin salida)";
}

const SYSTEM_PROMPT = `Eres un asistente de edición fotográfica que controla Adobe Lightroom
Classic a través de un servidor MCP local (@pired/lightroom-mcp). Trabajo con fotos reales
del catálogo del usuario: antes de tocar un lote grande, aplica el patrón "preview gate":

1. Busca o selecciona las fotos (search_photos / get_selected_photos).
2. Edita UNA foto de muestra (set_develop_settings, add_ai_mask, apply_develop_preset, ...).
3. Genera la vista previa (get_photo_preview) y dile al usuario qué archivo abrir
   para revisar el resultado antes de continuar.
4. Solo tras la aprobación, aplica los mismos ajustes al resto con copy_develop_settings.

Consejos: los ids de foto vienen como números; reutilízalos tal cual. Para máscaras
IA necesitas Lightroom Classic 12.4+. get_develop_settings (fields=basic) muestra el
estado actual. create_snapshot guarda un punto de restauración antes de cambios
arriesgados. Nunca llames a remove_from_catalog sin pedírselo explícitamente al
usuario. Responde en el idioma del usuario.`;

// -------------------------------------------------------------------- main

async function main() {
  console.error(`[harness] arrancando servidor MCP: ${serverPath}`);
  const init = await mcpInitialize();
  const toolsResult = await mcpListTools();
  const mcpTools = toolsResult.tools ?? [];
  const deepseekTools = mcpTools.map(toDeepseekTool);

  console.error(
    `[harness] MCP ${init.serverInfo?.name} v${init.serverInfo?.version} — ` +
      `${mcpTools.length} herramientas expuestas${process.env.LIGHTROOM_MCP_TOOLS ? " (filtradas)" : ""}.`,
  );
  console.error(`[harness] modelo: ${MODEL} — escribe tu instrucción, o "salir" para terminar.\n`);

  const messages = [{ role: "system", content: SYSTEM_PROMPT }];

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = () =>
    new Promise((resolve) => rl.question("tú > ", (answer) => resolve(answer.trim())));

  while (true) {
    const input = await ask();
    if (input === "") continue;
    if (input === "salir" || input === "exit" || input === "quit") break;

    messages.push({ role: "user", content: input });

    try {
      for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
        const message = await deepseekChat(messages, deepseekTools);
        messages.push(message);

        const calls = message.tool_calls ?? [];
        if (calls.length === 0) {
          console.log(`\nDeepSeek > ${message.content ?? "(sin texto)"}\n`);
          break;
        }

        for (const call of calls) {
          const name = call.function.name;
          let args = {};
          try {
            args = JSON.parse(call.function.arguments || "{}");
          } catch {
            args = {};
          }
          const argsPreview = JSON.stringify(args);
          process.stdout.write(
            `  -> ${name}(${argsPreview.length > 160 ? argsPreview.slice(0, 160) + "…" : argsPreview}) `,
          );
          const result = await mcpCallTool(name, args);
          const text = toolResultToText(result.content);
          const failed = result.isError === true;
          console.log(failed ? "✗" : "✓");
          messages.push({
            role: "tool",
            tool_call_id: call.id,
            content: failed ? `ERROR: ${text}` : text.slice(0, 12000),
          });
        }
      }
    } catch (err) {
      console.error(`[harness] error: ${err.message}`);
      messages.push({
        role: "user",
        content: `(Nota del sistema: la última llamada falló con "${err.message}". Avisa al usuario y continúa con cuidado.)`,
      });
    }
  }

  rl.close();
  child.stdin.end();
}

main().catch((err) => {
  console.error(`[harness] fatal: ${err.message}`);
  process.exit(1);
});
