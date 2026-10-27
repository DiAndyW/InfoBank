import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { dismissQuickCapture, listTopics, sortedTopics, type Topic } from "./api";
import Composer, { type ComposerHandle } from "./Composer";
import CaptureDestination from "./CaptureDestination";
import { applyTheme, storedTheme } from "./theme";

const dismiss = () => dismissQuickCapture().catch(() => {});

export default function QuickCapture() {
  const [session, setSession] = useState(0);
  const [topics, setTopics] = useState<Topic[]>([]);
  const [topicId, setTopicId] = useState<string | null>(null);
  const [tunnel, setTunnel] = useState(() => localStorage.getItem("tunnelSwitch") === "true");
  const composer = useRef<ComposerHandle>(null);

  useEffect(() => {
    const load = () => listTopics().then((all) => setTopics(sortedTopics(all.filter((t) => !t.archived))), () => {});
    applyTheme(storedTheme());
    load();
    const stops = [
      listen("quick-capture-shown", () => {
        applyTheme(storedTheme());
        setTunnel(localStorage.getItem("tunnelSwitch") === "true");
        load();
        composer.current?.focus();
      }),
      listen("quick-capture-hidden", () => {
        setSession((s) => s + 1);
        setTopicId(null);
        composer.current?.discard();
      }),
      listen("items-changed", load),
    ];
    return () => stops.forEach((stop) => stop.then((s) => s()));
  }, []);

  // Only on a Topics change, so a Topic picked from the list is never undone before it's checked.
  useEffect(() => {
    if (topicId !== null && !topics.some((t) => t.id === topicId)) setTopicId(null);
  }, [topics]);

  const chosen = topics.find((t) => t.id === topicId);
  return (
    <div className="nb-quick" onMouseDown={(e) => e.target === e.currentTarget && dismiss()}>
      <Composer
        ref={composer}
        acceptsDrops
        target={tunnel ? { kind: "tunnel" } : chosen ? { kind: "topic", id: chosen.id } : { kind: "inbox" }}
        placeholder={tunnel ? "Send to your other devices…" : "Capture to NoteBank…"}
        onCaptured={dismiss}
        onCancel={dismiss}
        picker={<CaptureDestination key={session} topics={topics} tunnel={tunnel} topicId={chosen?.id ?? null} onTunnelChange={setTunnel} onTopicChange={setTopicId} />}
      />
    </div>
  );
}
