// Mimics `claude -p --output-format stream-json`. Behaviour depends on the prompt:
// invocation 1 of a block answers CONTINUE, invocation 2 writes a file and answers DONE.
// A block whose title contains QUOTA fails with a usage limit on its first call
// (SOON: the limit renews in two seconds); OFFLINE: no network on its first call.
const fs = require('fs');
let input = '';
process.stdin.on('data', d => (input += d));
process.stdin.on('end', () => {
  const block = Number(/Blocco corrente: (\d+)/.exec(input)[1]);
  const attempt = Number(/Invocazione n\. (\d+)/.exec(input)[1]);
  const title = /«([^»]*)»\n/.exec(input)[1];
  const emit = o => console.log(JSON.stringify(o));
  emit({ type: 'system', subtype: 'init', model: 'fake' });
  const quotaFlag = '.quota_seen';
  if (title.includes('QUOTA') && !fs.existsSync(quotaFlag)) {
    fs.writeFileSync(quotaFlag, '1');
    const reset = title.includes('SOON') ? Math.floor(Date.now() / 1000) + 2 : 1731000000;
    emit({ type: 'result', subtype: 'success', is_error: true, result: `Claude AI usage limit reached|${reset}`, usage: {} });
    process.exit(1);
  }
  const offlineFlag = '.offline_seen';
  if (title.includes('OFFLINE') && !fs.existsSync(offlineFlag)) {
    fs.writeFileSync(offlineFlag, '1');
    emit({ type: 'result', subtype: 'error_during_execution', is_error: true, result: 'API Error: fetch failed (getaddrinfo ENOTFOUND api.anthropic.com)', usage: {} });
    process.exit(1);
  }
  emit({ type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Write', input: { file_path: `out${block}.txt` } }] } });
  // Reports its steps the way the prompt asks: one of three per invocation.
  emit({ type: 'assistant', message: { content: [{ type: 'text', text: `AUTOLOOP_PROGRESS: ${attempt}/3` }] } });
  let status;
  if (attempt === 1) {
    status = 'CONTINUE';
  } else {
    fs.writeFileSync(`out${block}.txt`, `block ${block}\n`);
    status = 'DONE';
  }
  const text = `Lavoro sul blocco ${block}.\nAUTOLOOP_STATUS: ${status}`;
  emit({ type: 'assistant', message: { content: [{ type: 'text', text }] } });
  emit({ type: 'result', subtype: 'success', is_error: false, result: text, usage: { input_tokens: 100, output_tokens: 10 }, total_cost_usd: 0.001 });
});
