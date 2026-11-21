import { act, waitFor } from "@testing-library/react";
import { emit } from "@tauri-apps/api/event";
import { mockIPC } from "@tauri-apps/api/mocks";
import { expect } from "vitest";

const listeners = new Map<number, string>();

export function mockBackend(handler: Parameters<typeof mockIPC>[0]) {
  listeners.clear();
  mockIPC(handler, { shouldMockEvents: true });
  const internals = (window as unknown as { __TAURI_INTERNALS__: { invoke: (cmd: string, args: any, options?: unknown) => Promise<unknown> } }).__TAURI_INTERNALS__;
  const invoke = internals.invoke;
  internals.invoke = async (cmd, args, options) => {
    const result = await invoke(cmd, args, options);
    if (cmd === "plugin:event|listen") listeners.set(result as number, args.event);
    if (cmd === "plugin:event|unlisten") listeners.delete(args.eventId);
    return result;
  };
}

// Components register listeners in effects, which can run after their markup is already on screen.
export async function emitHeard(event: string, payload?: unknown) {
  await waitFor(() => expect([...listeners.values()]).toContain(event));
  await act(() => emit(event, payload));
}
