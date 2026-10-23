// YouTube ads, which the content blocker's URL rules miss: YouTube serves its ads from the same hosts as the videos.
// Run on youtube.com pages while "Block ads and trackers" is on (features/adblock.nim), again and again while a page
// loads, so everything here is idempotent.
//
// 1. The player learns about ads from the player response: ytInitialPlayerResponse in the watch page's HTML, and the
//    /youtubei/v1/player (and /next, /browse, /reel) JSON when the site navigates by itself. Stripping its ad fields
//    (adPlacements, playerAds, adSlots) before the player reads them means no ad is ever scheduled. A setter on
//    window catches the page's own `var ytInitialPlayerResponse = {...}` when this runs first; JSON.parse and
//    Response.json catch the later responses.
// 2. Whatever still gets through (this script came too late for the first response, or an ad was stitched into the
//    stream) is skipped: while the player shows an ad, it's muted, run to its end and its Skip button pressed.
// 3. Ad slots in the page (feed, search, sidebar, masthead) are hidden with CSS, and the "ad blockers violate" dialog
//    is closed and playback resumed.
(function () {
  if (window.__webbyYouTubeAds) { window.__webbyYouTubeAds.prune(); return; }
  var state = window.__webbyYouTubeAds = { pruned: 0, skipped: 0, prune: null };

  var adKeys = ['adPlacements', 'adSlots', 'playerAds'];

  function strip(r) {
    // Removes the ad fields from a player response `r` (or anything shaped like one); true if there were any.
    if (!r || typeof r !== 'object') return false;
    var hit = false;
    for (var i = 0; i < adKeys.length; i++) {
      if (Object.prototype.hasOwnProperty.call(r, adKeys[i])) { try { delete r[adKeys[i]]; hit = true; } catch (e) {} }
    }
    return hit;
  }

  function pruneResponse(o) {
    // A parsed JSON value from YouTube: a player response itself, or a /next or /reel response carrying one.
    if (!o || typeof o !== 'object' || Array.isArray(o)) return o;
    var hit = strip(o);
    if (o.playerResponse) hit = strip(o.playerResponse) || hit;
    if (o.response && o.response.playerResponse) hit = strip(o.response.playerResponse) || hit;
    if (hit) state.pruned++;
    return o;
  }

  // The watch page's own response: trap the global before the page sets it, else strip it where it is.
  function trapGlobal(name) {
    var d = Object.getOwnPropertyDescriptor(window, name);
    if (d && (d.get || d.set)) return;   // trapped already
    var value = d ? d.value : undefined;
    if (value !== undefined) pruneResponse(value);
    try {
      Object.defineProperty(window, name, {
        configurable: true, enumerable: true,
        get: function () { return value; },
        set: function (v) { value = pruneResponse(v); }
      });
    } catch (e) {}
  }

  function prune() {
    trapGlobal('ytInitialPlayerResponse');
    var y = window.ytplayer;
    if (y && y.config && y.config.args && y.config.args.raw_player_response) pruneResponse(y.config.args.raw_player_response);
    var p = document.getElementById('movie_player');
    if (p && typeof p.getPlayerResponse === 'function') { try { pruneResponse(p.getPlayerResponse()); } catch (e) {} }
  }
  state.prune = prune;
  prune();

  // Later responses. Only objects that look like YouTube's are touched, so the cost elsewhere is one property check.
  function looksLikeYouTube(o) {
    return o && typeof o === 'object' && (o.responseContext || o.playerResponse || o.playabilityStatus);
  }
  var parse = JSON.parse;
  JSON.parse = function () {
    var o = parse.apply(this, arguments);
    return looksLikeYouTube(o) ? pruneResponse(o) : o;
  };
  if (window.Response && Response.prototype.json) {
    var json = Response.prototype.json;
    Response.prototype.json = function () {
      return json.apply(this, arguments).then(function (o) { return looksLikeYouTube(o) ? pruneResponse(o) : o; });
    };
  }

  // Page ad slots, and the ad-blocker warning.
  var css = [
    '#masthead-ad', '#player-ads', '#panels > ytd-ads-engagement-panel-content-renderer',
    'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer', 'ytd-statement-banner-renderer',
    'ytd-promoted-sparkles-web-renderer', 'ytd-promoted-video-renderer', 'ytd-display-ad-renderer',
    'ytd-companion-slot-renderer', 'ytd-action-companion-ad-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer',
    'ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)', 'ytd-rich-section-renderer:has(ytd-statement-banner-renderer)',
    'ytm-promoted-sparkles-web-renderer', 'ytm-companion-ad-renderer', 'ad-slot-renderer', 'ytm-ad-slot-renderer',
    '.ytp-ad-overlay-container', '.ytp-ad-image-overlay', '.ytp-featured-product',
    'ytd-enforcement-message-view-model', 'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)'
  ];
  function addStyle() {
    if (document.getElementById('webby-youtube-ads')) return;
    var root = document.head || document.documentElement;
    if (!root) return;
    var s = document.createElement('style');
    s.id = 'webby-youtube-ads';
    // One rule per selector: a selector the engine can't parse (:has) mustn't drop the others.
    s.textContent = css.map(function (c) { return c + '{display:none!important}'; }).join('\n');
    root.appendChild(s);
  }

  // Ads that still play.
  var mutedByUs = false;
  function check() {
    addStyle();
    var player = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
    var video = player && player.querySelector('video');
    var inAd = !!player && (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'));
    if (inAd && video) {
      if (!video.muted) { video.muted = true; mutedByUs = true; }
      var buttons = player.querySelectorAll('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button');
      for (var i = 0; i < buttons.length; i++) buttons[i].click();
      if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
        try { video.currentTime = video.duration; } catch (e) {}
        state.skipped++;
      }
    } else if (mutedByUs && video) {
      video.muted = false;
      mutedByUs = false;
    }
    // The warning dialog pauses the video; with it gone, play on.
    var warning = document.querySelector('ytd-enforcement-message-view-model');
    if (warning) {
      var dialog = warning.closest('tp-yt-paper-dialog') || warning;
      dialog.remove();
      var backdrop = document.querySelector('tp-yt-iron-overlay-backdrop');
      if (backdrop) backdrop.remove();
      if (video && video.paused) video.play().catch(function () {});
    }
  }
  // The player's class says when an ad starts; while one shows, look again every 250 ms for its Skip button. The rest
  // (a new player after navigation, the warning) is looked for once a second.
  var watched = null, again = 0;
  function tick() {
    check();
    var player = document.getElementById('movie_player');
    if (player && player !== watched && window.MutationObserver) {
      watched = player;
      new MutationObserver(tick).observe(player, { attributes: true, attributeFilter: ['class'] });
    }
    if (player && player.classList.contains('ad-showing') && !again) again = setTimeout(function () { again = 0; tick(); }, 250);
  }
  setInterval(tick, 1000);
  tick();
})();
