import type { Native } from './device';

/** Pull bytes from URLSession. No CORS workaround, buffered SSE, or model-specific message rewriting. */
export function nativeFetch(native: Native): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    const id = crypto.randomUUID();
    const cancel = () => { void native('httpCancel', { id }).catch(() => {}); };
    request.signal.throwIfAborted();
    request.signal.addEventListener('abort', cancel, { once: true });
    const cleanup = () => request.signal.removeEventListener('abort', cancel);
    try {
      const head = await native('httpStart', { id, url: request.url, method: request.method,
        headers: Object.fromEntries(request.headers), body: await request.text() });
      request.signal.throwIfAborted();
      const body = new ReadableStream<Uint8Array>({
        async pull(controller) {
          try {
            request.signal.throwIfAborted();
            const chunk = await native('httpRead', { id });
            request.signal.throwIfAborted();
            if (chunk === null) { cleanup(); controller.close(); }
            else controller.enqueue(Uint8Array.from(atob(chunk), c => c.charCodeAt(0)));
          } catch (error) { cleanup(); cancel(); controller.error(error); }
        },
        cancel() { cleanup(); cancel(); },
      });
      return new Response(body, { status: head.status, headers: head.headers });
    } catch (error) { cleanup(); cancel(); throw error; }
  };
}
