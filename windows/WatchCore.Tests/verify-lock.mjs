// 只在测试中执行导出脚本；生产应用不执行从代理读取的脚本。
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import path from 'node:path';

const folder = process.argv[2];
const script = fs.readFileSync(path.join(folder, 'exit-lock.js'), 'utf8');
const source = {
  proxies: [
    {name: '落地', type: 'socks5', 'dialer-proxy': '前置', server: '127.0.0.1', port: 1},
    {name: '前置', type: 'socks5', server: '127.0.0.1', port: 2}
  ],
  'proxy-groups': [], rules: ['MATCH,DIRECT'], tun: {enable: true},
  dns: {enable: true, nameserver: ['https://example.com/dns-query']}
};
function apply(config, code = script) {
  const context = vm.createContext({input: structuredClone(config)});
  vm.runInContext('function main(c,n) { c.originalRan=n; return c; }\n' + code, context, {timeout: 1000});
  vm.runInContext('output=main(input,"测试订阅")', context, {timeout: 1000});
  assert.equal(context.injected, undefined);
  return JSON.parse(JSON.stringify(context.output));
}
const result = apply(source);
assert.equal(result.originalRan, '测试订阅');
for (const key of ['proxies','proxy-groups','tun','dns']) assert.deepEqual(result[key], source[key]);
assert.equal(result.rules.length, 15);
assert.equal(result.rules[0], 'DOMAIN-SUFFIX,claude.ai,落地');
assert.equal(result.rules[1], 'DOMAIN-SUFFIX,claude.ai,REJECT');
assert.deepEqual(apply(result).rules, result.rules);
assert(!script.includes('127.0.0.1'));
const variants = [
  {...source, proxies: []},
  {...source, proxies: [...source.proxies, source.proxies[0]]},
  {...source, 'proxy-groups': [{name: '落地', type: 'select', proxies: ['DIRECT']}]},
  {...source, proxies: [{...source.proxies[0], 'dialer-proxy': '自动'}, source.proxies[1]]},
  {...source, proxies: [{...source.proxies[0], type: 'direct'}, source.proxies[1]]}
];
for (const config of variants) assert(apply(config).rules.slice(0,14).every(r => r.endsWith(',REJECT')));
const name = '落地";globalThis.injected=true;//';
const escaped = fs.readFileSync(path.join(folder, 'escaped-lock.js'), 'utf8');
assert.equal(apply({...source, proxies: [{...source.proxies[0], name}, source.proxies[1]]}, escaped).rules[0],
  'DOMAIN-SUFFIX,claude.ai,' + name);
const rejected = apply({...source, proxies: []});
const unsafe = {...result, rules: result.rules.filter(r => !r.endsWith(',REJECT'))};
fs.writeFileSync(path.join(folder, 'mihomo-fixture.json'), JSON.stringify([result,rejected,unsafe]));
console.log('通过：旧脚本保留、域名节点 + REJECT、缺失 / 改链 / 冲突拒绝、幂等与脚本注入隔离');
