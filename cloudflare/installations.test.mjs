import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const source = readFileSync(new URL('./src/index.js', import.meta.url), 'utf8');
const worker = (await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'))).default;
let writes = [];
const env = { DB: { prepare(sql) { return { bind(...params) { return { async run() { writes.push({ sql, params }); } }; } }; } } };
const report = { installationID: '00000000-0000-4000-8000-000000000001', appVersion: '8.2', osVersion: '27.0', macModel: 'Mac14,2' };
const post = body => worker.fetch(new Request('https://example.test/installations', { method: 'POST', body: JSON.stringify(body) }), env);
assert.equal((await post(report)).status, 204);
assert.equal((await post({ ...report, macModel: 'private name with spaces' })).status, 400);
assert.equal((await post({ ...report, installationID: 'bad' })).status, 400);
assert.equal((await post({ ...report, extra: 'x'.repeat(2000) })).status, 413);
assert.equal((await worker.fetch(new Request('https://example.test/installations'), env)).status, 405);
assert.equal(writes.length, 1);
const sql = writes[0].sql;
const schema = readFileSync(new URL('./schema.sql', import.meta.url), 'utf8');
const check = spawnSync('python3', ['-c', `import sqlite3,json,sys
x=json.load(sys.stdin); db=sqlite3.connect(':memory:'); db.executescript(x['schema'])
def report(v,t): db.execute(x['sql'],('id',v,'27.0','Mac14,2',t,t,t))
report('8.2','first'); report('8.2','retry')
assert db.execute('select first_seen,version_first_seen,last_reported from installations').fetchone()==('first','first','retry')
report('8.3','update')
assert db.execute('select app_version,first_seen,version_first_seen from installations').fetchone()==('8.3','first','update')
assert db.execute('select count(*) from installations').fetchone()[0]==1
`], { input: JSON.stringify({ schema, sql }), encoding: 'utf8' });
assert.equal(check.status, 0, check.stderr);
console.log('Collector validation and SQLite update/retry checks passed');
