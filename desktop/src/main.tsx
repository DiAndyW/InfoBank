import React from "react";
import ReactDOM from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "./App";
import QuickCapture from "./QuickCapture";
import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";
import "@fontsource-variable/source-serif-4/opsz.css";
import "./tokens.css";
import "./styles.css";

const quick = getCurrentWindow().label === "quick-capture";
if (quick) document.documentElement.classList.add("nb-quick-window");

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(<React.StrictMode>{quick ? <QuickCapture /> : <App />}</React.StrictMode>);
