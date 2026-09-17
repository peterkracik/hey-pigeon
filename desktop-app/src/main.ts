import { mount } from "svelte";
import "./app.css";
import App from "./App.svelte";

// WKWebView has no visible console; pipe webview runtime errors into the Rust
// app log so render crashes (e.g. Svelte each_key_duplicate) are diagnosable.
import { weblog } from "./lib/ipc";
window.addEventListener("error", (e) => weblog(`window.onerror: ${String(e.message)} @${e.filename}:${e.lineno}`));
window.addEventListener("unhandledrejection", (e) => weblog(`unhandledrejection: ${String(e.reason)}`));

const app = mount(App, { target: document.getElementById("app")! });
export default app;
