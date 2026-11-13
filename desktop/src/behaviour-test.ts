import { test, vi } from "vitest";
import file from "../../behaviour/behaviour.json";

export type BehaviourExpectation = {
  message?: string; buttons?: string[]; duration_seconds?: number;
  menu?: { id: string; label: string }[]; row?: boolean; batch?: { id: string; label: string }[];
  offered?: boolean; label?: string;
};
type Rule = { expect: BehaviourExpectation; differs?: Partial<Record<string, { expect: BehaviourExpectation; reason: string }>> };

export function behaviourTest(id: keyof typeof file.rules, run: (expected: BehaviourExpectation) => void | Promise<void>) {
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
