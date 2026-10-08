import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { query } from '@anthropic-ai/claude-agent-sdk';

class InputQueue {
  values = []; waiting; closed = false;
  push(value) { if (this.closed) throw new Error('Session closed'); if (this.waiting) { this.waiting({ value, done: false }); this.waiting = undefined; } else this.values.push(value); }
  close() { this.closed = true; this.waiting?.({ done: true }); this.waiting = undefined; }
  [Symbol.asyncIterator]() { return this; }
  next() { if (this.values.length) return Promise.resolve({ value: this.values.shift(), done: false }); if (this.closed) return Promise.resolve({ done: true }); return new Promise(resolve => { this.waiting = resolve; }); }
}

// JSON-RPC facade over Claude Code's SDK. Vendor tools remain inside Claude Code.
export function createBridge({ queryFactory = query, write = frame => process.stdout.write(JSON.stringify(frame) + '\n'), cancellationTimeoutMs = 5_000 } = {}) {
  const sessions = new Map(), approvals = new Map();
  const reply = (id, result) => write({ jsonrpc: '2.0', id, result });
  const fail = (id, message) => write({ jsonrpc: '2.0', id, error: { code: -32000, message } });
  const notify = (method, params) => write({ jsonrpc: '2.0', method, params });
  const update = (session, value) => notify('session/update', { sessionId: session.id, update: value });
  function denyPending(session) {
    for (const [id, item] of approvals) if (item.session === session) { approvals.delete(id); item.finish({ behavior: 'deny', message: 'Request cancelled', interrupt: true }); }
  }
  function permission(session, tool, input, context) {
    return new Promise(resolve => {
      const id = randomUUID();
      const finish = result => { context.signal.removeEventListener('abort', abort); resolve(result); };
      const abort = () => { approvals.delete(id); finish({ behavior: 'deny', message: 'Request cancelled', interrupt: true }); };
      if (context.signal.aborted) { abort(); return; }
      approvals.set(id, { session, input, tool, finish });
      context.signal.addEventListener('abort', abort, { once: true });
      const params = { sessionId: session.id, toolName: tool, input };
      if (tool === 'AskUserQuestion') write({ jsonrpc: '2.0', id, method: 'shastra/claudeQuestion', params });
      else write({ jsonrpc: '2.0', id, method: 'session/request_permission', params: { ...params,
        reason: context.title ?? context.decisionReason ?? `${tool}: ${JSON.stringify(input)}`,
        options: [{ optionId: 'allow_once' }, { optionId: 'deny_once' }] } });
    });
  }
  function settle(session, result, error) {
    const id = session.promptID;
    session.promptID = undefined;
    if (id !== undefined) { if (error) fail(id, error); else reply(id, result); }
  }
  function start(session) {
    session.queue = new InputQueue();
    const options = {
      cwd: session.cwd, includePartialMessages: true, permissionMode: 'default',
      ...(session.model ? { model: session.model } : {}),
      mcpServers: session.mcpServers ?? {},
      settingSources: ['user', 'project', 'local'], systemPrompt: { type: 'preset', preset: 'claude_code' },
      ...(session.started ? { resume: session.id } : { sessionId: session.id }),
      ...(process.env.SHASTRA_CLAUDE_EXECUTABLE ? { pathToClaudeCodeExecutable: process.env.SHASTRA_CLAUDE_EXECUTABLE } : {}),
      canUseTool: (tool, input, context) => permission(session, tool, input, context),
      // Keep the SDK's bidirectional control channel open for streaming input.
      hooks: { PreToolUse: [{ hooks: [async () => ({ continue: true })] }] },
    };
    const runner = queryFactory({ prompt: session.queue, options });
    session.runner = runner;
    session.streamed = new Set();
    void (async () => {
      try {
        for await (const message of runner) {
          if (session.runner !== runner) break;
          if (message.type === 'system' && message.subtype === 'init') session.started = true;
          if (message.type === 'stream_event') {
            const event = message.event;
            if (event.type === 'message_start') {
              session.messageID = event.message?.id;
              notify('shastra/messageStart', { sessionId: session.id });
            }
            if (event.type === 'content_block_delta' && event.delta?.type === 'text_delta') {
              if (session.messageID) session.streamed.add(session.messageID);
              update(session, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: event.delta.text } });
            }
          } else if (message.type === 'assistant') {
            for (const [index, block] of (message.message?.content ?? []).entries()) {
              if (block.type === 'text' && !session.streamed.has(message.message.id)) {
                update(session, message.parent_tool_use_id
                  ? { sessionUpdate: 'tool_call', title: `Subagent: ${block.text}` }
                  : { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: block.text } });
              } else if (block.type === 'tool_use') {
                update(session, { sessionUpdate: 'tool_call', title: block.name, input: block.input });
              }
            }
          } else if (message.type === 'result') {
            denyPending(session);
            const error = message.is_error && !session.cancelled ? (message.errors?.join('\n') || message.result || 'Claude turn failed') : undefined;
            settle(session, { stopReason: session.cancelled ? 'cancelled' : 'end_turn' }, error);
            session.streamed.clear();
          }
        }
        if (session.runner === runner && session.promptID !== undefined) settle(session, undefined, 'Claude ended before returning a turn result.');
      } catch (error) {
        if (session.runner === runner) {
          if (session.cancelled) settle(session, { stopReason: 'cancelled' });
          else settle(session, undefined, error.message || 'Claude session failed');
        }
      } finally {
        if (session.runner === runner) { denyPending(session); session.runner = undefined; session.queue.close(); }
      }
    })();
  }
  async function handle(frame) {
    if (!frame.method) {
      const approval = approvals.get(String(frame.id));
      if (!approval) return;
      approvals.delete(String(frame.id));
      if (approval.tool === 'AskUserQuestion') {
        const answers = frame.result?.answers;
        if (answers && (approval.input.questions ?? []).every(q => answers[q.question]?.length)) {
          const formatted = Object.fromEntries(approval.input.questions.map(q => [q.question, q.multiSelect ? answers[q.question].join(', ') : answers[q.question][0]]));
          approval.finish({ behavior: 'allow', updatedInput: { ...approval.input, answers: formatted } });
        } else approval.finish({ behavior: 'deny', message: 'Question was not answered' });
      } else {
        const allow = frame.result?.outcome?.optionId === 'allow_once';
        approval.finish(allow ? { behavior: 'allow', updatedInput: approval.input } : { behavior: 'deny', message: 'User declined this operation' });
      }
      return;
    }
    try {
      const p = frame.params ?? {};
      switch (frame.method) {
        case 'shastra/models': {
          const input = new InputQueue();
          const runner = queryFactory({ prompt: input, options: {
            cwd: p.cwd, persistSession: false, settingSources: ['user', 'project', 'local'],
            strictMcpConfig: true, mcpServers: {}, tools: [],
            settings: { disableAllHooks: true },
            ...(process.env.SHASTRA_CLAUDE_EXECUTABLE ? { pathToClaudeCodeExecutable: process.env.SHASTRA_CLAUDE_EXECUTABLE } : {}),
          } });
          try { reply(frame.id, { models: await runner.supportedModels() }); }
          finally { input.close(); runner.close(); }
          break;
        }
        case 'initialize': reply(frame.id, { protocolVersion: 1, agentInfo: { name: 'Claude Code', version: '0.3.286' } }); break;
        case 'authenticate': reply(frame.id, {}); break; // Claude's own login is checked when its process starts.
        case 'session/new': case 'session/load': {
          const id = frame.method === 'session/load' ? p.sessionId : randomUUID();
          if (!id || sessions.has(id)) throw new Error('Invalid or already open session');
          const mcpServers = Object.fromEntries((p.mcpServers ?? []).map(server => [server.name, {
            type: 'stdio', command: server.command, args: server.args ?? [],
            env: Object.fromEntries((server.env ?? []).map(item => [item.name, item.value]))
          }]));
          sessions.set(id, { id, cwd: p.cwd, mcpServers, started: frame.method === 'session/load' });
          reply(frame.id, { sessionId: id }); break;
        }
        case 'session/set_model': {
          const session = sessions.get(p.sessionId);
          if (!session || session.runner) throw new Error('Choose a model before starting the session');
          session.model = p.modelId; reply(frame.id, {}); break;
        }
        case 'session/prompt': {
          const session = sessions.get(p.sessionId);
          if (!session) throw new Error('Session is unavailable');
          if (session.promptID !== undefined) throw new Error('Wait for the current turn to finish');
          const text = (p.prompt ?? []).filter(x => x.type === 'text').map(x => x.text).join('\n');
          if (!text) throw new Error('Enter a message');
          if (!session.runner) start(session);
          session.cancelled = false;
          session.promptID = frame.id;
          session.queue.push({ type: 'user', session_id: session.id, parent_tool_use_id: null, message: { role: 'user', content: text } });
          break;
        }
        case 'session/cancel': {
          const session = sessions.get(p.sessionId);
          if (session && session.promptID !== undefined) {
            session.cancelled = true; denyPending(session);
            const runner = session.runner;
            const cancelledPromptID = session.promptID;
            // A wedged control channel must not leave the composer permanently busy.
            const timeout = setTimeout(() => {
              if (session.runner !== runner || session.promptID !== cancelledPromptID) return;
              session.runner = undefined; session.queue?.close(); runner?.close();
              settle(session, { stopReason: 'cancelled' });
            }, cancellationTimeoutMs);
            timeout.unref?.();
            try { await runner?.interrupt(); }
            catch {
              if (session.runner === runner && session.promptID === cancelledPromptID) {
                session.runner = undefined; session.queue?.close(); runner?.close();
                settle(session, { stopReason: 'cancelled' });
              }
            }
          }
          if (frame.id !== undefined) reply(frame.id, {});
          break;
        }
        default: if (frame.id !== undefined) fail(frame.id, `Unsupported bridge method: ${frame.method}`);
      }
    } catch (error) { if (frame.id !== undefined) fail(frame.id, error.message || 'Claude bridge failed'); }
  }
  function close() {
    for (const session of sessions.values()) {
      denyPending(session); session.queue?.close(); session.runner?.close(); session.runner = undefined;
      settle(session, undefined, 'Claude session closed');
    }
    sessions.clear();
  }
  return { handle, close };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const bridge = createBridge();
  const input = createInterface({ input: process.stdin, terminal: false });
  input.on('line', line => { if (line.length > 8_388_608) { bridge.close(); process.exit(1); } try { void bridge.handle(JSON.parse(line)); } catch { /* Ignore malformed transport lines. */ } });
  input.on('close', () => { bridge.close(); process.exit(0); });
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => { bridge.close(); process.exit(0); });
}
