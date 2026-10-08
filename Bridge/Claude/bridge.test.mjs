import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createBridge } from './bridge.mjs';

function fixture({ stuckInterrupt = false } = {}) {
  const frames = [], options = [], decisions = [];
  let releaseWait;
  const queryFactory = ({ prompt, options: config }) => {
    options.push(config);
    const controller = new AbortController();
    const generator = (async function* () {
      yield { type: 'system', subtype: 'init', session_id: config.sessionId ?? config.resume };
      for await (const message of prompt) {
        const text = message.message.content;
        if (text === 'stream') {
          yield { type: 'stream_event', event: { type: 'message_start', message: { id: 'response' } } };
          for (const [index, text] of [[0, 'Hello '], [2, 'world']]) {
            yield { type: 'stream_event', event: { type: 'content_block_delta', index, delta: { type: 'text_delta', text } } };
            // Complete blocks each carry only that block, rather than a full message array.
            yield { type: 'assistant', message: { id: 'response', content: [{ type: 'text', text }] } };
          }
          yield { type: 'assistant', message: { id: 'tool', content: [{ type: 'tool_use', name: 'Read', input: { file_path: 'fixture' } }] } };
        } else if (text === 'approve' || text === 'question' || text === 'multiquestion') {
          const isQuestion = text !== 'approve';
          const input = isQuestion ? { questions: [{ question: 'Choose a target', header: 'Target', multiSelect: text === 'multiquestion', options: [{ label: 'Mac' }, { label: 'Linux' }] }] } : { command: 'fixture-only' };
          const decision = await config.canUseTool(isQuestion ? 'AskUserQuestion' : 'Bash', input, { signal: controller.signal });
          decisions.push(decision);
        } else if (text === 'wait') await new Promise(resolve => { releaseWait = resolve; });
        else if (text === 'fail') throw new Error('Fixture failure');
        yield { type: 'result', is_error: controller.signal.aborted, errors: controller.signal.aborted ? ['Interrupted'] : [] };
      }
    })();
    generator.interrupt = async () => { if (stuckInterrupt) return new Promise(() => {}); controller.abort(); releaseWait?.(); };
    generator.close = () => { controller.abort(); releaseWait?.(); prompt.close(); };
    return generator;
  };
  const bridge = createBridge({ queryFactory, write: frame => frames.push(frame), cancellationTimeoutMs: 30 });
  let next = 1;
  const send = (method, params = {}) => { const id = next++; void bridge.handle({ id, method, params }); return id; };
  async function until(predicate) {
    for (let i = 0; i < 100; i++) { if (predicate()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
    assert.fail('Timed out waiting for fixture');
  }
  async function start(text) {
    const newID = send('session/new', { cwd: '/tmp/disposable-fixture' });
    await until(() => frames.some(f => f.id === newID));
    const sessionId = frames.find(f => f.id === newID).result.sessionId;
    const id = send('session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
    return { id, sessionId };
  }
  return { bridge, frames, options, decisions, send, until, start };
}

test('streaming does not duplicate complete text blocks; tools and settings remain native', async () => {
  const f = fixture();
  try {
    const turn = await f.start('stream');
    await f.until(() => f.frames.some(x => x.id === turn.id));
    const text = f.frames.filter(x => x.params?.update?.sessionUpdate === 'agent_message_chunk').map(x => x.params.update.content.text).join('');
    assert.equal(text, 'Hello world');
    assert.ok(f.frames.some(x => x.params?.update?.title === 'Read'));
    assert.equal(f.options[0].permissionMode, 'default');
    assert.equal(f.options[0].allowDangerouslySkipPermissions, undefined);
    assert.equal(f.options[0].allowedTools, undefined);
    assert.deepEqual(f.options[0].settingSources, ['user', 'project', 'local']);
    const next = f.send('session/prompt', { sessionId: turn.sessionId, prompt: [{ type: 'text', text: 'second turn' }] });
    await f.until(() => f.frames.some(x => x.id === next));
    assert.equal(f.options.length, 1, 'A follow-up must reuse the live vendor query');
  } finally { f.bridge.close(); }
});

test('approval remains pending until an explicit decision and denial is preserved', async () => {
  const f = fixture();
  try {
    const turn = await f.start('approve');
    await f.until(() => f.frames.some(x => x.method === 'session/request_permission'));
    assert.ok(!f.frames.some(x => x.id === turn.id));
    const request = f.frames.find(x => x.method === 'session/request_permission');
    await f.bridge.handle({ id: request.id, result: { outcome: { optionId: 'deny_once' } } });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.equal(f.decisions[0].behavior, 'deny');
  } finally { f.bridge.close(); }
});

test('allow once changes no saved permission rules', async () => {
  const f = fixture();
  try {
    const turn = await f.start('approve');
    await f.until(() => f.frames.some(x => x.method === 'session/request_permission'));
    const request = f.frames.find(x => x.method === 'session/request_permission');
    await f.bridge.handle({ id: request.id, result: { outcome: { optionId: 'allow_once' } } });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.deepEqual(f.decisions[0], { behavior: 'allow', updatedInput: { command: 'fixture-only' } });
  } finally { f.bridge.close(); }
});

test('questions preserve the vendor input and send the selected answer', async () => {
  const f = fixture();
  try {
    const turn = await f.start('question');
    await f.until(() => f.frames.some(x => x.method === 'shastra/claudeQuestion'));
    const request = f.frames.find(x => x.method === 'shastra/claudeQuestion');
    await f.bridge.handle({ id: request.id, result: { answers: { 'Choose a target': ['Mac'] } } });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.equal(f.decisions[0].updatedInput.answers['Choose a target'], 'Mac');
    assert.equal(f.decisions[0].updatedInput.questions.length, 1);
  } finally { f.bridge.close(); }
});

test('interrupt settles only at the turn boundary and rejects pending permission', async () => {
  const f = fixture();
  try {
    const turn = await f.start('approve');
    await f.until(() => f.frames.some(x => x.method === 'session/request_permission'));
    await f.bridge.handle({ method: 'session/cancel', params: { sessionId: turn.sessionId } });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.equal(f.decisions[0].behavior, 'deny');
    assert.equal(f.frames.find(x => x.id === turn.id).result.stopReason, 'cancelled');
    assert.equal(f.frames.filter(x => x.id === turn.id).length, 1);
  } finally { f.bridge.close(); }
});

test('multiple selections match the pinned SDK string answer schema', async () => {
  const f = fixture();
  try {
    const turn = await f.start('multiquestion');
    await f.until(() => f.frames.some(x => x.method === 'shastra/claudeQuestion'));
    const request = f.frames.find(x => x.method === 'shastra/claudeQuestion');
    await f.bridge.handle({ id: request.id, result: { answers: { 'Choose a target': ['Mac', 'Linux'] } } });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.equal(f.decisions[0].updatedInput.answers['Choose a target'], 'Mac, Linux');
  } finally { f.bridge.close(); }
});

test('failure is actionable and a subsequent query resumes the same session', async () => {
  const f = fixture();
  try {
    const turn = await f.start('fail');
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.equal(f.frames.find(x => x.id === turn.id).error.message, 'Fixture failure');
    const id = f.send('session/prompt', { sessionId: turn.sessionId, prompt: [{ type: 'text', text: 'retry' }] });
    await f.until(() => f.frames.some(x => x.id === id));
    assert.equal(f.options[1].resume, turn.sessionId);
    assert.equal(f.options[1].sessionId, undefined);
  } finally { f.bridge.close(); }
});

test('closing rejects unanswered questions without accepting them', async () => {
  const f = fixture();
  const turn = await f.start('question');
  await f.until(() => f.frames.some(x => x.method === 'shastra/claudeQuestion'));
  f.bridge.close();
  await f.until(() => f.decisions.length === 1);
  assert.equal(f.decisions[0].behavior, 'deny');
  assert.equal(f.frames.filter(x => x.id === turn.id).length, 1);
});

test('a stuck interrupt closes its runner and allows the next turn to resume', async () => {
  const f = fixture({ stuckInterrupt: true });
  try {
    const turn = await f.start('wait');
    await f.until(() => f.options.length === 1);
    f.send('session/cancel', { sessionId: turn.sessionId });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    assert.equal(f.frames.find(x => x.id === turn.id).result.stopReason, 'cancelled');
    const next = f.send('session/prompt', { sessionId: turn.sessionId, prompt: [{ type: 'text', text: 'retry' }] });
    await f.until(() => f.frames.some(x => x.id === next));
    assert.equal(f.options[1].resume, turn.sessionId);
  } finally { f.bridge.close(); }
});

test('an old cancellation timer cannot stop a subsequent prompt', async () => {
  const f = fixture();
  try {
    const turn = await f.start('approve');
    await f.until(() => f.frames.some(x => x.method === 'session/request_permission'));
    f.send('session/cancel', { sessionId: turn.sessionId });
    await f.until(() => f.frames.some(x => x.id === turn.id));
    const next = f.send('session/prompt', { sessionId: turn.sessionId, prompt: [{ type: 'text', text: 'wait' }] });
    await new Promise(resolve => setTimeout(resolve, 70));
    assert.ok(!f.frames.some(x => x.id === next));
    f.send('session/cancel', { sessionId: turn.sessionId });
    await f.until(() => f.frames.some(x => x.id === next));
  } finally { f.bridge.close(); }
});

test('scoped coordination MCP configuration and requested model reach the SDK', async () => {
  const f = fixture();
  try {
    const creation = f.send('session/new', { cwd: '/tmp/disposable-fixture', mcpServers: [{ name: 'shastra', command: '/test/ShastraCLI', args: ['mcp'], env: [{ name: 'SHASTRA_AGENT_TOKEN', value: 'fixture-only' }] }] });
    await f.until(() => f.frames.some(x => x.id === creation));
    const sessionId = f.frames.find(x => x.id === creation).result.sessionId;
    const model = f.send('session/set_model', { sessionId, modelId: 'fixture-model' });
    await f.until(() => f.frames.some(x => x.id === model));
    const prompt = f.send('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'stream' }] });
    await f.until(() => f.frames.some(x => x.id === prompt));
    assert.equal(f.options[0].model, 'fixture-model');
    assert.deepEqual(f.options[0].mcpServers.shastra, { type: 'stdio', command: '/test/ShastraCLI', args: ['mcp'], env: { SHASTRA_AGENT_TOKEN: 'fixture-only' } });
  } finally { await f.bridge.close(); }
});

test('model discovery uses SDK metadata without a prompt, tools or session persistence', async () => {
  const frames = []; let closed = false, captured;
  const bridge = createBridge({ write: frame => frames.push(frame), queryFactory: ({ prompt, options }) => {
    captured = { prompt, options };
    return { supportedModels: async () => [{ value: 'sonnet', displayName: 'Provider Sonnet', resolvedModel: 'provider-wire-model' }], close: () => { closed = true; } };
  } });
  await bridge.handle({ id: 99, method: 'shastra/models', params: { cwd: '/fixture' } });
  assert.equal(frames[0].result.models[0].resolvedModel, 'provider-wire-model');
  assert.equal(captured.options.persistSession, false);
  assert.equal(captured.options.strictMcpConfig, true);
  assert.deepEqual(captured.options.mcpServers, {});
  assert.deepEqual(captured.options.tools, []);
  assert.equal(captured.options.settings.disableAllHooks, true);
  assert.deepEqual(captured.prompt.values, []);
  assert.equal(closed, true); assert.equal(captured.prompt.closed, true);
  bridge.close();
});
test('model discovery closes its metadata query when the provider fails', async () => {
  let closed = false; const frames = [];
  const bridge = createBridge({ write: frame => frames.push(frame), queryFactory: () => ({ supportedModels: async () => { throw new Error('Sign in required'); }, close: () => { closed = true; } }) });
  await bridge.handle({ id: 1, method: 'shastra/models', params: { cwd: '/fixture' } });
  assert.equal(closed, true); assert.match(frames[0].error.message, /Sign in required/);
  bridge.close();
});

test('loading an existing Claude thread resumes its exact ID without forking', async () => {
  const f = fixture();
  try {
    const sessionId = 'existing-claude-thread';
    const load = f.send('session/load', { sessionId, cwd: '/tmp/disposable-fixture' });
    await f.until(() => f.frames.some(x => x.id === load));
    assert.equal(f.frames.find(x => x.id === load).result.sessionId, sessionId);
    const turn = f.send('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'follow-up' }] });
    await f.until(() => f.frames.some(x => x.id === turn));
    assert.equal(f.options[0].resume, sessionId);
    assert.equal(f.options[0].sessionId, undefined);
    assert.notEqual(f.options[0].forkSession, true);
  } finally { f.bridge.close(); }
});
