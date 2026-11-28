const toggle = document.querySelector('.nav-toggle');
const links = document.getElementById('nav-links');
toggle?.addEventListener('click', () => {
  const open = links.classList.toggle('open');
  toggle.setAttribute('aria-expanded', String(open));
});
// Collapse the mobile menu after following a link.
links?.querySelectorAll('a').forEach((a) =>
  a.addEventListener('click', () => {
    links.classList.remove('open');
    toggle?.setAttribute('aria-expanded', 'false');
  }),
);
