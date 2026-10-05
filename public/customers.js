// Campo CPF/CNPJ: máscara e preenchimento automático pelo CNPJ (consulta feita pelo servidor).
(function () {
  var doc = document.querySelector('input[data-doc]');
  if (!doc) { return; }
  var form = doc.form;
  var status = document.querySelector('[data-doc-status]');
  var btn = document.querySelector('[data-cnpj-lookup]');
  var busy = false;

  function digits(s) { return s.replace(/\D+/g, ''); }
  function mask(d) {
    d = d.slice(0, 14);
    if (d.length <= 11) {
      return d.replace(/^(\d{3})(\d)/, '$1.$2').replace(/^(\d{3})\.(\d{3})(\d)/, '$1.$2.$3')
        .replace(/^(\d{3})\.(\d{3})\.(\d{3})(\d)/, '$1.$2.$3-$4');
    }
    return d.replace(/^(\d{2})(\d)/, '$1.$2').replace(/^(\d{2})\.(\d{3})(\d)/, '$1.$2.$3')
      .replace(/^(\d{2})\.(\d{3})\.(\d{3})(\d)/, '$1.$2.$3/$4').replace(/^(\d{2})\.(\d{3})\.(\d{3})\/(\d{4})(\d)/, '$1.$2.$3/$4-$5');
  }
  function say(msg, bad) {
    if (!status) { return; }
    status.textContent = msg;
    status.className = bad ? 'muted bad' : 'muted';
  }
  function setIfEmpty(name, value) {
    var el = form.elements[name];
    if (el && value && !el.value.trim()) { el.value = value; return true; }
    return false;
  }
  function lookup() {
    var d = digits(doc.value);
    if (busy || d.length !== 14) {
      if (d.length !== 14) { say('Informe um CNPJ completo (14 dígitos) para consultar.', true); }
      return;
    }
    busy = true;
    say('Consultando CNPJ…', false);
    var body = new URLSearchParams();
    body.set('csrf', form.elements.csrf.value);
    body.set('cnpj', d);
    fetch('cnpj_lookup.php', { method: 'POST', body: body, credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (!j.ok) { say(j.error || 'Consulta falhou.', true); return; }
        var n = 0;
        ['name', 'email', 'phone', 'address'].forEach(function (k) { if (setIfEmpty(k, j.data[k])) { n++; } });
        say('Dados da Receita Federal' + (j.data.situacao ? ' (situação: ' + j.data.situacao + ')' : '') +
          ' — ' + n + ' campo(s) preenchido(s); confira antes de salvar.', false);
      })
      .catch(function () { say('Consulta indisponível agora. Preencha manualmente.', true); })
      .then(function () { busy = false; });
  }

  doc.addEventListener('input', function () {
    var d = digits(doc.value);
    doc.value = mask(d);
    if (d.length === 14 && doc.hasAttribute('data-auto')) { lookup(); }
  });
  if (btn) { btn.addEventListener('click', lookup); }
})();
