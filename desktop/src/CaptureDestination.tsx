import { useState } from "react";
import { pickerTopic, type Topic } from "./api";
import { Icon } from "./icons";
import Menu from "./Menu";
import NewTopicDialog from "./NewTopicDialog";

type Props = {
  topics: Topic[];
  tunnel: boolean;
  topicId: string | null;
  onTunnelChange: (on: boolean) => void;
  onTopicChange: (id: string | null, created?: Topic) => void;
};

export default function CaptureDestination({ topics, tunnel, topicId, onTunnelChange, onTopicChange }: Props) {
  const [open, setOpen] = useState(false);
  const [naming, setNaming] = useState(false);
  const chosen = topics.find((t) => t.id === topicId);

  const draftBox = (from: HTMLElement) => from.closest("form")?.querySelector("textarea");

  async function create(name: string, from: HTMLElement) {
    try {
      const topic = await pickerTopic(name);
      onTopicChange(topic.id, topic);
      draftBox(from)?.focus();
      return null;
    } catch (err) {
      return String(err);
    }
  }

  return <>
    <label className="nb-switch">
      <input type="checkbox" role="switch" checked={tunnel} onChange={(e) => {
        setOpen(false);
        localStorage.setItem("tunnelSwitch", String(e.target.checked));
        onTunnelChange(e.target.checked);
      }} />
      Tunnel
    </label>
    {!tunnel && (
      <Menu label="Topic" open={open} onOpenChange={setOpen}
        trigger={<><Icon name={chosen ? "topic" : "inbox"} /><span>{chosen?.name ?? "Inbox"}</span></>}
        entries={[
          {
            filter: "Find or create a Topic",
            choices: [
              { label: "Inbox", checked: topicId === null, onSelect: () => onTopicChange(null) },
              ...topics.map((t) => ({ label: t.name, checked: topicId === t.id, onSelect: () => onTopicChange(t.id) })),
            ],
            create: {
              label: "New Topic…",
              // The dialog hands focus back to whatever had it, so give it to the draft first.
              onNew: (from) => {
                draftBox(from)?.focus();
                setNaming(true);
              },
              onCreate: create,
            },
          },
        ]} />
    )}
    {naming && (
      <NewTopicDialog onClose={() => setNaming(false)}
        onCreated={(topic) => {
          setNaming(false);
          onTopicChange(topic.id, topic);
        }} />
    )}
  </>;
}
