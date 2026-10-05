// Ferramentas: gerar segredo forte (no navegador) e baixar o script .rsc gerado.
(function () {
  var ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.';
  var LEN = 32;

  function randomSecret() {
    var out = '';
    var limit = 256 - (256 % ALPHABET.length);   // descarta o resto para não enviesar a escolha
    var buf = new Uint8Array(64);
    while (out.length < LEN) {
      window.crypto.getRandomValues(buf);
      for (var i = 0; i < buf.length && out.length < LEN; i++) {
        if (buf[i] < limit) { out += ALPHABET.charAt(buf[i] % ALPHABET.length); }
      }
    }
    return out;
  }

  function init() {
    Array.prototype.forEach.call(document.querySelectorAll('button[data-gensecret]'), function (btn) {
      btn.addEventListener('click', function () {
        var input = document.getElementById(btn.getAttribute('data-gensecret'));
        if (!input || !window.crypto || !window.crypto.getRandomValues) { return; }
        input.value = randomSecret();
        input.type = 'text';   // mostra uma vez para o usuário copiar para o cadastro do equipamento
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll('button[data-download]'), function (btn) {
      btn.addEventListener('click', function () {
        var pre = document.querySelector(btn.getAttribute('data-download'));
        if (!pre) { return; }
        var blob = new Blob([pre.textContent], { type: 'text/plain;charset=utf-8' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = btn.getAttribute('data-filename') || 'radpanel.rsc';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      });
    });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
