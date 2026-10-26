import { createRoot } from "react-dom/client";
import { Toaster, sileo } from "sileo";

const TYPES = new Set(["success", "error", "warning", "info", "action"]);

// Called by the native app with a payload it has already reduced to strings.
window.notify = ({ type, title, description, duration }) => {
  const show = TYPES.has(type) ? sileo[type] : sileo.show;
  show({
    title,
    description: description
      ? description.split("\n").map((line, i) => <div key={i}>{line}</div>)
      : undefined,
    duration: duration ?? 6000,
  });
};

createRoot(document.getElementById("root")).render(<Toaster position="top-right" theme="system" />);
