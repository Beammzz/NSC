// Copies the Next.js static export (out/) into the Go embed directory
// (../internal/webui/dist) so `go build` picks up the fresh webui.
import { cpSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '..', 'out');
const dist = join(here, '..', '..', 'internal', 'webui', 'dist');

if (!existsSync(out)) {
  console.error('copy-dist: out/ not found — did `next build` run?');
  process.exit(1);
}
rmSync(dist, { recursive: true, force: true });
cpSync(out, dist, { recursive: true });
console.log(`copy-dist: ${out} -> ${dist}`);
