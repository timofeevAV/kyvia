import { createRoot } from "react-dom/client";
import { Toaster, sileo } from "sileo";

const TYPES = new Set(["success", "error", "warning", "info", "action"]);
// Every toast shown, by number; the number rides on the title's class so a click finds its toast.
// shortcut: never pruned, a few bytes per toast; prune if kyvia ever runs for months under heavy load.
const shown = [];

// Called by the native app with a payload it has already reduced to strings.
// A question toast also has options (labels) and ask (the number the app waits on).
window.notify = ({ type, title, description, duration, app, path, options, ask }) => {
  const show = TYPES.has(type) ? sileo[type] : sileo.show;
  const n = shown.length;
  shown.push({ app, path, ask });
  const content = [
    ...(description ? description.split("\n") : []).map((line, i) => <div key={i}>{line}</div>),
    ...(options ?? []).map((label, i) => // The toast itself is a <button>, so an option is a div acting as one.
    <div key={`o${i}`} role="button" data-kyvia-option={i} data-sileo-button data-state="action">{label}</div>),
  ];
  shown[n].id = show({
    // sileo replaces a toast by id ("sileo-default" when unset); a question keeps its own so a newer toast cannot hide it.
    id: ask ? `kyvia-ask-${ask}` : undefined,
    title,
    description: content.length ? content : undefined,
    duration: duration ?? 6000,
    styles: { title: `kyvia-${n}` },
  });
};

// A click on a toast closes it. An option answers the question; anywhere else asks the app to bring the
// toast's source forward (and leaves a question to the terminal).
document.addEventListener("click", (e) => {
  const toast = e.target.closest("[data-sileo-toast]");
  const tag = toast?.querySelector("[class^='kyvia-']");
  if (!tag) return;
  const { id, app, path, ask } = shown[tag.className.slice(6)];
  // A collapsed question hides its options; the click only opens it (sileo expands on hover).
  if (ask && toast.dataset.expanded !== "true") return;
  sileo.dismiss(id);
  const option = e.target.closest("[data-kyvia-option]");
  if (option) {
    window.webkit.messageHandlers.answer.postMessage({ ask, option: Number(option.dataset.kyviaOption) });
    return;
  }
  window.webkit.messageHandlers.focus.postMessage({ app: app ?? "", path: path ?? "", ask: ask ?? 0 });
});

// The app reports the pointer (the panel never gets hover of its own); replay it as the mouseover/mouseout
// pair React turns into sileo's onMouseEnter/onMouseLeave, so a toast expands under the pointer.
let hovered = null;
window.hover = (x, y) => {
  const toast = document.elementFromPoint(x, y)?.closest("[data-sileo-toast]") ?? null;
  if (toast !== hovered) {
    hovered?.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: toast ?? document.body }));
    toast?.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, relatedTarget: hovered ?? document.body }));
    hovered = toast;
  }
  return !!toast;
};

createRoot(document.getElementById("root")).render(<Toaster position="top-right" theme="system" />);
