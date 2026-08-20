// Lightweight pointer-based 3D tilt effect for elements with class "tilt-3d".
// Purely decorative — tilts toward the cursor, resets smoothly on leave.
(function () {
  function attach(el) {
    const strength = 10; // max degrees of tilt
    el.addEventListener('mousemove', (e) => {
      const rect = el.getBoundingClientRect();
      const px = (e.clientX - rect.left) / rect.width - 0.5;
      const py = (e.clientY - rect.top) / rect.height - 0.5;
      el.style.transform = `perspective(900px) rotateY(${px * strength}deg) rotateX(${-py * strength}deg) translateZ(4px)`;
    });
    el.addEventListener('mouseleave', () => {
      el.style.transform = 'perspective(900px) rotateY(0deg) rotateX(0deg) translateZ(0)';
    });
  }

  function init() {
    // Skip on touch-only devices and reduced-motion preference.
    if (window.matchMedia('(hover: none)').matches) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    document.querySelectorAll('.tilt-3d').forEach(attach);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
