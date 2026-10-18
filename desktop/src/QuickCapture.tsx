import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { dismissQuickCapture, listTopics, sortedTopics, type Topic } from "./api";
import Composer, { type ComposerHandle } from "./Composer";
import { Icon } from "./icons";
import Menu from "./Menu";
import { applyTheme, storedTheme } from "./theme";

const dismiss = () => dismissQuickCapture().catch(() => {});

export default function QuickCapture() {
  const [topics, setTopics] = useState<Topic[]>([]);
  const [topicId, setTopicId] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const composer = useRef<ComposerHandle>(null);

  useEffect(() => {
    const load = () => listTopics().then((all) => setTopics(sortedTopics(all.filter((t) => !t.archived))), () => {});
    applyTheme(storedTheme());
    load();
    const stops = [
      listen("quick-capture-shown", () => {
        applyTheme(storedTheme());
        load();
        composer.current?.focus();
      }),
      listen("quick-capture-hidden", () => {
        setMenuOpen(false);
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
        topicId={topicId}
        placeholder="Capture to NoteBank…"
        onCaptured={dismiss}
        onCancel={dismiss}
        picker={
          <Menu
            label="Topic"
            open={menuOpen}
            onOpenChange={setMenuOpen}
            trigger={
              <>
                <Icon name={chosen ? "topic" : "inbox"} />
                {chosen?.name ?? "Inbox"}
              </>
            }
            entries={[
              { label: "Inbox", checked: topicId === null, onSelect: () => setTopicId(null) },
              ...topics.map((t) => ({ label: t.name, checked: topicId === t.id, onSelect: () => setTopicId(t.id) })),
            ]}
          />
        }
      />
    </div>
  );
}
