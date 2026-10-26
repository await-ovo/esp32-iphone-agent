import { actionParams } from './progress.js';
import {
  AbstractInterface, defineAction, defineActionTap, defineActionInput,
  defineActionClearInput, defineActionKeyboardPress, defineActionLongPress,
  defineActionSwipe, defineActionScroll, z,
} from '@midscene/core/device';

export type Native = (method: string, params?: any) => Promise<any>;
const point = (target: any) => target && { x: target.center[0], y: target.center[1] };

/** Screenshots and all SDK coordinates use JPEG pixels. Swift owns HID and calibration. */
export class PhoneDevice extends AbstractInterface {
  interfaceType = 'iphone-hid';
  constructor(private native: Native) { super(); }
  screenshotBase64() { return this.native('screenshot'); }
  size() { return this.native('size'); }
  describe() {
    return 'An iPhone controlled with an AssistiveTouch mouse and keyboard. Ignore the floating AssistiveTouch button and mouse cursor. Input supports ASCII text only. Use Command shortcuts on iOS. Gesture duration is approximate over Bluetooth.';
  }
  async destroy() {}
  async beforeInvokeAction(name: string, param: any) {
    // Sleep belongs to core, so it does not pass through actionSpace().
    if (name === 'Sleep') await this.native('actionBegin', { name, timeMs: param.timeMs, param: actionParams(param) });
  }
  async afterInvokeAction(name: string) {
    if (name === 'Sleep') await this.native('actionEnd');
  }
  actionSpace() {
    const input = {
      typeText: (text: string, options: any = {}) => this.native('input', {
        text, target: point(options.target), mode: options.replace ? 'replace' : 'typeOnly',
      }),
      clearInput: (target?: any) => this.native('input', { target: point(target), mode: 'clear', text: '' }),
    };
    return [
      defineActionTap(p => this.native('tap', p)),
      defineActionLongPress((p, options) => this.native('longPress', { ...p, duration: options?.duration ?? 500 })),
      defineActionInput(input),
      defineActionClearInput(input.clearInput),
      defineActionKeyboardPress((keyName, options) => this.native('key', { keyName, target: point(options?.target) })),
      defineActionSwipe({
        size: () => this.size(), inputMode: 'mouse',
        swipe: (start, end, options) => this.native('swipe', { start, end, duration: options?.duration ?? 300 }),
      }),
      defineActionScroll(param => this.native('scroll', { ...param, locate: undefined, target: point(param.locate) })),
      defineAction({ name: 'Home', description: 'Go to the iPhone Home Screen.', call: () => this.native('home') }),
      defineAction({ name: 'Back', description: 'Swipe from the left edge to go back on iOS.', call: () => this.native('back') }),
      defineAction({
        name: 'DrawPath', description: 'Draw one continuous stroke through points in screenshot pixels.',
        paramSchema: z.object({ points: z.array(z.tuple([z.number(), z.number()])).min(2), duration: z.number().positive().optional() }),
        call: param => this.native('draw', param),
      }),
    ].map(action => ({
      ...action,
      call: async (param: any, context: any) => {
        await this.native('actionBegin', { name: action.name, param: actionParams(param) });
        try {
          const result = await action.call(param, context);
          await this.native('actionEnd');
          return result;
        } catch (error) {
          await this.native('actionEnd', { error: String(error) });
          throw error;
        }
      },
    }));
  }
}
