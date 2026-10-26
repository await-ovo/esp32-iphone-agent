import { Agent } from '@midscene/core/agent';
import * as photon from '@silvia-odwyer/photon';
import { PhoneDevice } from './device';
import { iphoneContext } from './context';
import { nativeFetch } from './transport';
import { progressData } from './progress';

declare const PHOTON_WASM_BASE64: string;
declare global { interface Window { Midscene: any; webkit: any } }
let current: AbortController | undefined;

async function native(method: string, params: any = {}) {
  const reply = await window.webkit.messageHandlers.native.postMessage({ method, params });
  if (!reply?.ok) throw Error(reply?.error || `Native ${method} failed`);
  return reply.value;
}
async function run(config: any) {
  if (current) throw Error('A task is already running');
  const controller = new AbortController();
  current = controller;
  let agent: Agent | undefined;
  let result: any;
  // Progress carries no screenshots, raw model messages, headers, or dump JSON across the bridge.
  let progressQueue = Promise.resolve();
  const emit = (method: string, data: any) => {
    progressQueue = progressQueue.then(() => native(method, data)).catch(() => {});
    return progressQueue;
  };
  const progress = (event: any) => {
    const data = progressData(event);
    if (data) return emit('progress', data);
  };
  try {
    agent = new Agent(new PhoneDevice(native), {
      cache: false, generateReport: false, autoPrintReportMsg: false,
      waitAfterAction: 0, replanningCycleLimit: config.maxSteps,
      aiContexts: { aiAct: iphoneContext },
      modelConfig: {
        MIDSCENE_MODEL_BASE_URL: config.baseURL, MIDSCENE_MODEL_NAME: config.model,
        MIDSCENE_MODEL_FAMILY: config.family, MIDSCENE_MODEL_API_KEY: config.apiKey || 'local',
        MIDSCENE_MODEL_STREAM_MODE: 'stream', MIDSCENE_MODEL_RETRY_COUNT: '0', MIDSCENE_MODEL_EXTRA_BODY_JSON: JSON.stringify(config.extra),
      },
      createOpenAIClient: async client => client.withOptions({ maxRetries: 0, timeout: 120000, fetch: nativeFetch(native) }),
      onLLMUsage: usage => { void emit('usage', { model: usage.model_name, tokens: usage.total_tokens, milliseconds: usage.total_time_cost ?? usage.time_cost }); },
    });
    agent.addProgressListener(progress);
    const output = await agent.aiAct(config.prompt, { abortSignal: controller.signal });
    result = { ok: true, answer: typeof output === 'string' ? output : JSON.stringify(output ?? '') };
  } catch (error) { result = { ok: false, error: String(error), stopped: controller.signal.aborted }; }
  finally {
    await progressQueue;
    if (agent) await agent.destroy().catch(() => {});
    current = undefined;
  }
  await native('finished', result);
}

window.Midscene = { run, stop: () => current?.abort() };
void (async () => {
  try {
    await photon.default({ module_or_path: Uint8Array.from(atob(PHOTON_WASM_BASE64), c => c.charCodeAt(0)) });
    await native('ready');
  } catch (error) { await native('fatal', { error: String(error) }); }
})();
