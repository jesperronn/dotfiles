#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/bin/lib/bash_test.sh"
TEST_TMP_DIR="$(mktemp -d)"
cleanup_test_tmp() { rm -rf "$TEST_TMP_DIR"; }
trap 'cleanup_test_tmp' EXIT

test_config_contract() {
  node --input-type=module - "$ROOT/bin/apicall" "$TEST_TMP_DIR" <<'JS'
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readFileSync, writeFileSync, statSync} from 'node:fs';
import {join} from 'node:path';
const [bin,tmp]=process.argv.slice(2);
const config=join(tmp,'config.toml');
const run=(...args)=>spawnSync(process.execPath,[bin,...args],{encoding:'utf8',env:{...process.env,APICALL_CONFIG:config}});
let r=run('--help'); assert.equal(r.status,0,r.stderr); assert.match(r.stdout,/setup/);
r=run('list'); assert.equal(r.status,1); assert.match(r.stderr,/apicall setup/);
r=run('setup'); assert.equal(r.status,0,r.stderr); assert.equal(statSync(config).mode&0o777,0o600);
const template=readFileSync(config,'utf8'); assert.match(template,/#/); assert.match(template,/credential_policy/);
assert.equal(run('setup').status,1); assert.equal(readFileSync(config,'utf8'),template);
assert.equal(run('validate').status,0);
writeFileSync(config,`version = 1 # schema
[services.demo]
api_path = "/api"
[services.demo.headers]
"X-Label" = "a # b"
[services.demo.auth]
type = "basic"
credential_policy = "env"
[services.demo.auth.username]
env = "DEMO_{ENV}_USER"
[services.demo.auth.password]
env = "DEMO_{ENV}_PASS"
[services.demo.environments.prod]
origin = "https://{env}.example.test"
[services.demo.environments.prod.headers]
"x-label" = "override"
`);
assert.equal(run('validate').status,0);
assert.equal(run('list').stdout.trim(),'demo');
assert.equal(run('environments','demo').stdout.trim(),'prod');
r=run('describe','demo','prod'); assert.equal(r.status,0,r.stderr); assert.match(r.stdout,/DEMO_PROD_USER/); assert.match(r.stdout,/https:\/\/prod.example.test/);
assert.equal(JSON.parse(r.stdout).headers['x-label'],'override');
assert.equal(Object.keys(JSON.parse(r.stdout).headers).length,1);
assert.match(run('environments','missing').stderr,/demo/);
const valid=readFileSync(config,'utf8');
for(const [bad,pattern] of [
 ['unknown = "bad"\n'+valid,/unknown/i],
 [valid.replace('version = 1','version = 2'),/version/],
 [valid.replace('api_path = "/api"','api_path = ["/api"]'),/Unsupported/],
 [valid+'\n[services.demo]\n',/Duplicate/],
 [valid.replace('{ENV}','{unknown}'),/placeholder/],
 [valid.replace('https://{env}.example.test','https://example.test/path'),/origin/],
 [valid.replace('env = "DEMO_{ENV}_USER"','env = "A"\nenv = "B"'),/duplicate/i]
]) { writeFileSync(config,bad); r=run('validate'); assert.equal(r.status,1,bad); assert.match(r.stderr,pattern); }
writeFileSync(config,valid);
console.log('configuration contract passed');
JS
  test_pass "setup, TOML parsing, discovery and validation contract"
}
test_request_contract() {
  node --input-type=module - "$ROOT/bin/apicall" "$TEST_TMP_DIR" <<'JS'
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {writeFileSync, mkdirSync, readFileSync, existsSync} from 'node:fs';
import {join} from 'node:path';
const [bin,tmp]=process.argv.slice(2), config=join(tmp,'requests.toml'), mock=join(tmp,'mock');
mkdirSync(mock,{recursive:true});
writeFileSync(join(mock,'op'),`#!/usr/bin/env node
require('node:fs').appendFileSync(process.env.OP_LOG,JSON.stringify(process.argv.slice(2))+'\\n');
process.stdout.write(process.argv[4].endsWith('/username')?'op-user':'op-token');
`,{mode:0o700});
writeFileSync(join(mock,'curl'),`#!/usr/bin/env node
const fs=require('node:fs'), args=process.argv.slice(2), i=args.indexOf('--config');
fs.writeFileSync(process.env.CURL_LOG,JSON.stringify({args,auth:i>=0?fs.readFileSync(args[i+1],'utf8'):'',mode:i>=0?fs.statSync(args[i+1]).mode&0o777:0}));
process.stdout.write('response-body'); process.exit(Number(process.env.CURL_STATUS||0));
`,{mode:0o700});
const log=join(tmp,'curl.json'), opLog=join(tmp,'op.log');
const env={...process.env,PATH:mock+':'+process.env.PATH,APICALL_CONFIG:config,CURL_LOG:log,OP_LOG:opLog,DEMO_PROD_USER:'env-user',DEMO_PROD_PASS:'env-pass',DEMO_PROD_TOKEN:'env-token'};
const run=(args,extra={})=>spawnSync(process.execPath,[bin,...args],{encoding:'utf8',env:{...env,...extra}});
const fixture=(type='basic',policy='env')=>`version = 1
[services.demo]
api_path = "/api/"
[services.demo.headers]
Accept = "application/json"
[services.demo.auth]
type = "${type}"
${type==='none'?'':`credential_policy = "${policy}"`}
${type==='header'?'name = "X-API-Key"\nprefix = "Key "':''}
${type==='basic'?`[services.demo.auth.username]
env = "DEMO_{ENV}_USER"
op = "op://Test/demo-{env}/username"
[services.demo.auth.password]
env = "DEMO_{ENV}_PASS"
op = "op://Test/demo-{env}/password"`:type==='none'?'':`[services.demo.auth.token]
env = "DEMO_{ENV}_TOKEN"
op = "op://Test/demo-{env}/token"`}
[services.demo.environments.prod]
origin = "https://{env}.example.test"
`;
writeFileSync(config,fixture());
let r=run(['preview','demo','prod','/jobs/?x=1&y=2','--','-k','--connect-timeout','5']);
assert.equal(r.status,0,r.stderr); assert.match(r.stdout,/https:\/\/prod.example.test\/api\/jobs\/\?x=1&y=2/);
assert.equal(run(['preview','demo','prod','']).status,0);
assert.equal(JSON.parse(run(['preview','demo','prod','']).stdout).url,'https://prod.example.test/api/');
assert.doesNotMatch(r.stdout,/env-pass|env-user/); assert.equal(existsSync(log),false); assert.equal(existsSync(opLog),false);
r=run(['call','demo','prod','jobs/','--','-k','--connect-timeout=5','-XPOST','-H','X-Test: a b','--data','value with spaces']);
assert.equal(r.status,0,r.stderr); assert.equal(r.stdout,'response-body');
let recorded=JSON.parse(readFileSync(log)); assert.equal(recorded.args[0],'--disable'); assert.ok(recorded.args.includes('--globoff')); 
assert.ok(recorded.args.includes('X-Test: a b')); assert.ok(recorded.args.includes('value with spaces'));
assert.equal(recorded.mode,0o600); assert.match(recorded.auth,/env-user:env-pass/); assert.ok(!recorded.args.join(' ').includes('env-pass'));
assert.equal(existsSync(recorded.args[recorded.args.indexOf('--config')+1]),false);
r=run(['call','demo','prod','jobs'],{DEMO_PROD_PASS:''}); assert.equal(r.status,1); assert.match(r.stderr,/DEMO_PROD_PASS/); assert.equal(existsSync(opLog),false);
for (const tail of [['--url=https://evil.test'],['--next'],['-Kx'],['https://evil.test'],['--config','x'],['--unknown'],['-ks'],['--output']]) {
 r=run(['call','demo','prod','jobs','--',...tail]); assert.equal(r.status,1,tail.join(' '));
}
for (const path of ['https://evil.test/a','//evil.test','../a','a/../b','a#fragment']) assert.equal(run(['call','demo','prod',path]).status,1,path);
r=run(['call','demo','prod','jobs'],{CURL_STATUS:'22'}); assert.equal(r.status,22); assert.equal(r.stdout,'response-body');
for (const type of ['bearer','header','none']) {
 writeFileSync(config,fixture(type)); r=run(['call','demo','prod','jobs']); assert.equal(r.status,0,r.stderr);
 recorded=JSON.parse(readFileSync(log));
 if(type==='bearer') assert.match(recorded.auth,/Authorization: Bearer env-token/);
 if(type==='header') assert.match(recorded.auth,/X-API-Key: Key env-token/);
 if(type==='none') assert.equal(recorded.auth,'');
}
writeFileSync(config,fixture('basic','env-or-op'));
r=run(['call','demo','prod','jobs'],{DEMO_PROD_PASS:''}); assert.equal(r.status,0,r.stderr);
recorded=JSON.parse(readFileSync(log)); assert.match(recorded.auth,/op-user:op-token/); assert.doesNotMatch(recorded.auth,/env-user/);
assert.equal(readFileSync(opLog,'utf8').trim().split('\n').length,2);
writeFileSync(config,fixture('basic','op')); assert.equal(run(['call','demo','prod','jobs']).status,0);
writeFileSync(join(mock,'op'),'#!/usr/bin/env node\nprocess.stderr.write("secret-error");process.exit(1);');
r=run(['call','demo','prod','jobs']); assert.equal(r.status,1); assert.doesNotMatch(r.stderr,/secret-error/);
writeFileSync(config,fixture());
r=run(['call','demo','prod','jobs'],{DEMO_PROD_PASS:'bad\nvalue'}); assert.equal(r.status,1); assert.doesNotMatch(r.stderr,/bad/);

console.log('request and credential contract passed (mock curl/op only)');
JS
  test_pass "request construction, passthrough, redaction and credential policies"
}
test_local_http() {
  node --input-type=module - "$ROOT/bin/apicall" "$TEST_TMP_DIR" <<'JS'
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {writeFileSync} from 'node:fs';
import {join} from 'node:path';
const [bin,tmp]=process.argv.slice(2), config=join(tmp,'http.toml');
const requests=[];
const server=createServer((req,res)=>{
 let body=''; req.on('data',chunk=>body+=chunk); req.on('end',()=>{
  requests.push({url:req.url,method:req.method,auth:req.headers.authorization,body,header:req.headers['x-test']});
  res.statusCode=req.url.includes('failure')?403:200; res.end(res.statusCode===403?'denied':'ok');
 });
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin=`http://127.0.0.1:${server.address().port}`;
function fixture(type='basic') { return `version = 1
[services.demo]
api_path = "/api"
[services.demo.auth]
type = "${type}"
credential_policy = "env"
${type==='basic'?`[services.demo.auth.username]
env = "LOCAL_API_USER"
[services.demo.auth.password]
env = "LOCAL_API_PASS"`:`[services.demo.auth.token]
env = "LOCAL_API_TOKEN"`}
[services.demo.environments.dev]
origin = "${origin}"
`; }
const run=args=>new Promise((resolve,reject)=>{
 const child=spawn(process.execPath,[bin,...args],{env:{...process.env,APICALL_CONFIG:config,LOCAL_API_USER:'local-user',LOCAL_API_PASS:'a"b\\c\t!$',LOCAL_API_TOKEN:'local-token'},stdio:['ignore','pipe','pipe']});
 let out='',err=''; child.stdout.on('data',x=>out+=x); child.stderr.on('data',x=>err+=x);
 child.on('error',reject); child.on('close',status=>resolve({status,out,err}));
});
try {
 writeFileSync(config,fixture());
 let r=await run(['call','demo','dev','jobs/?a=1&b=2','--','--connect-timeout','2','--max-time','5']);
 assert.equal(r.status,0,r.err); assert.equal(r.out,'ok');
 assert.equal(requests[0].url,'/api/jobs/?a=1&b=2');
 assert.equal(requests[0].auth,'Basic '+Buffer.from('local-user:a"b\\c\t!$').toString('base64'));
 r=await run(['call','demo','dev','jobs','--','-X','POST','--json','{"a":1}','-H','X-Test: hello world']);
 assert.equal(r.status,0,r.err); assert.equal(requests[1].method,'POST'); assert.equal(requests[1].body,'{"a":1}'); assert.equal(requests[1].header,'hello world');
 r=await run(['call','demo','dev','failure']); assert.equal(r.status,22); assert.equal(r.out,'denied');
 writeFileSync(config,fixture('bearer')); r=await run(['call','demo','dev','jobs']); assert.equal(r.status,0,r.err); assert.equal(requests[3].auth,'Bearer local-token');
 console.log('real curl/local HTTP contract passed with environment credentials');
} finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
JS
  test_pass "real curl with local HTTP, env credentials, bodies and HTTP errors"
}
test_cleanup_on_signal() {
  node --input-type=module - "$ROOT/bin/apicall" "$TEST_TMP_DIR" <<'JS'
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {writeFileSync, readFileSync, existsSync, mkdirSync} from 'node:fs';
import {join} from 'node:path';
const [bin,tmp]=process.argv.slice(2), mock=join(tmp,'signal-mock'), config=join(tmp,'signal.toml'), ready=join(tmp,'ready');
mkdirSync(mock);
writeFileSync(join(mock,'curl'),`#!/usr/bin/env node
const fs=require('node:fs'), args=process.argv.slice(2);
fs.writeFileSync(process.env.READY,args[args.indexOf('--config')+1]);
process.on('SIGTERM',()=>process.exit(143)); setInterval(()=>{},1000);
`,{mode:0o700});
writeFileSync(config,`version = 1
[services.demo.auth]
type = "bearer"
[services.demo.auth.token]
env = "LOCAL_TOKEN"
[services.demo.environments.dev]
origin = "https://example.test"
`);
const child=spawn(process.execPath,[bin,'call','demo','dev','jobs'],{env:{...process.env,APICALL_CONFIG:config,LOCAL_TOKEN:'dummy',READY:ready,PATH:mock+':'+process.env.PATH},stdio:'ignore'});
const completion=new Promise(resolve=>child.on('close',resolve));
try {
 const deadline=Date.now()+5000;
 while(!existsSync(ready)) { if(Date.now()>deadline) throw Error('curl mock did not start'); await new Promise(resolve=>setTimeout(resolve,10)); }
 const auth=readFileSync(ready,'utf8'); assert.equal(existsSync(auth),true);
 child.kill('SIGTERM'); assert.equal(await completion,143); assert.equal(existsSync(auth),false);
 console.log('private authentication config removed on termination');
} finally { child.kill('SIGTERM'); }
JS
  test_pass "catchable termination removes private authentication config"
}
run_tests "$@"
