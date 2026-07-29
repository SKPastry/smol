import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const rootDirectory = path.resolve(scriptDirectory, '..');
const upstreamDirectory = path.join(rootDirectory, 'web/slimenrf-ota-web');
const upstreamDist = path.join(upstreamDirectory, 'dist');
const commandDist = path.join(rootDirectory, 'web/slimenrf-remote-command/dist');
const commandTarget = path.join(upstreamDist, 'commands');
const indexPath = path.join(upstreamDist, 'index.html');
const wranglerPath = path.join(upstreamDirectory, 'wrangler.toml');
const functionsPath = path.join(upstreamDirectory, 'functions');

const marker = '<!-- smol-remote-command-nav -->';
const insertionPoint = '        <!-- Language switcher -->';
const navigation = [
  `        ${marker}`,
  '        <a href="/commands/" class="btn btn-ghost btn-sm" aria-label="Remote Commands">',
  '          <svg class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M8 9h8M8 15h5"/><path d="M5 3h14a2 2 0 0 1 2 2v14l-4-3H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"/></svg>',
  '          <span class="hidden sm:inline">Commands</span>',
  '        </a>',
].join('\n');

function fail(message) {
  throw new Error(`[compose-web] ${message}`);
}

for (const required of [
  [indexPath, 'upstream dist/index.html'],
  [path.join(commandDist, 'index.html'), 'command dist/index.html'],
  [wranglerPath, 'upstream wrangler.toml'],
  [functionsPath, 'upstream Pages Functions'],
]) {
  if (!existsSync(required[0])) fail(`missing ${required[1]}`);
}

let indexHtml = readFileSync(indexPath, 'utf8');
if (indexHtml.includes(marker)) fail('navigation marker already exists before composition');
const insertionMatches = indexHtml.split(insertionPoint).length - 1;
if (insertionMatches !== 1) {
  fail(`expected exactly one navigation insertion point, found ${insertionMatches}`);
}

const commandIndex = readFileSync(path.join(commandDist, 'index.html'), 'utf8');
const commandReferences = [
  ...commandIndex.matchAll(/\b(?:href|src)="\.\/([^"]+)"/g),
].map((match) => match[1].split(/[?#]/, 1)[0]);
if (commandReferences.length === 0) fail('command page contains no relative build assets');
for (const reference of commandReferences) {
  const resolvedReference = path.resolve(commandDist, reference);
  if (!resolvedReference.startsWith(`${commandDist}${path.sep}`)) {
    fail(`command build asset escapes its dist directory: ${reference}`);
  }
  if (!existsSync(resolvedReference)) {
    fail(`missing command build asset: ${reference}`);
  }
}

if (existsSync(commandTarget)) {
  if (lstatSync(commandTarget).isSymbolicLink()) {
    fail('refusing to replace a symbolic-link commands target');
  }
  rmSync(commandTarget, { recursive: true });
}
mkdirSync(commandTarget, { recursive: true });
cpSync(commandDist, commandTarget, { recursive: true });

indexHtml = indexHtml.replace(insertionPoint, `${navigation}\n${insertionPoint}`);
if (indexHtml.split(marker).length - 1 !== 1) {
  fail('navigation injection did not produce exactly one marker');
}
writeFileSync(indexPath, indexHtml);

console.log('[compose-web] copied the remote command page to dist/commands/');
console.log('[compose-web] injected the generated OTA navigation entry');
