/** Parameters for native replay, excluding locator images and SDK internals. */
export function actionParams(param: any = {}) {
  const out: Record<string, unknown> = {};
  for (const key of ['value', 'mode', 'keyName', 'direction', 'distance', 'duration', 'repeat', 'scrollType', 'timeMs', 'points', 'autoDismissKeyboard', 'keyboardTypeDelay', 'inputStrategy']) {
    const value = param?.[key];
    if (typeof value === 'string') out[key] = value.length > 2000 ? value.slice(0, 2000) + '…' : value;
    else if (typeof value === 'number' && Number.isFinite(value) || typeof value === 'boolean') out[key] = value;
    else if (key === 'points' && Array.isArray(value)) out[key] = value.slice(0, 100).filter(p =>
      Array.isArray(p) && p.length === 2 && p.every(n => typeof n === 'number' && Number.isFinite(n)));
  }
  for (const key of ['locate', 'start', 'end']) {
    const center = param?.[key]?.center;
    if (Array.isArray(center) && center.length === 2 && center.every(Number.isFinite)) out[key] = { center };
  }
  return out;
}

/** Only compact presentation data crosses the bridge; screenshots and model dumps stay out. */
export function progressData(event: any) {
  if (event.scope !== 'aiAct') return;
  const data = event.data || {};
  const text = (value: unknown) => typeof value === 'string' ? value.slice(0, 2000) : undefined;
  return {
    phase: event.phase, sequence: event.sequence,
    planIndex: data.planIndex,
    text: text(data.log), error: text(data.error), durationMs: data.durationMs,
    action: data.action && { name: text(data.action.name), target: text(data.action.target),
      param: actionParams(data.action.param),
      point: Array.isArray(data.action.point) && data.action.point.length === 2 && data.action.point.every(Number.isFinite)
        ? data.action.point : undefined },
  };
}
