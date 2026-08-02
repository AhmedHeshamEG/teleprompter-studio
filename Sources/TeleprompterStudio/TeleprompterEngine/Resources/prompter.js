(function () {
  "use strict";

  const scroller = document.getElementById("scroller");
  const content = document.getElementById("content");
  const mirrorWrap = document.getElementById("mirror-wrap");
  const guideLine = document.getElementById("guide-line");
  const guideBand = document.getElementById("guide-band");
  const countdownOverlay = document.getElementById("countdown-overlay");
  const countdownNumber = document.getElementById("countdown-number");

  let isPlaying = false;
  let pxPerSecond = 90;
  let lastFrameTime = null;
  let guideMode = "line"; // 'line' | 'band' | 'none'
  let guideIdleTimer = null;
  let lastReportedFraction = -1;
  let lastReportTime = 0;

  function post(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prompter) {
      window.webkit.messageHandlers.prompter.postMessage(message);
    }
  }

  function maxScroll() {
    return Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  }

  function currentFraction() {
    const max = maxScroll();
    return max <= 0 ? 0 : scroller.scrollTop / max;
  }

  function reportProgress(force) {
    const now = performance.now();
    const fraction = currentFraction();
    if (force || now - lastReportTime > 120 || Math.abs(fraction - lastReportedFraction) > 0.002) {
      lastReportedFraction = fraction;
      lastReportTime = now;
      post({ type: "progress", value: fraction, playing: isPlaying });
    }
  }

  function tick(timestamp) {
    if (!isPlaying) { lastFrameTime = null; return; }
    if (lastFrameTime === null) { lastFrameTime = timestamp; }
    const dt = (timestamp - lastFrameTime) / 1000;
    lastFrameTime = timestamp;

    scroller.scrollTop += pxPerSecond * dt;
    reportProgress(false);

    if (scroller.scrollTop >= maxScroll() - 1) {
      isPlaying = false;
      post({ type: "didFinish" });
      reportProgress(true);
      return;
    }
    requestAnimationFrame(tick);
  }

  function renderMath() {
    if (window.renderMathInElement) {
      renderMathInElement(content, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false }
        ],
        throwOnError: false
      });
    }
  }

  const Prompter = {
    setContent(markdown) {
      const html = window.marked ? window.marked.parse(markdown || "") : (markdown || "");
      content.innerHTML = html;
      renderMath();
      reportProgress(true);
    },

    setStyle(opts) {
      const root = document.documentElement.style;
      if (opts.textColor) root.setProperty("--text-color", opts.textColor);
      if (opts.bgColor) root.setProperty("--bg-color", opts.bgColor);
      if (opts.accentColor) root.setProperty("--accent-color", opts.accentColor);
      if (typeof opts.baseSize === "number") root.setProperty("--base-size", opts.baseSize + "px");
      if (typeof opts.lineHeight === "number") root.setProperty("--line-height", String(opts.lineHeight));
      if (typeof opts.marginH === "number") root.setProperty("--margin-h", opts.marginH + "%");
      if (opts.fontName) {
        document.body.className = document.body.className
          .split(" ")
          .filter((c) => !c.startsWith("font-"))
          .concat(["font-" + opts.fontName.replace(/\s+/g, "-")])
          .join(" ");
      }
    },

    setFontSize(px) {
      document.documentElement.style.setProperty("--base-size", px + "px");
    },

    setMirror(horizontal, vertical) {
      const sx = horizontal ? -1 : 1;
      const sy = vertical ? -1 : 1;
      mirrorWrap.style.transform = "scale(" + sx + "," + sy + ")";
    },

    setSpeed(newPxPerSecond) {
      pxPerSecond = Math.max(0, newPxPerSecond);
    },

    play() {
      if (isPlaying) return;
      isPlaying = true;
      lastFrameTime = null;
      requestAnimationFrame(tick);
      post({ type: "playState", playing: true });
    },

    pause() {
      isPlaying = false;
      post({ type: "playState", playing: false });
      reportProgress(true);
    },

    toggle() {
      if (isPlaying) { Prompter.pause(); } else { Prompter.play(); }
    },

    jumpToTop() {
      scroller.scrollTop = 0;
      reportProgress(true);
    },

    jumpToFraction(fraction) {
      const clamped = Math.max(0, Math.min(1, fraction));
      scroller.scrollTop = clamped * maxScroll();
      reportProgress(true);
    },

    setGuide(mode) {
      guideMode = mode;
      guideLine.classList.toggle("guide-hidden", mode !== "line");
      guideBand.classList.toggle("guide-hidden", mode !== "band");
    },

    revealGuideTemporarily() {
      if (guideMode === "none") return;
      guideLine.classList.remove("guide-hidden");
      guideBand.classList.remove("guide-hidden");
      if (guideMode !== "line") guideLine.classList.add("guide-hidden");
      if (guideMode !== "band") guideBand.classList.add("guide-hidden");
      clearTimeout(guideIdleTimer);
      guideIdleTimer = setTimeout(() => {
        if (guideMode === "line") guideLine.classList.add("guide-hidden");
        if (guideMode === "band") guideBand.classList.add("guide-hidden");
      }, 2800);
    },

    startCountdown(seconds) {
      let remaining = Math.ceil(seconds);
      countdownOverlay.classList.remove("hidden");
      countdownNumber.textContent = String(remaining);
      const step = () => {
        remaining -= 1;
        if (remaining <= 0) {
          countdownOverlay.classList.add("hidden");
          Prompter.play();
          post({ type: "countdownComplete" });
          return;
        }
        countdownNumber.textContent = String(remaining);
        setTimeout(step, 1000);
      };
      setTimeout(step, 1000);
    },

    getProgress() {
      reportProgress(true);
    }
  };

  window.Prompter = Prompter;

  document.body.addEventListener("touchstart", () => Prompter.revealGuideTemporarily(), { passive: true });

  window.addEventListener("load", () => {
    post({ type: "ready" });
  });
})();
