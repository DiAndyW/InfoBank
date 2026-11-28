import { test, vi } from "vitest";
import file from "../../behaviour/behaviour.json";

export type BehaviourExpectation = {
  max_characters?: number; ellipsis?: string;
  initial_items?: number; older_items?: number;
  message?: string; buttons?: string[]; duration_seconds?: number;
  menu?: { id: string; label: string }[]; row?: boolean; batch?: { id: string; label: string }[];
  order?: string; offered?: boolean; label?: string; actions?: string[];
};
type Rule = { expect: BehaviourExpectation; differs?: Partial<Record<string, { expect: BehaviourExpectation; reason: string }>> };

export function behaviourTest(id: Exclude<keyof typeof file.rules, `style.${string}`>, run: (expected: BehaviourExpectation) => void | Promise<void>) {
  test.each(["macos", "windows"] as const)(`${id} on %s`, async platform => {
    const agent = vi.spyOn(navigator, "userAgent", "get").mockReturnValue(platform === "macos" ? "Macintosh" : "Windows NT");
    try {
      const rule: Rule = file.rules[id];
      await run({ ...rule.expect, ...rule.differs?.[platform]?.expect });
    } finally { agent.mockRestore(); }
  });
}

export function noticeMessage(expected: BehaviourExpectation, values: Record<string, string | number> = {}) {
  return expected.message!.replace(/\{(\w+)\}/g, (_, key: string) => String(values[key]));
}
