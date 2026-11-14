import type { ReactElement } from "react";

const PATHS = {
  copy: <><rect x={5.5} y={5.5} width={8} height={9} rx={1} /><path d="M10.5 5.5V2.5h-8v9h3" /></>,
  sidebar: <><rect x={2} y={2.5} width={12} height={11} rx={1.5} /><path d="M6 2.5v11" /></>,
  home: <path d="M2 7 8 2l6 5v7H9.5V9h-3v5H2z" />,
  more: (
    <>
      <circle cx={3} cy={8} r={1.25} fill="currentColor" stroke="none" />
      <circle cx={8} cy={8} r={1.25} fill="currentColor" stroke="none" />
      <circle cx={13} cy={8} r={1.25} fill="currentColor" stroke="none" />
    </>
  ),
  paperclip: <path d="M13 7.5 8.2 12.3a3 3 0 0 1-4.2-4.2l5-5a2 2 0 0 1 2.8 2.8l-5 5a1 1 0 0 1-1.4-1.4L10 4.9" />,
  send: <path d="M8 13V3M3.5 7.5 8 3l4.5 4.5" />,
  file: <path d="M4 1.75h5L12.25 5v9.25H4zM9 1.75V5h3.25" />,
  image: (
    <>
      <rect x={2} y={2.75} width={12} height={10.5} rx={1.5} />
      <circle cx={5.75} cy={6.25} r={1.25} />
      <path d="M2.5 12l3.75-3.75L9 11l2-2 2.5 2.5" />
    </>
  ),
  play: <path d="M5.5 3.5v9l7-4.5z" fill="currentColor" />,
  check: <path d="M3.5 8.5 6.5 11.5 12.5 4.5" />,
  x: <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" />,
  "chevron-right": <path d="M6 3.5 10.5 8 6 12.5" />,
  "chevron-left": <path d="M10 3.5 5.5 8 10 12.5" />,
  "chevron-down": <path d="M3.5 6 8 10.5 12.5 6" />,
  plus: <path d="M8 3v10M3 8h10" />,
  all: <path d="M8 2 14 5 8 8 2 5zM2 8l6 3 6-3M2 11l6 3 6-3" />,
  inbox: <path d="M2 9.5h3.5l1 1.75h3l1-1.75H14M2 9.5 4 3h8l2 6.5V13H2z" />,
  topic: <path d="M6 2.5 4.5 13.5M11.5 2.5 10 13.5M2.5 6h11M2 10h11" />,
  trash: <path d="M2.5 4h11M6 4V2.5h4V4M4 4l.75 9.5h6.5L12 4" />,
  settings: (
    <>
      <path d="M2 4.5h7M12 4.5h2M2 11.5h2M7 11.5h7" />
      <circle cx={10.5} cy={4.5} r={1.5} />
      <circle cx={5.5} cy={11.5} r={1.5} />
    </>
  ),
  synced: <circle cx={8} cy={8} r={3.5} fill="currentColor" stroke="none" />,
  syncing: <path d="M13 8a5 5 0 0 1-8.6 3.5M3 8a5 5 0 0 1 8.6-3.5M11.75 2v2.75H14.5M4.25 14v-2.75H1.5" />,
  offline: <circle cx={8} cy={8} r={4.25} />,
  alert: <path d="M8 2.25 14.25 13.5H1.75zM8 6.5v3.25M8 11.75v.01" />,
  key: (
    <>
      <circle cx={5} cy={11} r={2.75} />
      <path d="M7 9l6-6M11 5l1.75 1.75" />
    </>
  ),
  pending: <circle cx={8} cy={8} r={4.5} strokeDasharray="2.2 2" />,
  reveal: <path d="M6.5 3H3v10h10V9.5M9 2.5h4.5V7M13.5 2.5 7.5 8.5" />,
  grip: <path d="M6 4h.01M10 4h.01M6 8h.01M10 8h.01M6 12h.01M10 12h.01" strokeWidth={2.5} />,
  restore: <path d="M3 8a5 5 0 1 0 1.6-3.7M3 2.5v3h3" />,
  calendar: (
    <>
      <rect x={2.5} y={3.5} width={11} height={10} rx={1.5} />
      <path d="M2.5 6.5h11M5.5 2v3M10.5 2v3" />
    </>
  ),
  search: <path d="M7 12A5 5 0 1 0 7 2a5 5 0 0 0 0 10zM10.75 10.75 14 14" />,
} satisfies Record<string, ReactElement>;

export type IconName = keyof typeof PATHS;

export function Icon({ name, size = 16, label, className }: { name: IconName; size?: number; label?: string; className?: string }) {
  return (
    <svg
      className={className ? `nb-icon ${className}` : "nb-icon"}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {PATHS[name]}
    </svg>
  );
}
