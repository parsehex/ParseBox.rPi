import { createReadStream } from "node:fs";
import { access, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { argv, cwd } from "node:process";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";

type RuntimeConfig = {
  port: number;
  controlsPort: number;
  staticDir: string;
  appUrl?: string;
  currentAppId?: string;
  allowOnlyLocalhostControl: boolean;
};

type AppTarget = {
  id: string;
  name: string;
  staticDir: string;
  appUrl: string;
  appUrlPath: string;
  splashImage?: string;
  splashThemeId?: string;
};

const DEFAULT_PORT = 4174;
const DEFAULT_CONTROLS_PORT = 4175;
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
    controlsPort: DEFAULT_CONTROLS_PORT,
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

  if (!Number.isInteger(merged.controlsPort) || merged.controlsPort < 1 || merged.controlsPort > 65535) {
    throw new Error(`Invalid controlsPort in config: ${merged.controlsPort}`);
  }

  if (typeof merged.staticDir !== "string" || merged.staticDir.trim().length === 0) {
    throw new Error("Invalid staticDir in config.");
  }

  if (typeof merged.allowOnlyLocalhostControl !== "boolean") {
    throw new Error("Invalid allowOnlyLocalhostControl in config.");
  }

  if (merged.currentAppId !== undefined && typeof merged.currentAppId !== "string") {
    throw new Error("Invalid currentAppId in config.");
  }

  return {
    ...merged,
    staticDir: resolve(merged.staticDir),
  };
}

function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

function getHomeDir(configPath: string): string {
  return dirname(dirname(configPath));
}

function configPathForHome(homeDir: string): string {
  return join(homeDir, ".parsebox", "config.json");
}

function ensureAbsolutePath(pathname: string): string {
  return resolve(pathname);
}

async function parseJsonFile(pathname: string): Promise<Record<string, unknown> | null> {
  try {
    const text = await readFile(pathname, "utf8");
    const parsed = JSON.parse(text) as Record<string, unknown>;
    return parsed;
  } catch {
    return null;
  }
}

async function listInstalledTargets(config: RuntimeConfig, configPath: string, rootDir: string): Promise<AppTarget[]> {
  const homeDir = getHomeDir(configPath);
  const metadataDir = join(homeDir, ".parsebox", "apps");
  const appUrlBase = `http://127.0.0.1:${config.port}`;
  const targets = new Map<string, AppTarget>();

  const parseboxTarget: AppTarget = {
    id: "parsebox-kiosk",
    name: "ParseBox Kiosk",
    staticDir: join(rootDir, "kiosk"),
    appUrl: `${appUrlBase}/`,
    appUrlPath: "/",
    splashImage: join(rootDir, "resources", "parsebox-splash.svg"),
    splashThemeId: "parsebox",
  };
  targets.set(parseboxTarget.id, parseboxTarget);

  if (await pathExists(metadataDir)) {
    const entries = await readdir(metadataDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) {
        continue;
      }

      const parsed = await parseJsonFile(join(metadataDir, entry.name));
      if (!parsed) {
        continue;
      }

      const id = typeof parsed.id === "string" ? slugify(parsed.id) : slugify(entry.name.replace(/\.json$/, ""));
      const name = typeof parsed.name === "string" && parsed.name.trim() ? parsed.name.trim() : id;
      const staticDirRaw = typeof parsed.staticDir === "string" ? parsed.staticDir : "";
      if (!staticDirRaw) {
        continue;
      }

      const appUrlPath =
        typeof parsed.appUrlPath === "string" && parsed.appUrlPath.trim()
          ? parsed.appUrlPath
          : "/";
      const normalizedPath = appUrlPath.startsWith("/") ? appUrlPath : `/${appUrlPath}`;

      const target: AppTarget = {
        id,
        name,
        staticDir: ensureAbsolutePath(staticDirRaw),
        appUrl: `${appUrlBase}${normalizedPath}`,
        appUrlPath: normalizedPath,
      };

      if (typeof parsed.splashImage === "string" && parsed.splashImage.trim()) {
        target.splashImage = ensureAbsolutePath(parsed.splashImage);
      }

      if (typeof parsed.splashThemeId === "string" && parsed.splashThemeId.trim()) {
        target.splashThemeId = slugify(parsed.splashThemeId);
      }

      targets.set(target.id, target);
    }
  }

  return [...targets.values()];
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

function runSudoCommand(command: string, args: string[]): Promise<void> {
  return new Promise((resolvePromise, rejectPromise) => {
    execFile("/usr/bin/sudo", [command, ...args], (error) => {
      if (error) {
        rejectPromise(error);
        return;
      }

      resolvePromise();
    });
  });
}

function readRequestBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolvePromise, rejectPromise) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => {
      chunks.push(Buffer.from(chunk));
    });
    req.on("end", () => {
      resolvePromise(Buffer.concat(chunks).toString("utf8"));
    });
    req.on("error", (error) => {
      rejectPromise(error);
    });
  });
}

async function parseRequestJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const body = await readRequestBody(req);
  if (!body.trim()) {
    return {};
  }

  return JSON.parse(body) as Record<string, unknown>;
}

async function writeRuntimeConfig(configPath: string, config: RuntimeConfig): Promise<void> {
  await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
}

async function rewriteXinitrcAppUrl(homeDir: string, appUrl: string): Promise<void> {
  const xinitrcPath = join(homeDir, ".xinitrc");
  if (!(await pathExists(xinitrcPath))) {
    return;
  }

  const current = await readFile(xinitrcPath, "utf8");
  const next = current.replace(/--app="[^"]+"/g, `--app="${appUrl}"`);
  if (next !== current) {
    await writeFile(xinitrcPath, next, "utf8");
  }
}

