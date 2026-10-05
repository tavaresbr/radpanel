document.addEventListener('submit', function (ev) {
  var msg = ev.target.getAttribute('data-confirm');
  if (msg && !window.confirm(msg)) {
    ev.preventDefault();
  }
});

// Botão "Copiar" nos blocos <pre data-copy> (comandos e scripts para colar em outro equipamento).
(function () {
  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.className = 'copyhidden';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }
  function selectBlock(pre) {
    var r = document.createRange();
    r.selectNodeContents(pre);
    var s = window.getSelection();
    s.removeAllRanges();
    s.addRange(r);
  }
  function setLabel(btn, text) {
    btn.textContent = text;
    window.setTimeout(function () { btn.textContent = 'Copiar'; }, 2000);
  }
  function copy(pre, btn) {
    var text = pre.textContent;
    var done = function (ok) {
      if (ok) { setLabel(btn, 'Copiado!'); return; }
      selectBlock(pre);
      setLabel(btn, 'Selecionado: Ctrl+C');
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done(true); },
        function () { done(legacyCopy(text)); });
    } else {
      done(legacyCopy(text));
    }
  }
  function init() {
    var blocks = document.querySelectorAll('pre[data-copy]');
    Array.prototype.forEach.call(blocks, function (pre) {
      var wrap = document.createElement('div');
      wrap.className = 'copywrap';
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'copybtn';
      btn.textContent = 'Copiar';
      btn.addEventListener('click', function () { copy(pre, btn); });
      wrap.appendChild(btn);
    });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
