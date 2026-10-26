import { createRoot } from "react-dom/client";
import { Toaster, sileo } from "sileo";

const TYPES = new Set(["success", "error", "warning", "info", "action"]);
// Every toast shown, by number; the number rides on the title's class so a click finds its toast.
// shortcut: never pruned, a few bytes per toast; prune if kyvia ever runs for months under heavy load.
const shown = [];

// Called by the native app with a payload it has already reduced to strings.
window.notify = ({ type, title, description, duration, app, path }) => {
  const show = TYPES.has(type) ? sileo[type] : sileo.show;
  const n = shown.length;
  shown.push({ app, path });
  shown[n].id = show({
    title,
    description: description
      ? description.split("\n").map((line, i) => <div key={i}>{line}</div>)
      : undefined,
    duration: duration ?? 6000,
    styles: { title: `kyvia-${n}` },
  });
};

// A click on a toast closes it and asks the app to bring its source forward.
document.addEventListener("click", (e) => {
  const tag = e.target.closest("[data-sileo-toast]")?.querySelector("[class^='kyvia-']");
  if (!tag) return;
  const { id, app, path } = shown[tag.className.slice(6)];
  sileo.dismiss(id);
  window.webkit.messageHandlers.focus.postMessage({ app: app ?? "", path: path ?? "" });
});

createRoot(document.getElementById("root")).render(<Toaster position="top-right" theme="system" />);
