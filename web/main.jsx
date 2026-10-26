import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Toaster, sileo } from "sileo";

const TYPES = new Set(["success", "error", "warning", "info", "action"]);
// Every toast shown, by number; the number rides on the title's class so a click finds its toast.
// shortcut: never pruned, a few bytes per toast; prune if kyvia ever runs for months under heavy load.
const shown = [];

// The questions of one AskUserQuestion call, one step at a time. A lone single-choice question is answered by
// its first click. Otherwise a click picks (toggles in a multi-select question; a single-choice pick moves on),
// Back and Next walk the steps, and Send on the last one answers them all.
function Ask({ ask, questions }) {
  const [picks, setPicks] = useState(() => questions.map(() => []));
  const [step, setStep] = useState(0);
  const last = questions.length - 1;
  const { question, options, multi } = questions[step];
  const send = (answer) => {
    sileo.dismiss(`kyvia-ask-${ask}`);
    window.webkit.messageHandlers.answer.postMessage({ ask, picks: answer });
  };
  const pick = (o) => {
    if (!last && !multi) return send([[o]]);
    const toggle = (p) => (p.includes(o) ? p.filter((x) => x !== o) : [...p, o]);
    setPicks(picks.map((p, i) => (i !== step ? p : multi ? toggle(p) : [o])));
    if (!multi && step < last) setStep(step + 1);
  };
  const ready = picks[step].length > 0;
  // The toast itself is a <button>, so an option is a div acting as one; a picked one takes sileo's success colour,
  // Back and a button not usable yet sileo's grey, so neither reads as an answer.
  const button = (key, label, state, onClick) => (
    <div key={key} role="button" data-kyvia-option data-sileo-button data-state={state} onClick={onClick}>{label}</div>
  );
  const row = (justifyContent, children) => <div style={{ display: "flex", flexWrap: "wrap", columnGap: "0.375rem", justifyContent }}>{children}</div>;
  const counter = last ? `${step + 1}/${questions.length} · ` : "";
  return (
    <>
      <div style={{ whiteSpace: "pre-line" }}>{`${counter}${question}${multi ? " · any" : ""}`}</div>
      {row("flex-start", options.map((label, o) => button(o, label, picks[step].includes(o) ? "success" : "action", () => pick(o))))}
      {(last > 0 || multi) && row("space-between", [
        step > 0 ? button("back", "Back", "loading", () => setStep(step - 1)) : <span key="back" />,
        step < last
          ? button("next", "Next", ready ? "action" : "loading", () => ready && setStep(step + 1))
          : button("send", "Send", ready ? "action" : "loading", () => ready && send(picks)),
      ])}
    </>
  );
}

// Called by the native app with a payload it has already reduced to strings.
// A question toast also has questions ({question, options, multi}) and ask (the number the app waits on).
window.notify = ({ type, title, description, duration, app, path, questions, ask }) => {
  const show = TYPES.has(type) ? sileo[type] : sileo.show;
  const n = shown.length;
  shown.push({ app, path, ask });
  const lines = description ? description.split("\n").map((line, i) => <div key={i}>{line}</div>) : undefined;
  shown[n].id = show({
    // sileo replaces a toast by id ("sileo-default" when unset); a question keeps its own so a newer toast cannot hide it.
    id: ask ? `kyvia-ask-${ask}` : undefined,
    title,
    description: questions ? <Ask ask={ask} questions={questions} /> : lines,
    duration: duration ?? 6000,
    // sileo's autopilot collapses a toast 4 s after it appears, even under the pointer; a question stays open
    // until answered or left (sileo clamps the delay to the duration).
    autopilot: ask ? { collapse: Infinity } : undefined,
    styles: { title: `kyvia-${n}` },
  });
};

// The app closes a question it has answered or left to the terminal; an id already gone does nothing.
window.dismissAsk = (ask) => sileo.dismiss(`kyvia-ask-${ask}`);

// A click on a toast outside its options closes it and asks the app to bring the toast's source forward
// (and leaves a question to the terminal). Options are Ask's.
document.addEventListener("click", (e) => {
  if (e.target.closest("[data-kyvia-option]")) return;
  const toast = e.target.closest("[data-sileo-toast]");
  const tag = toast?.querySelector("[class^='kyvia-']");
  if (!tag) return;
  const { id, app, path, ask } = shown[tag.className.slice(6)];
  // A collapsed question hides its options; the click only opens it (sileo expands on hover).
  if (ask && toast.dataset.expanded !== "true") return;
  sileo.dismiss(id);
  window.webkit.messageHandlers.focus.postMessage({ app: app ?? "", path: path ?? "", ask: ask ?? 0 });
});

// The app asks for the CSS cursor under the pointer, null off a toast; only over a toast does the panel take the mouse.
window.toastCursor = (x, y) => {
  const el = document.elementFromPoint(x, y);
  return el?.closest("[data-sileo-toast]") ? getComputedStyle(el).cursor : null;
};

createRoot(document.getElementById("root")).render(<Toaster position="top-right" theme="system" />);
