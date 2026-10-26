// Run with Bun from the web checkout so its TypeScript aliases resolve.
// bun /path/to/gsd-iosapp/scripts/verify-saved-sync.mjs /path/to/web /path/to/pocketbase
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readdir, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';

const [webPath, binaryPath] = process.argv.slice(2);
assert(webPath && binaryPath, 'Supply the web checkout and PocketBase binary paths');
const web = resolve(webPath);
const ios = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const requireWeb = createRequire(join(web, 'package.json'));
const PocketBase = requireWeb('pocketbase/cjs');
const { taskRecordToPocketBase, pocketBaseToTaskRecord } = await import(pathToFileURL(join(web, 'lib/sync/task-mapper.ts')).href);
const scratch = await mkdtemp(join(tmpdir(), 'gsd-native-saved-'));
const migrations = join(scratch, 'migrations');
const data = join(scratch, 'data');
const adminEmail = 'saved-admin@example.test';
const password = randomBytes(24).toString('hex');
const environment = { ...process.env, GSD_TASKS_ENC_KEY: randomBytes(16).toString('hex') };
let backend;
const run = (binary, args, options = {}) => {
  const result = spawnSync(binary, args, { cwd: web, env: environment, encoding: 'utf8', ...options });
  if (result.status !== 0) throw new Error(`${binary} failed: ${result.stderr || result.stdout || result.error}`);
  return result;
};

try {
  await mkdir(migrations);
  for (const source of ['docker/pb_migrations', 'docker/pb_fresh_migrations']) {
    for (const name of await readdir(join(web, source))) {
      if (name.endsWith('.js')) await copyFile(join(web, source, name), join(migrations, name));
    }
  }
  const listener = createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const url = `http://127.0.0.1:${port}`;
  const shared = [`--dir=${data}`, '--automigrate=false', `--hooksDir=${join(web, 'docker/pb_hooks')}`, `--migrationsDir=${migrations}`];
  run(binaryPath, ['superuser', 'upsert', adminEmail, password, `--dir=${data}`]);
  run(binaryPath, ['migrate', 'up', ...shared]);
  backend = spawn(binaryPath, ['serve', ...shared, `--http=127.0.0.1:${port}`], { cwd: web, env: environment, stdio: 'ignore' });
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { if ((await fetch(`${url}/api/health`)).ok) { ready = true; break; } } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(ready, 'Local PocketBase did not become healthy');
  const admin = new PocketBase(url);
  await admin.collection('_superusers').authWithPassword(adminEmail, password);
  let collections = await admin.collections.getFullList();
  if (!collections.some(c => c.name === 'users')) {
    await admin.collections.create({ name: 'users', type: 'auth', authRule: '',
      listRule: 'id = @request.auth.id', viewRule: 'id = @request.auth.id',
      updateRule: 'id = @request.auth.id', deleteRule: 'id = @request.auth.id',
      passwordAuth: { enabled: true, identityFields: ['email'] } });
  }
  if (!collections.some(c => c.name === 'tasks')) {
    run('bash', ['scripts/setup-pocketbase-collections.sh'], { env: { ...environment,
      PB_URL: url, PB_ADMIN_EMAIL: adminEmail, PB_ADMIN_PASSWORD: password } });
  }
  await admin.collection('users').create({ email: 'saved-owner@example.test', password, passwordConfirm: password, verified: true });
  const user = new PocketBase(url);
  const session = await user.collection('users').authWithPassword('saved-owner@example.test', password);
  const stamp = new Date(Date.now() - 60_000).toISOString();
  const task = { id: 'native-saved-e2e', title: 'Read later', description: 'Created by the web client',
    urgent: false, important: true, quadrant: 'not-urgent-important', completed: false,
    createdAt: stamp, updatedAt: stamp, savedAt: stamp, recurrence: 'none', tags: ['reading'],
    subtasks: [], dependencies: [], timeEntries: [] };
  await user.collection('tasks').create(taskRecordToPocketBase(task, session.record.id, 'web-saved-test'));
  const test = run('swift', ['test', '--filter', 'SavedPocketBaseSystemTests'], { cwd: join(ios, 'GSDKit'),
    env: { ...environment, GSD_SAVED_PB_URL: url, GSD_SAVED_PB_TOKEN: session.token } });
  process.stdout.write(test.stdout);
  const rows = await user.collection('tasks').getFullList();
  assert.equal(rows.length, 1);
  const mapped = pocketBaseToTaskRecord(rows[0]);
  assert(mapped && mapped.savedAt);
  assert.equal(mapped.id, task.id);
  assert.equal(mapped.description, 'Native annotation 😀');
  assert.equal(mapped.urgent, true);
  assert.equal(mapped.important, true);
  console.log('PASS: web create → native pull/notes/return/save → web read; one identity, encrypted hooks, owner auth');
} finally {
  if (backend && backend.exitCode === null) {
    backend.kill('SIGTERM');
    await new Promise(resolve => backend.once('exit', resolve));
  }
  await rm(scratch, { recursive: true, force: true });
}
