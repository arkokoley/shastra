"use strict";
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const screenshots = {
  workspace: {
    file: "workspace-files.png",
    caption:
      "The real Shastra workspace, with a conversation and file preview.",
    alt: "Shastra running on macOS, with its development conversation and README open side by side.",
  },
  newchat: {
    file: "new-chat.png",
    caption: "Start a new conversation in Shastra.",
    alt: "The actual Shastra new-chat screen on macOS.",
  },
  agents: {
    file: "agents-workspace.png",
    caption: "The Agents workspace, showing a completed verification task.",
    alt: "The actual Agents workspace showing a disposable isolation verification task.",
  },
  context: {
    file: "project-context.png",
    caption: "The native project-context editor, shown with a prepared draft.",
    alt: "The actual Shastra project-context editor with prepared instruction and decision drafts.",
  },
};
const screenshotImage = document.querySelector("#product-screenshot");
const screenshotLink = document.querySelector(".product-screenshot-link");
document.querySelector(".tour-controls").hidden = false;
document.querySelectorAll("[data-view]").forEach((button) =>
  button.addEventListener("click", () => {
    const view = screenshots[button.dataset.view];
    if (!view || button.getAttribute("aria-pressed") === "true") return;
    document
      .querySelectorAll("[data-view]")
      .forEach((control) =>
        control.setAttribute("aria-pressed", String(control === button)),
      );
    const path = `assets/screenshots/${view.file}`;
    screenshotImage.src = path;
    screenshotImage.alt = view.alt;
    screenshotLink.href = path;
    document.querySelector("#tour-caption").textContent = view.caption;
    if (!reducedMotion.matches)
      screenshotImage.animate([{ opacity: 0.2 }, { opacity: 1 }], {
        duration: 280,
      });
  }),
);
const dialog = document.querySelector(".screenshot-dialog");
if (typeof dialog.showModal === "function") {
  document.querySelectorAll("[data-screenshot]").forEach((link) =>
    link.addEventListener("click", (event) => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
        return;
      event.preventDefault();
      const image = document.querySelector("#expanded-screenshot");
      image.src = link.href;
      document.querySelector("#original-screenshot").href = link.href;
      image.alt = link.querySelector("img").alt;
      dialog.showModal();
    }),
  );
  document
    .querySelector(".close-screenshot")
    .addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) dialog.close();
  });
}
const copyButton = document.querySelector("#copy-setup");
if (navigator.clipboard && window.isSecureContext) {
  copyButton.hidden = false;
  copyButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(
        document.querySelector("#setup-code").textContent,
      );
      document.querySelector("#copy-status").textContent = "Commands copied.";
      copyButton.textContent = "Copied";
    } catch {
      document.querySelector("#copy-status").textContent =
        "Select the commands above and copy them manually.";
    }
  });
}
if (!reducedMotion.matches && "IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries
        .filter((entry) => entry.isIntersecting)
        .forEach((entry, index) => {
          entry.target.style.setProperty(
            "--delay",
            `${Math.min(index, 3) * 65}ms`,
          );
          entry.target.classList.add("is-revealing");
          observer.unobserve(entry.target);
        });
    },
    { threshold: 0.06 },
  );
  document
    .querySelectorAll("[data-reveal]")
    .forEach((element) => observer.observe(element));
}
