(function () {
  "use strict";

  const scriptListEl = document.getElementById("script-list");
  const titleInput = document.getElementById("title-input");
  const markdownInput = document.getElementById("markdown-input");
  const preview = document.getElementById("preview");
  const saveStatus = document.getElementById("save-status");
  const newScriptBtn = document.getElementById("new-script-btn");

  let scripts = [];
  let activeID = null;
  let saveTimer = null;

  async function api(path, options) {
    const response = await fetch(path, options);
    if (response.status === 204) return null;
    return response.json();
  }

  async function loadScriptList() {
    scripts = await api("/api/scripts");
    renderScriptList();
    if (!activeID && scripts.length > 0) {
      selectScript(scripts[0].id);
    }
  }

  function renderScriptList() {
    scriptListEl.innerHTML = "";
    for (const script of scripts) {
      const item = document.createElement("div");
      item.className = "script-item" + (script.id === activeID ? " active" : "");
      item.innerHTML =
        '<span class="title">' + escapeHTML(script.title || "Untitled Script") + "</span>" +
        '<span class="meta">' + script.wordCount + " words</span>";
      item.addEventListener("click", () => selectScript(script.id));
      scriptListEl.appendChild(item);
    }
  }

  async function selectScript(id) {
    activeID = id;
    renderScriptList();
    const script = await api("/api/scripts/" + id);
    titleInput.value = script.title || "";
    markdownInput.value = script.bodyMarkdown || "";
    renderPreview();
  }

  function renderPreview() {
    const html = window.marked ? window.marked.parse(markdownInput.value || "") : "";
    preview.innerHTML = html;
    if (window.renderMathInElement) {
      renderMathInElement(preview, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false }
        ],
        throwOnError: false
      });
    }
  }

  function scheduleSave() {
    saveStatus.textContent = "Saving…";
    clearTimeout(saveTimer);
    saveTimer = setTimeout(saveActiveScript, 500);
  }

  async function saveActiveScript() {
    if (!activeID) return;
    await api("/api/scripts/" + activeID, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: titleInput.value, bodyMarkdown: markdownInput.value })
    });
    saveStatus.textContent = "Saved";
    const script = scripts.find((s) => s.id === activeID);
    if (script) script.title = titleInput.value;
    renderScriptList();
  }

  async function createScript() {
    const script = await api("/api/scripts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Untitled Script", bodyMarkdown: "" })
    });
    await loadScriptList();
    selectScript(script.id);
  }

  function escapeHTML(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  titleInput.addEventListener("input", scheduleSave);
  markdownInput.addEventListener("input", () => {
    renderPreview();
    scheduleSave();
  });
  newScriptBtn.addEventListener("click", createScript);

  loadScriptList();
  setInterval(loadScriptList, 5000); // picks up edits made live from the app
})();
