import { useEffect, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { attachmentOriginal, attachmentStored, openAttachment, thumbnail, type FeedAttachment } from "./api";
import { Icon } from "./icons";

type Props = {
  images: FeedAttachment[];
  selected: string;
  onSelect: (id: string) => void;
  onClose: () => void;
};

type View = { scale: number; x: number; y: number };

type Display = {
  id: string;
  thumbSrc: string | null;
  originalSrc: string | null;
  loaded: boolean;
  loading: boolean;
  note: string | null;
  retry: boolean;
  thumbSmall: boolean;
  originalSmall: boolean;
};

export default function ImageViewer({ images, selected, onSelect, onClose }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const stage = useRef<HTMLDivElement>(null);
  const imageWrapper = useRef<HTMLDivElement>(null);
  const [view, setView] = useState<View>({ scale: 1, x: 0, y: 0 });
  const viewRef = useRef(view);
  viewRef.current = view;
  const drag = useRef<{ id: number; x: number; y: number } | null>(null);
  const clickedStage = useRef(false);
  const [openerId] = useState(selected);
  const opening = useRef(new Set<string>());
  const fetches = useRef(new Map<string, Promise<string>>());
  const generation = useRef(0);
  const [attempt, setAttempt] = useState(0);
  const [display, setDisplay] = useState<Display | null>(null);
  const current = display?.id === selected ? display : null;
  const index = images.findIndex(a => a.id === selected);
  const filename = images[index].filename;

  useEffect(() => {
    panel.current!.focus();
    return () => {
      [...document.querySelectorAll<HTMLButtonElement>("button[data-attachment-id]")]
        .find(button => button.dataset.attachmentId === openerId)?.focus();
    };
  }, []);

  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if ([...document.querySelectorAll('[aria-modal="true"]')].some(el => el !== panel.current)) return;
      if (event.key === "Tab") {
        event.preventDefault();
        event.stopPropagation();
        const buttons = [...panel.current!.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
        const focused = buttons.indexOf(document.activeElement as HTMLButtonElement);
        const next = focused < 0 ? (event.shiftKey ? buttons.length - 1 : 0)
          : (focused + (event.shiftKey ? -1 : 1) + buttons.length) % buttons.length;
        buttons[next]?.focus();
        return;
      }
      if (!["Escape", "ArrowLeft", "ArrowRight"].includes(event.key)) return;
      event.preventDefault();
      event.stopPropagation();
      if (event.key === "Escape") onClose();
      else {
        const next = index + (event.key === "ArrowLeft" ? -1 : 1);
        if (images[next]) onSelect(images[next].id);
      }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, [images, index, onClose, onSelect]);

  useEffect(() => {
    let live = true;
    generation.current++;
    setDisplay(d => ({ id: selected, thumbSrc: d?.id === selected ? d.thumbSrc : null,
      thumbSmall: d?.id === selected ? d.thumbSmall : false, originalSrc: null, loaded: false,
      loading: false, note: null, retry: false, originalSmall: false }));
    thumbnail(selected).then(path => {
      if (live) setDisplay(d => d && { ...d, thumbSrc: convertFileSrc(path) });
    }, () => {});
    const stored = attachmentStored(selected);
    stored.then(value => {
      if (live) setDisplay(d => d && !d.originalSrc && !d.note ? { ...d, loading: !value } : d);
    }, () => {});
    let fetching = fetches.current.get(selected);
    if (!fetching) {
      fetching = stored.then(() => attachmentOriginal(selected));
      fetches.current.set(selected, fetching);
      const forget = () => { fetches.current.delete(selected); };
      fetching.then(forget, forget);
    }
    fetching.then(path => {
      if (live) setDisplay(d => d && { ...d, originalSrc: convertFileSrc(path) });
    }, err => {
      if (live) setDisplay(d => d && { ...d, loading: false, note: String(err), retry: true });
    });
    return () => { live = false; generation.current++; };
  }, [selected, attempt]);

  function clampView(next: View): View {
    if (next.scale === 1) return { scale: 1, x: 0, y: 0 };
    const bounds = stage.current!.getBoundingClientRect();
    const wrapper = imageWrapper.current!;
    const image = wrapper.querySelector<HTMLImageElement>("img:not(.is-loading)");
    let width = wrapper.clientWidth;
    let height = wrapper.clientHeight;
    if (image?.naturalWidth && image.naturalHeight) {
      const fit = Math.min(width / image.naturalWidth, height / image.naturalHeight,
        image.classList.contains("is-small") ? 1 : Infinity);
      width = image.naturalWidth * fit;
      height = image.naturalHeight * fit;
    }
    const maxX = Math.max(0, (width * next.scale - bounds.width) / 2);
    const maxY = Math.max(0, (height * next.scale - bounds.height) / 2);
    return { scale: next.scale, x: Math.max(-maxX, Math.min(maxX, next.x)),
      y: Math.max(-maxY, Math.min(maxY, next.y)) };
  }

  function zoomAt(scale: (previous: number) => number, clientX?: number, clientY?: number) {
    const bounds = stage.current!.getBoundingClientRect();
    const x = clientX === undefined ? 0 : clientX - bounds.left - bounds.width / 2;
    const y = clientY === undefined ? 0 : clientY - bounds.top - bounds.height / 2;
    setView(previous => {
      const boundedScale = Math.max(1, Math.min(6, scale(previous.scale)));
      const nextScale = boundedScale < 1.01 && boundedScale < previous.scale ? 1 : boundedScale;
      const ratio = nextScale / previous.scale;
      return clampView({ scale: nextScale, x: x - (x - previous.x) * ratio,
        y: y - (y - previous.y) * ratio });
    });
  }

  useEffect(() => {
    setView({ scale: 1, x: 0, y: 0 });
    drag.current = null;
  }, [selected]);

  useEffect(() => {
    const element = stage.current!;
    let gestureScale = 1;
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? element.clientHeight : 1);
      zoomAt(scale => scale * Math.exp(-delta * (event.ctrlKey ? 0.01 : 0.002)), event.clientX, event.clientY);
    };
    const gestureStart = (event: Event) => {
      event.preventDefault();
      drag.current = null;
      gestureScale = viewRef.current.scale;
    };
    const gestureChange = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX?: number; clientY?: number };
      zoomAt(() => gestureScale * gesture.scale, gesture.clientX, gesture.clientY);
    };
    const resize = () => setView(current => clampView(current));
    window.addEventListener("resize", resize);
    element.addEventListener("wheel", wheel, { passive: false });
    element.addEventListener("gesturestart", gestureStart, { passive: false });
    element.addEventListener("gesturechange", gestureChange, { passive: false });
    return () => {
      window.removeEventListener("resize", resize);
      element.removeEventListener("wheel", wheel);
      element.removeEventListener("gesturestart", gestureStart);
      element.removeEventListener("gesturechange", gestureChange);
    };
  }, []);

  async function failedDisplay() {
    const version = generation.current;
    try {
      const stored = await attachmentStored(selected);
      if (version === generation.current) setDisplay(d => d && { ...d, originalSrc: null, loaded: false,
        loading: false, note: stored ? "This image can't be shown here." : "Couldn't load this image", retry: !stored });
    } catch (err) {
      if (version === generation.current) setDisplay(d => d && { ...d, originalSrc: null, loaded: false,
        loading: false, note: String(err), retry: true });
    }
  }

  async function openOriginal() {
    if (opening.current.has(selected)) return;
    opening.current.add(selected);
    const version = generation.current;
    try {
      let fetching = fetches.current.get(selected);
      if (!fetching && current?.retry) {
        setDisplay(d => d && { ...d, loading: true });
        fetching = attachmentOriginal(selected);
        fetches.current.set(selected, fetching);
        const forget = () => { fetches.current.delete(selected); };
        fetching.then(forget, forget);
      }
      if (fetching) {
        const path = await fetching;
        if (version === generation.current) setDisplay(d => d && { ...d, originalSrc: convertFileSrc(path), note: null, retry: false });
      }
      await openAttachment(selected);
    } catch (err) {
      if (version === generation.current) setDisplay(d => d && { ...d, loading: false, note: String(err) });
    } finally {
      opening.current.delete(selected);
    }
  }

  return (
    <div ref={panel} tabIndex={-1} role="dialog" aria-modal="true" aria-label={filename} className="nb-viewer">
      <div className="nb-viewer-bar">
        <button type="button" aria-label="Close image" onClick={onClose}><Icon name="x" /></button>
        <span>{filename}</span>
        <button type="button" onClick={openOriginal}>Open original</button>
      </div>
      <div ref={stage} className="nb-viewer-stage"
        onClick={event => { if (event.detail === 1) clickedStage.current = true; }}
        onDoubleClick={event => {
          // Double-clicking a Feed thumbnail lands its second click here; that one must not zoom.
          if (!clickedStage.current || (event.target as HTMLElement).closest("button")) return;
          zoomAt(scale => scale === 1 ? 3 : 1, event.clientX, event.clientY);
        }}
        onPointerDown={event => {
          if (view.scale === 1 || event.button !== 0 || (event.target as HTMLElement).closest("button")) return;
          event.preventDefault();
          drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY };
          event.currentTarget.setPointerCapture(event.pointerId);
        }}
        onPointerMove={event => {
          const previous = drag.current;
          if (!previous || previous.id !== event.pointerId) return;
          const dx = event.clientX - previous.x;
          const dy = event.clientY - previous.y;
          drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY };
          setView(current => clampView({ ...current, x: current.x + dx, y: current.y + dy }));
        }}
        onPointerUp={event => {
          if (drag.current?.id !== event.pointerId) return;
          drag.current = null;
          event.currentTarget.releasePointerCapture(event.pointerId);
        }}
        onPointerCancel={() => { drag.current = null; }}
        onLostPointerCapture={() => { drag.current = null; }}>
        {images.length > 1 && <button type="button" className="nb-viewer-previous" aria-label="Previous image" disabled={index === 0} onClick={() => onSelect(images[index - 1].id)}><Icon name="chevron-left" size={32} /></button>}
        <div ref={imageWrapper} className="nb-viewer-images" style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.scale})` }}>
          {current?.thumbSrc && !current.loaded && <img draggable={false} src={current.thumbSrc} alt={filename}
            className={current.thumbSmall ? "is-small" : undefined}
            onError={() => setDisplay(d => d && { ...d, thumbSrc: null })}
            onLoad={e => {
              const small = Math.max(e.currentTarget.naturalWidth, e.currentTarget.naturalHeight) < 400;
              setDisplay(d => d && { ...d, thumbSmall: small });
            }} />}
          {current?.originalSrc && <img draggable={false} src={current.originalSrc} alt={current.loaded ? filename : ""}
            className={[!current.loaded && "is-loading", current.originalSmall && "is-small"].filter(Boolean).join(" ")}
            onLoad={e => {
              const small = Math.max(e.currentTarget.naturalWidth, e.currentTarget.naturalHeight) < 400;
              setDisplay(d => d && { ...d, loaded: true, loading: false, originalSmall: small });
            }} onError={failedDisplay} />}
        </div>
        {images.length > 1 && <button type="button" className="nb-viewer-next" aria-label="Next image" disabled={index === images.length - 1} onClick={() => onSelect(images[index + 1].id)}><Icon name="chevron-right" size={32} /></button>}
      </div>
      <div className="nb-viewer-footer">
        {current?.loading && <p>Loading full image…</p>}
        {current?.note && <p>{current.note}</p>}
        {current?.note && current.retry && <button type="button" onClick={() => setAttempt(a => a + 1)}><Icon name="restore" size={14} />Retry</button>}
        {images.length > 1 && <p>{index + 1} of {images.length}</p>}
      </div>
    </div>
  );
}
