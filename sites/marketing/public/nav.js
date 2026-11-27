document.querySelector('.nav-toggle')?.addEventListener('click', (e) => {
  const btn = e.currentTarget;
  const links = document.getElementById('nav-links');
  const open = links.classList.toggle('open');
  btn.setAttribute('aria-expanded', String(open));
});
