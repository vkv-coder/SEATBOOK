// ===== khursilo error monitor =====
var RELAY_URL = "https://script.google.com/macros/s/AKfycbxL74pGhZhcWKGH-ZClwmIPWFH-pDeMW8L9itOoy-sxoZext2reTSvy0amjhx193CNFyQ/exec";

function reportError(message, source) {
  try {
    fetch(RELAY_URL, {
      method: "POST",
      body: JSON.stringify({
        page: window.location.pathname,
        message: message,
        source: source || "khursilo.in",
        userAgent: navigator.userAgent
      })
    });
  } catch (e) {}
}

window.onerror = function (msg, url, line) {
  reportError(msg + " (line " + line + ")");
};

window.addEventListener("unhandledrejection", function (e) {
  reportError("Promise error: " + (e.reason && e.reason.message ? e.reason.message : e.reason));
});
