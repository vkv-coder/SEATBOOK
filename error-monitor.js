// ===== khursilo error monitor =====
var RELAY_URL = "https://script.google.com/macros/s/AKfycbxL74pGhZhcWKGH-ZClwmIPWFH-pDeMW8L9itOoy-sxoZext2reTSvy0amjhx193CNFyQ/exec";

function khursiloLogError(message, source) {
  fetch(RELAY_URL, {
    method: "POST",
    body: JSON.stringify({
      page: window.location.pathname,
      message: message,
      source: source || "khursilo.in",
      userAgent: navigator.userAgent
    })
  }).then(function(res) {
    console.log("Error reported, status:", res.status);
  }).catch(function(err) {
    console.log("Error reporting FAILED:", err);
  });
}

window.onerror = function (msg, url, line) {
  khursiloLogError(msg + " (line " + line + ")");
};

window.addEventListener("unhandledrejection", function (e) {
  khursiloLogError("Promise error: " + (e.reason && e.reason.message ? e.reason.message : e.reason));
});
