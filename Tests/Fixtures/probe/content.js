// At document_start, as early as a page script can speak: the moment that races
// extension loading at launch.
(function () {
  function note(text) { document.documentElement.setAttribute('data-drift-probe', text); }
  try {
    chrome.runtime.sendMessage({ probe: 'who-am-i' }).then(function (answer) {
      note((answer && answer.tab !== null && answer.tab !== undefined ? 'tab:' + answer.tab : 'no-tab') + ' installed:' + (answer && answer.installed));
    }).catch(function (error) { note('error:' + error.message); });
  } catch (error) { note('error:' + error.message); }
})();
