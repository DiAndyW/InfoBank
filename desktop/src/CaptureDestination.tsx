import { useState } from "react";
import type { Topic } from "./api";
import { Icon } from "./icons";
import Menu from "./Menu";

type Props = {
  topics: Topic[];
  tunnel: boolean;
  topicId: string | null;
  onTunnelChange: (on: boolean) => void;
  onTopicChange: (id: string | null) => void;
};

export default function CaptureDestination({ topics, tunnel, topicId, onTunnelChange, onTopicChange }: Props) {
  const [open, setOpen] = useState(false);
  const chosen = topics.find((t) => t.id === topicId);
  return <>
    <label className="nb-switch">
      <input type="checkbox" role="switch" checked={tunnel} onChange={(e) => {
        setOpen(false);
        localStorage.setItem("tunnelSwitch", String(e.target.checked));
        onTunnelChange(e.target.checked);
      }} />
      Tunnel
    </label>
    {!tunnel && <Menu label="Topic" open={open} onOpenChange={setOpen}
      trigger={<><Icon name={chosen ? "topic" : "inbox"} /><span>{chosen?.name ?? "Inbox"}</span></>}
      entries={[
        { label: "Inbox", checked: topicId === null, onSelect: () => onTopicChange(null) },
        ...topics.map((t) => ({ label: t.name, checked: topicId === t.id, onSelect: () => onTopicChange(t.id) })),
      ]} />}
  </>;
}