async function maybeSwitchSplash(target: AppTarget): Promise<{ attempted: boolean; updated: boolean; warning?: string }> {
  const markerFile = "/etc/parsebox/splash-enabled";
  const helperPath = "/usr/local/bin/parsebox-install-plymouth-theme";

  if (!(await pathExists(markerFile))) {
    return { attempted: false, updated: false, warning: "Splash marker is not enabled." };
  }

  if (!(await pathExists(helperPath))) {
    return { attempted: false, updated: false, warning: "Splash helper is missing." };
  }

  if (!target.splashImage || !(await pathExists(target.splashImage))) {
    return { attempted: true, updated: false, warning: "Selected target has no splash asset." };
  }

  try {
    await runSudoCommand(helperPath, [
      "--theme-id",
      target.splashThemeId ?? target.id,
      "--theme-name",
      target.name,
      "--image",
      target.splashImage,
      "--marker-file",
      markerFile,
    ]);
    return { attempted: true, updated: true };
  } catch (error) {
    return { attempted: true, updated: false, warning: `Failed to update splash: ${String(error)}` };
  }
}

async function switchTarget(target: AppTarget, configPath: string, current: RuntimeConfig): Promise<{ splash: { attempted: boolean; updated: boolean; warning?: string } }> {
  const homeDir = getHomeDir(configPath);
  const nextConfig: RuntimeConfig = {
    ...current,
    staticDir: target.staticDir,
    appUrl: target.appUrl,
    currentAppId: target.id,
  };

  await writeRuntimeConfig(configPath, nextConfig);
  await rewriteXinitrcAppUrl(homeDir, target.appUrl);
  const splash = await maybeSwitchSplash(target);
  await runSudoCommand("/usr/bin/systemctl", ["restart", "getty@tty1.service"]);
  return { splash };
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
  const rootDir = resolve(fileURLToPath(new URL("..", import.meta.url)));
  let config = await loadConfig(configPath);
  const controlsPagePath = join(rootDir, "kiosk", "index.html");

  if (!(await pathExists(config.staticDir))) {
    throw new Error(`Static directory does not exist: ${config.staticDir}`);
  }

  const handleRequest = (resolveStaticRoot: () => string) => async (req: IncomingMessage, res: ServerResponse) => {
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

    if (method === "GET" && (pathname === "/controls" || pathname === "/controls/")) {
      await serveStaticFile(rootDir, "/kiosk/index.html", res);
      return;
    }

    if (method === "GET" && pathname === "/api/apps") {
      if (config.allowOnlyLocalhostControl && !isLocalhostAddress(req.socket.remoteAddress)) {
        json(res, 403, { error: "Control endpoint is localhost-only." });
        return;
      }

      const targets = await listInstalledTargets(config, configPath, rootDir);
      json(res, 200, {
        currentAppId: config.currentAppId ?? null,
        apps: targets,
      });
      return;
    }

    if (method === "POST" && pathname === "/api/apps/switch") {
      if (config.allowOnlyLocalhostControl && !isLocalhostAddress(req.socket.remoteAddress)) {
        json(res, 403, { error: "Control endpoint is localhost-only." });
        return;
      }

      let body: Record<string, unknown>;
      try {
        body = await parseRequestJson(req);
      } catch {
        json(res, 400, { error: "Invalid JSON body." });
        return;
      }

      const appId = typeof body.appId === "string" ? slugify(body.appId) : "";
      if (!appId) {
        json(res, 400, { error: "appId is required." });
        return;
      }

      const targets = await listInstalledTargets(config, configPath, rootDir);
      const target = targets.find((entry) => entry.id === appId);
      if (!target) {
        json(res, 404, { error: `Unknown app target: ${appId}` });
        return;
      }

      if (!(await pathExists(target.staticDir))) {
        json(res, 400, { error: `Target static directory missing: ${target.staticDir}` });
        return;
      }

      try {
        const result = await switchTarget(target, configPath, config);
        config = await loadConfig(configPath);
        json(res, 200, {
          ok: true,
          appId: target.id,
          appUrl: target.appUrl,
          splash: result.splash,
        });
      } catch (error) {
        json(res, 500, { error: `Failed to switch target: ${String(error)}` });
      }
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

    await serveStaticFile(resolveStaticRoot(), pathname, res);
  };

  const appServer = createServer(handleRequest(() => config.staticDir));
  const controlsServer =
    config.controlsPort === config.port
      ? null
      : createServer(handleRequest(() => join(rootDir, "kiosk")));

  appServer.on("clientError", () => {
    // Ignore malformed clients; kiosk networking can be noisy on boot.
  });

  if (controlsServer) {
    controlsServer.on("clientError", () => {
      // Ignore malformed clients; kiosk networking can be noisy on boot.
    });
  }

  appServer.listen(config.port, "0.0.0.0", () => {
    console.log(
      JSON.stringify({
        event: "parsebox-server-started",
        port: config.port,
        controlsPort: config.controlsPort,
        staticDir: config.staticDir,
        controlsPagePath,
        configPath,
      }),
    );
  });

  if (controlsServer) {
    controlsServer.listen(config.controlsPort, "0.0.0.0", () => {
      console.log(
        JSON.stringify({
          event: "parsebox-controls-server-started",
          controlsPort: config.controlsPort,
          controlsPagePath,
        }),
      );
    });
  }

  const shutdown = () => {
    appServer.close(() => {
      if (!controlsServer) {
        process.exit(0);
        return;
      }

      controlsServer.close(() => {
        process.exit(0);
      });
    });
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((error) => {
  console.error(`[parsebox-server] ${String(error)}`);
  process.exit(1);
});
