import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';

const binary = process.argv[2] || new URL('../bin/omniscope-search', import.meta.url).pathname;
const root = process.argv[3] || process.env.HOME;
const child = spawn(binary, [root], { stdio: ['pipe', 'pipe', 'inherit'] });
let sequence = 0;
const waiting = new Map();
let indexedResolve;
const indexed = new Promise(resolve => { indexedResolve = resolve; });
const timeout = setTimeout(() => { child.kill(); throw new Error('Benchmark timed out'); }, 60000);
createInterface({ input: child.stdout }).on('line', line => {
    const message = JSON.parse(line);
    if (message.type === 'indexed') indexedResolve(message);
    if (message.type === 'results') {
        const resolve = waiting.get(message.id);
        if (resolve) { waiting.delete(message.id); resolve(message); }
    }
});
child.on('error', error => { clearTimeout(timeout); throw error; });
try {
    const index = await indexed;
    console.log(JSON.stringify({ files: index.count, indexMs: index.elapsedMs }));
    const measurements = new Map();
    // Alternate queries so these measure actual matching, not cached pages.
    for (let run = 0; run < 12; run++) {
        for (const query of ['m', 'ma', 'main', 'config', 'omni', 'zz_omniscope_no_match_7a8c9d']) {
            const id = ++sequence;
            const reply = new Promise(resolve => waiting.set(id, resolve));
            const start = performance.now();
            child.stdin.write(JSON.stringify({ type: 'search', id, query, mode: 'files', limit: 100 }) + '\n');
            const result = await reply;
            if (run >= 2) {
                const samples = measurements.get(query) || [];
                samples.push({ worker: result.elapsedMs, roundtrip: performance.now() - start, total: result.total });
                measurements.set(query, samples);
            }
        }
    }
    for (const [query, samples] of measurements) {
        const percentile = (key, p) => samples.map(s => s[key]).sort((a,b) => a-b)[Math.min(samples.length-1, Math.floor(samples.length*p))];
        console.log(JSON.stringify({ query, matches: samples[0].total, workerMedianMs: percentile('worker', .5), roundtripMedianMs: percentile('roundtrip', .5), roundtripP95Ms: percentile('roundtrip', .95) }));
    }
    const memory = readFileSync(`/proc/${child.pid}/status`, 'utf8').match(/^VmRSS:.*$/m);
    if (memory) console.log(memory[0]);
} finally {
    clearTimeout(timeout);
    child.stdin.end();
}
