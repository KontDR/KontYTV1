import Foundation

/// The script that goes into the YouTube page before anything else loads.\n///\n/// It does five things, all local to this web view:\n/// 1. strips ad keys (`adPlacements`, `playerAds`, `adSlots`, `adBreakHeartbeatParams` …) out of the\n///    player response so the player never receives an ad to schedule,\n/// 2. hides ad overlay furniture (promoted slots, ad containers, ad progress bars, companion ads),\n/// 3. presses YouTube's own Skip / Atla / Geç button the instant it appears,\n/// 4. if an ad is still playing, mutes it and jumps straight to the real video source (end of ad),\n/// 5. detects ad markers on the video element and fast-forwards past them.\n///\n/// Everything is wrapped in try/catch: if YouTube changes shape, the page plays exactly as it would\n/// without the script. Nothing is proxied, nothing leaves the device.
enum SiteAdBlock {
    static let script = #"""
    (function () {
      "use strict";
      try {
        var AD_KEYS = ["adPlacements", "playerAds", "adSlots", "adBreakHeartbeatParams", "adBreakServiceRenderer", "adCues", "adPodIds"];
        function scrub(value, depth) {
          if (!value || typeof value !== "object" || (depth || 0) > 6) { return value; }
          for (var i = 0; i < AD_KEYS.length; i++) { try { delete value[AD_KEYS[i]]; } catch (e) {} }
          if (value.playerResponse) { scrub(value.playerResponse, (depth || 0) + 1); }
          if (value.playerConfig && value.playerConfig.adConfig) { try { delete value.playerConfig.adConfig; } catch (e) {} }
          if (value.playabilityStatus && value.playabilityStatus.contextParams) {
            try { delete value.playabilityStatus.contextParams; } catch (e) {}
          }
          return value;
        }
        function isPlayerCall(url) {
          return typeof url === "string" && url.indexOf("/youtubei/v1/player") !== -1;
        }
        function expose(xhr, text) {
          try { Object.defineProperty(xhr, "responseText", { value: text, configurable: true }); } catch (e) {}
          try { Object.defineProperty(xhr, "response", { value: text, configurable: true }); } catch (e) {}
        }
        function rewrite(xhr) {
          try {
            var data = JSON.parse(xhr.responseText);
            scrub(data, 0);
            expose(xhr, JSON.stringify(data));
          } catch (e) {}
        }

        var nativeOpen = XMLHttpRequest.prototype.open;
        var nativeSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { this.__kontytAd = isPlayerCall(url); } catch (e) {}
          return nativeOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          var xhr = this;
          try {
            if (xhr.__kontytAd) {
              xhr.addEventListener("readystatechange", function () {
                if (xhr.readyState === 4) { rewrite(xhr); }
              });
            }
          } catch (e) {}
          return nativeSend.apply(this, arguments);
        };

        var nativeFetch = window.fetch;
        if (nativeFetch) {
          window.fetch = function (input) {
            var url = (typeof input === "string") ? input : (input && input.url);
            var call = nativeFetch.apply(this, arguments);
            if (!isPlayerCall(url) || !call || typeof call.then !== "function") { return call; }
            return call.then(function (response) {
              try {
                return response.clone().json().then(function (data) {
                  scrub(data, 0);
                  return new Response(JSON.stringify(data), {
                    status: response.status,
                    statusText: response.statusText,
                    headers: response.headers
                  });
                }).catch(function () { return response; });
              } catch (e) { return response; }
            }).catch(function () { return call; });
          };
        }

        var SKIP_WORDS = /(^|[^a-z])(skip|atla|ge[cç]|passer|saltar|geç|reklamı atla|skip ad)/i;
        function shown(el) {
          try {
            if (!el || el.disabled) { return false; }
            var box = el.getBoundingClientRect();
            if (box.width < 2 || box.height < 2) { return false; }
            var style = window.getComputedStyle(el);
            return !!style && style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
          } catch (e) { return false; }
        }
        function wording(el) {
          try {
            var label = (el.getAttribute && (el.getAttribute("aria-label") || el.getAttribute("title"))) || "";
            return label + " " + ((el.innerText || el.textContent || "")).slice(0, 60);
          } catch (e) { return ""; }
        }
        function insidePlayer(el) {
          try { return !!(el.closest && el.closest('#movie_player, .html5-video-player, .ytp-ad-module, ytm-player, .player-container')); }
          catch (e) { return false; }
        }
        function adOnScreen() {
          try {
            return !!document.querySelector('.ad-showing, .ytp-ad-player-overlay, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-module, [class*="ad-showing"]');
          } catch (e) { return false; }
        }
        function isAdVideo(video) {
          try {
            if (!video || !video.duration) { return false; }
            // Ads are usually very short (under 60s) and have ad markers nearby
            if (video.duration > 0 && video.duration < 60) { return true; }
            if (document.querySelector('.ad-showing, .ytp-ad-player-overlay, .ytp-ad-module')) { return true; }
            return false;
          } catch (e) { return false; }
        }
        /// Press only real ad Skip / Atla / Geç buttons inside the player.
        /// Normal "Sonraki / Next" navigation buttons are never touched.
        function pressSkip() {
          var pressed = 0;
          try {
            var nodes = document.querySelectorAll("button, [role=button]");
            for (var i = 0; i < nodes.length && pressed < 3; i++) {
              var el = nodes[i];
              if (!shown(el)) { continue; }
              if (!el.closest || !el.closest('#movie_player, .html5-video-player, .ytp-ad-module, ytm-player, .player-container')) { continue; }
              if (!SKIP_WORDS.test(wording(el))) { continue; }
              try { el.click(); pressed++; } catch (e) {}
            }
          } catch (e) {}
          return pressed;
        }
        function skip() {
          try {
            pressSkip();
            var video = document.querySelector("video");
            if (video && isAdVideo(video)) {
              try { video.muted = true; } catch (e) {}
              // Jump straight to the end of the ad / real video source
              if (isFinite(video.duration) && video.duration > 0) {
                try { video.currentTime = video.duration; } catch (e) {}
              }
            }
          } catch (e) {}
        }
        var lastPress = 0;
        function pressSoon() {
          var now = Date.now();
          if (now - lastPress < 100) { return; }
          lastPress = now;
          pressSkip();
        }
        try {
          var watcher = new MutationObserver(pressSoon);
          watcher.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "style", "disabled"] });
        } catch (e) {}

        var css = "ytm-promoted-sparkles-web-renderer,ytd-promoted-sparkles-web-renderer,ytd-display-ad-renderer," +
          "ytd-ad-slot-renderer,ytm-companion-ad-renderer,#player-ads,.ytp-ad-overlay-container,.ytp-ad-progress-list{display:none !important}";
        function hideSlots() {
          try {
            if (document.getElementById("kontyt-adblock")) { return; }
            var style = document.createElement("style");
            style.id = "kontyt-adblock";
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          } catch (e) {}
        }

        hideSlots();
        if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", hideSlots); }
        setInterval(skip, 150);
        setInterval(hideSlots, 800);
        window.__kontytAdBlock = true;
        window.__kontytSkip = pressSkip;
      } catch (e) {}
    })();
    """#
}

/// Runs in every YouTube page before the site's own code. It only announces that this web view means to
/// keep playing audio - without it WebKit suspends the page as soon as the app is backgrounded, and the
/// sound dies with it. (`navigator.audioSession` is Safari 16.4+; older systems simply ignore the call.)
enum SitePlayback {
    static let script = #"""
    (function () {
      "use strict";
      window.__kontytWantPlay = false;
      function announce() {
        try { if (navigator.audioSession) { navigator.audioSession.type = "playback"; } } catch (e) {}
      }
      function videoID() {
        try {
          var href = location.href;
          var found = href.match(/[?&]v=([A-Za-z0-9_-]{11})/) || href.match(/youtu\\.be\\/([A-Za-z0-9_-]{11})/) ||
            href.match(/shorts\\/([A-Za-z0-9_-]{11})/);
          return found ? found[1] : "";
        } catch (e) { return ""; }
      }
      function channelName() {
        var selectors = ["ytm-slim-video-metadata-section-renderer a", '#owner #channel-name a',
          ".slim-video-information-channel-name", "a[href*='/@']", "a[href*='/channel/']"];
        for (var i = 0; i < selectors.length; i++) {
          try {
            var node = document.querySelector(selectors[i]);
            if (node && node.textContent) {
              var name = node.textContent.trim().slice(0, 60);
              if (name) { return name; }
            }
          } catch (e) {}
        }
        return "";
      }
      function publish() {
        try {
          var session = navigator.mediaSession;
          if (!session) { return; }
          var video = document.querySelector("video");
          var title = (document.title || "").replace(" - YouTube", "").trim();
          var id = videoID();
          if (title && window.MediaMetadata) {
            var artwork = id ? [{ src: "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg", sizes: "480x360", type: "image/jpeg" }] : [];
            var meta = { title: title, artist: channelName(), album: "YouTube", artwork: artwork };
            session.metadata = new window.MediaMetadata(meta);
          }
          if (video) {
            session.playbackState = video.paused ? "paused" : "playing";
          }
        } catch (e) {}
      }
      function actions() {
        var session = navigator.mediaSession;
        if (!session) { return; }
        function set(name, handler) { try { session.setActionHandler(name, handler); } catch (e) {} }
        function video() { try { return document.querySelector("video"); } catch (e) { return null; } }
        set("play", function () { var v = video(); if (v) { window.__kontytWantPlay = true; v.play(); } });
        set("pause", function () { var v = video(); if (v) { window.__kontytWantPlay = false; v.pause(); } publish(); });
        set("nexttrack", function () {
          try {
            var button = document.querySelector(".ytp-next-button, .ytp-next-button-modern, .next-button, [aria-label='Next']");
            if (button) { button.click(); }
          } catch (e) {}
        });
        set("previoustrack", function () { try { history.back(); } catch (e) {} });
      }
      function stayVisible() {
        var pairs = [["hidden", false], ["visibilityState", "visible"], ["webkitHidden", false], ["webkitVisibilityState", "visible"]];
        function pin(name, value) {
          try {
            if (document[name] !== undefined) {
              Object.defineProperty(document, name, { get: function () { return value; }, configurable: true });
            }
          } catch (e) {}
        }
        for (var i = 0; i < pairs.length; i++) { pin(pairs[i][0], pairs[i][1]); }
      }
      function player() { try { return document.querySelector("video"); } catch (e) { return null; } }
      function play() {
        var video = player();
        if (!video) { return; }
        try { var call = video.play(); if (call && call.catch) { call.catch(function () {}); } } catch (e) {}
      }
      window.__kontytPlay = play;
      window.__kontytPublish = publish;
      function afterGap() {
        announce();
        stayVisible();
        actions();
        publish();
        if (window.__kontytWantPlay) { play(); }
      }
      stayVisible();
      announce();
      actions();
      publish();
      document.addEventListener("play", function (event) {
        if (event && event.target && event.target.tagName === "VIDEO") { window.__kontytWantPlay = true; announce(); publish(); }
      }, true);
      document.addEventListener("pause", function (event) {
        if (event && event.target && event.target.tagName === "VIDEO") {
          window.__kontytWantPlay = false;
          publish();
        }
      }, true);
      document.addEventListener("playing", function (event) {
        if (event && event.target && event.target.tagName === "VIDEO") { announce(); publish(); }
      }, true);
      document.addEventListener("timeupdate", function (event) {
        if (event && event.target && event.target.tagName === "VIDEO") { publish(); }
      }, true);
      document.addEventListener("loadedmetadata", function () { publish(); }, true);
      document.addEventListener("DOMContentLoaded", afterGap);
      document.addEventListener("visibilitychange", afterGap);
      window.addEventListener("pageshow", afterGap);
      window.addEventListener("focus", afterGap);
      setInterval(function () { announce(); actions(); publish(); if (window.__kontytWantPlay) { play(); } }, 2000);
    })();
    """#
}
