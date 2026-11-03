"use strict";

document.documentElement.classList.add("js");

const menuButton = document.querySelector(".menu-toggle");
const sidebar = document.querySelector(".sidebar");
const mobileLayout = window.matchMedia("(max-width: 800px)");

function closeMenu(restoreFocus = false) {
  if (!menuButton || !sidebar) return;
  menuButton.setAttribute("aria-expanded", "false");
  sidebar.removeAttribute("data-open");
  if (restoreFocus) menuButton.focus();
}

menuButton?.addEventListener("click", () => {
  const open = menuButton.getAttribute("aria-expanded") !== "true";
  menuButton.setAttribute("aria-expanded", String(open));
  sidebar?.toggleAttribute("data-open", open);
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && menuButton?.getAttribute("aria-expanded") === "true") {
    closeMenu(true);
  }
});

sidebar?.querySelectorAll('a[href^="#"]').forEach((link) => {
  link.addEventListener("click", () => {
    if (!mobileLayout.matches) return;
    closeMenu();
    const target = document.getElementById(link.hash.slice(1));
    if (target) {
      target.setAttribute("tabindex", "-1");
      target.focus({ preventScroll: true });
    }
  });
});

mobileLayout.addEventListener("change", () => closeMenu());

document.querySelectorAll("[data-tabs]").forEach((group) => {
  const tabs = Array.from(group.querySelectorAll('[role="tab"]'));

  function activateTab(selected, focus = false) {
    tabs.forEach((tab) => {
      const active = tab === selected;
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute("aria-controls"));
      if (panel) panel.hidden = !active;
    });
    if (focus) selected.focus();
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => activateTab(tab));
    tab.addEventListener("keydown", (event) => {
      let nextIndex;
      if (event.key === "ArrowRight") nextIndex = (index + 1) % tabs.length;
      else if (event.key === "ArrowLeft") nextIndex = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === "Home") nextIndex = 0;
      else if (event.key === "End") nextIndex = tabs.length - 1;
      else return;
      event.preventDefault();
      activateTab(tabs[nextIndex], true);
    });
  });
  if (tabs.length) activateTab(tabs.find((tab) => tab.getAttribute("aria-selected") === "true") || tabs[0]);
});

const statusRegion = document.getElementById("copy-status");
const copyTimers = new WeakMap();

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    if (button.dataset.copyPending === "true") return;
    const source = document.getElementById(button.dataset.copy);
    if (!source) return;
    const text = source.textContent || "";
    window.clearTimeout(copyTimers.get(button));
    button.dataset.copyPending = "true";
    button.setAttribute("aria-busy", "true");
    button.removeAttribute("data-copied");
    if (statusRegion) statusRegion.textContent = "";
    try {
      if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
      button.setAttribute("data-copied", "");
      if (statusRegion) statusRegion.textContent = "Command copied to clipboard.";
    } catch {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(source);
      selection?.removeAllRanges();
      selection?.addRange(range);
      button.textContent = "Selected";
      if (statusRegion) statusRegion.textContent = "Automatic copy is unavailable. The command is selected. Press Command+C on Mac or Control+C to copy.";
    } finally {
      delete button.dataset.copyPending;
      button.removeAttribute("aria-busy");
      copyTimers.set(button, window.setTimeout(() => {
        button.textContent = "Copy";
        button.removeAttribute("data-copied");
      }, 2200));
    }
  });
});

const navLinks = Array.from(document.querySelectorAll('.sidebar nav a[href^="#"]'));
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
    if (!visible.length) return;
    const activeId = visible[0].target.id;
    navLinks.forEach((link) => {
      if (link.hash === "#" + activeId) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
  }, { rootMargin: "-12% 0px -65% 0px", threshold: 0 });
  document.querySelectorAll("main > section[id]").forEach((section) => observer.observe(section));
}
