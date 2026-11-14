// Header border once scrolled, reveal on scroll, dark/light screenshot.
(() => {
  const top = document.getElementById('top');
  const onScroll = () => top.classList.toggle('scrolled', window.scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  const items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      }
    }, { rootMargin: '0px 0px -8% 0px' });
    items.forEach((el) => io.observe(el));
  } else {
    items.forEach((el) => el.classList.add('in'));
  }

  const frame = document.getElementById('frame');
  document.querySelectorAll('.switch button').forEach((b) => {
    b.addEventListener('click', () => {
      frame.classList.toggle('is-light', b.dataset.theme === 'light');
      document.querySelectorAll('.switch button').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
    });
  });
})();
