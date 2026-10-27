/** Global toast store — bottom-right notifications. */

export type ToastTone = "success" | "warning" | "danger" | "info";

export interface ToastItem {
  id: number;
  tone: ToastTone;
  title: string;
  description?: string;
  actionLabel?: string;
  onAction?: () => void;
}

export interface ToastOpts {
  actionLabel?: string;
  onAction?: () => void;
  /** Auto-dismiss delay in ms. 0 = sticky: stays until the user dismisses
   *  it or takes the action (for things that need a decision, like a
   *  disconnected account). */
  duration?: number;
}

let nextId = 1;

export const toasts = $state<ToastItem[]>([]);

export function toast(tone: ToastTone, title: string, description?: string, opts?: ToastOpts) {
  const id = nextId++;
  // Invoking the action dismisses the toast first, then runs the callback.
  const onAction = opts?.onAction
    ? () => {
        dismissToast(id);
        opts.onAction!();
      }
    : undefined;
  toasts.push({ id, tone, title, description, actionLabel: opts?.actionLabel, onAction });
  const duration = opts?.duration ?? (tone === "danger" ? 7000 : 4000);
  if (duration > 0) setTimeout(() => dismissToast(id), duration);
  return id;
}

export function dismissToast(id: number) {
  const i = toasts.findIndex((t) => t.id === id);
  if (i !== -1) toasts.splice(i, 1);
}
