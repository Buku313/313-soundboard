(function () {
	"use strict";

	var SOUNDBOARD_URL = "http://178.156.220.61:3000";
	var panelOpen = false;

	function init() {
		// Toggle button
		var toggle = document.createElement("button");
		toggle.id = "mi-soundboard-toggle";
		toggle.title = "313 Soundboard";
		var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
		svg.setAttribute("viewBox", "0 0 24 24");
		var path = document.createElementNS("http://www.w3.org/2000/svg", "path");
		path.setAttribute("d", "M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z");
		svg.appendChild(path);
		toggle.appendChild(svg);
		document.body.appendChild(toggle);

		// Panel with iframe
		var panel = document.createElement("div");
		panel.id = "mi-soundboard-panel";

		var iframe = document.createElement("iframe");
		iframe.src = SOUNDBOARD_URL;
		iframe.id = "mi-soundboard-iframe";
		iframe.setAttribute("allow", "autoplay");
		panel.appendChild(iframe);
		document.body.appendChild(panel);

		toggle.addEventListener("click", function () {
			panelOpen = !panelOpen;
			panel.classList.toggle("open", panelOpen);
		});
	}

	if (document.readyState === "complete" || document.readyState === "interactive") {
		setTimeout(init, 500);
	} else {
		document.addEventListener("DOMContentLoaded", function () { setTimeout(init, 500); });
	}
})();
