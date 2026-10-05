document.addEventListener('click', function (ev) {
  var el = ev.target.closest ? ev.target.closest('[data-print]') : null;
  if (el) {
    window.print();
  }
});
