import { createReadStream } from "node:fs";
import { access, readFile, stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { argv, cwd } from "node:process";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";

type RuntimeConfig = {
  port: number;
  staticDir: string;
  appUrl?: string;
  allowOnlyLocalhostControl: boolean;
};

const DEFAULT_PORT = 4174;
const HEALTH_PATH = "/health";

const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
};

function parseArg(name: string): string | undefined {
  const idx = argv.findIndex((entry) => entry === name);
  if (idx === -1) {
    return undefined;
  }

  const next = argv[idx + 1];
  if (!next || next.startsWith("--")) {
    return undefined;
  }

  return next;
}

function getConfigPath(): string {
  const cliConfig = parseArg("--config");
  if (cliConfig) {
    return cliConfig;
  }

  return process.env.PARSEBOX_CONFIG ?? join(process.env.HOME ?? cwd(), ".parsebox", "config.json");
}

async function pathExists(pathname: string): Promise<boolean> {
  try {
    await access(pathname);
    return true;
  } catch {
    return false;
  }
}

async function loadConfig(configPath: string): Promise<RuntimeConfig> {
  const rootDir = resolve(fileURLToPath(new URL("..", import.meta.url)));
  const defaults: RuntimeConfig = {
    port: DEFAULT_PORT,
    staticDir: join(rootDir, "kiosk"),
    allowOnlyLocalhostControl: true,
  };

  if (!(await pathExists(configPath))) {
    return defaults;
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(await readFile(configPath, "utf8")) as Record<string, unknown>;
  } catch (error) {
    throw new Error(`Invalid config JSON at ${configPath}: ${String(error)}`);
  }

  const merged: RuntimeConfig = {
    ...defaults,
    ...parsed,
  } as RuntimeConfig;

  if (!Number.isInteger(merged.port) || merged.port < 1 || merged.port > 65535) {
    throw new Error(`Invalid port in config: ${merged.port}`);
  }

  if (typeof merged.staticDir !== "string" || merged.staticDir.trim().length === 0) {
    throw new Error("Invalid staticDir in config.");
  }

  if (typeof merged.allowOnlyLocalhostControl !== "boolean") {
    throw new Error("Invalid allowOnlyLocalhostControl in config.");
  }

  return {
    ...merged,
    staticDir: resolve(merged.staticDir),
  };
}

function json(res: ServerResponse, statusCode: number, payload: Record<string, unknown>): void {
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(payload));
}

function isLocalhostAddress(address?: string | null): boolean {
  if (!address) {
    return false;
  }

  return (
    address === "127.0.0.1" ||
    address === "::1" ||
    address === "::ffff:127.0.0.1"
  );
}

function runPowerCommand(command: "reboot" | "poweroff"): Promise<void> {
  return new Promise((resolvePromise, rejectPromise) => {
    execFile("/usr/bin/sudo", ["/usr/bin/systemctl", command], (error) => {
      if (error) {
        rejectPromise(error);
        return;
      }

      resolvePromise();
    });
  });
}

function parsePathname(req: IncomingMessage): string {
  const reqUrl = req.url ?? "/";
  return new URL(reqUrl, "http://127.0.0.1").pathname;
}

function safeStaticPath(root: string, pathname: string): string {
  const decodedPath = decodeURIComponent(pathname);
  const normalized = normalize(decodedPath).replace(/^([/\\])+/, "");
  return join(root, normalized);
}

async function serveStaticFile(root: string, pathname: string, res: ServerResponse): Promise<void> {
  const requestedPath = safeStaticPath(root, pathname);
  const resolvedPath = resolve(requestedPath);
  const rootWithSep = root.endsWith("/") ? root : `${root}/`;

  if (resolvedPath !== root && !resolvedPath.startsWith(rootWithSep)) {
    json(res, 403, { error: "Forbidden" });
    return;
  }

  let fileStat;
  try {
    fileStat = await stat(resolvedPath);
  } catch {
    fileStat = null;
  }

  let finalFilePath = resolvedPath;
  if (!fileStat || fileStat.isDirectory()) {
    finalFilePath = join(root, "index.html");
    try {
      fileStat = await stat(finalFilePath);
    } catch {
      json(res, 404, { error: "Not Found" });
      return;
    }
  }

  if (!fileStat.isFile()) {
    json(res, 404, { error: "Not Found" });
    return;
  }

  const ext = extname(finalFilePath).toLowerCase();
  const contentType = MIME_TYPES[ext] ?? "application/octet-stream";

  res.writeHead(200, {
    "Content-Type": contentType,
    "Content-Length": String(fileStat.size),
  });

  createReadStream(finalFilePath).pipe(res);
}

async function main(): Promise<void> {
  const configPath = getConfigPath();
  const config = await loadConfig(configPath);

  if (!(await pathExists(config.staticDir))) {
    throw new Error(`Static directory does not exist: ${config.staticDir}`);
  }

  const server = createServer(async (req, res) => {
    const method = req.method ?? "GET";
    const pathname = parsePathname(req);

    if (method === "GET" && pathname === HEALTH_PATH) {
      json(res, 200, {
        status: "ok",
        uptimeSeconds: Math.floor(process.uptime()),
        staticDir: config.staticDir,
      });
      return;
    }

    if (method === "POST" && pathname === "/api/system/reboot") {
      if (config.allowOnlyLocalhostControl && !isLocalhostAddress(req.socket.remoteAddress)) {
        json(res, 403, { error: "Control endpoint is localhost-only." });
        return;
      }

      try {
        await runPowerCommand("reboot");
      } catch (error) {
        json(res, 500, { error: `Failed to reboot: ${String(error)}` });
        return;
      }

      json(res, 200, { ok: true, action: "reboot" });
      return;
    }

    if (method === "POST" && pathname === "/api/system/shutdown") {
      if (config.allowOnlyLocalhostControl && !isLocalhostAddress(req.socket.remoteAddress)) {
        json(res, 403, { error: "Control endpoint is localhost-only." });
        return;
      }

      try {
        await runPowerCommand("poweroff");
      } catch (error) {
        json(res, 500, { error: `Failed to shutdown: ${String(error)}` });
        return;
      }

      json(res, 200, { ok: true, action: "shutdown" });
      return;
    }

    if (method !== "GET" && method !== "HEAD") {
      json(res, 405, { error: "Method Not Allowed" });
      return;
    }

    await serveStaticFile(config.staticDir, pathname, res);
  });

  server.on("clientError", () => {
    // Ignore malformed clients; kiosk networking can be noisy on boot.
  });

  server.listen(config.port, "0.0.0.0", () => {
    console.log(
      JSON.stringify({
        event: "parsebox-server-started",
        port: config.port,
        staticDir: config.staticDir,
        configPath,
      }),
    );
  });

  const shutdown = () => {
    server.close(() => {
      process.exit(0);
    });
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((error) => {
  console.error(`[parsebox-server] ${String(error)}`);
  process.exit(1);
});
