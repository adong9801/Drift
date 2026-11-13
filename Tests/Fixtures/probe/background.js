// Records that the installed event arrived. Outside Safari WebKit never sends
// one for a first install, so Drift has to arrange it; see `Extensions.prime`.
chrome.runtime.onInstalled.addListener(function (details) {
  chrome.storage.local.set({ installed: details && details.reason });
});

// Says back which tab the message came from, if WebKit could tell.
chrome.runtime.onMessage.addListener(function (message, sender, reply) {
  if (!message || message.probe !== 'who-am-i') return;
  chrome.storage.local.get('installed').then(function (stored) {
    reply({ tab: sender.tab ? sender.tab.id : null, url: sender.tab ? sender.tab.url : null, installed: stored.installed || null });
  });
  return true;
});
