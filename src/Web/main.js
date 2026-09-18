import monitor from '@phosphor-icons/core/assets/regular/monitor.svg?raw';
import wifi from '@phosphor-icons/core/assets/regular/wifi-high.svg?raw';
import search from '@phosphor-icons/core/assets/regular/magnifying-glass.svg?raw';
import battery from '@phosphor-icons/core/assets/regular/battery-high.svg?raw';
import lightning from '@phosphor-icons/core/assets/regular/lightning.svg?raw';
import gear from '@phosphor-icons/core/assets/regular/gear.svg?raw';
import shield from '@phosphor-icons/core/assets/regular/shield-check.svg?raw';
import apple from '@phosphor-icons/core/assets/fill/apple-logo-fill.svg?raw';

const icons = { monitor, wifi, search, battery, lightning, gear, shield, apple };
document.querySelectorAll('[data-icon]').forEach((element) => {
  element.innerHTML = icons[element.dataset.icon];
  element.setAttribute('aria-hidden', 'true');
});

const tabs = document.querySelector('.mode-tabs');
const buttons = [...tabs.querySelectorAll('button')];
const panels = buttons.map((button) => document.getElementById(button.getAttribute('aria-controls')));

function selectMode(index) {
  buttons.forEach((button, i) => {
    button.setAttribute('aria-selected', String(i === index));
    button.tabIndex = i === index ? 0 : -1;
    panels[i].hidden = i !== index;
  });
  tabs.style.setProperty('--selected-mode', index);
}

tabs.setAttribute('role', 'tablist');
tabs.setAttribute('aria-label', 'Choose a mode to see how it works');
buttons.forEach((button, index) => {
  button.setAttribute('role', 'tab');
  panels[index].setAttribute('role', 'tabpanel');
  panels[index].setAttribute('aria-labelledby', button.id);
  panels[index].tabIndex = 0;
  button.addEventListener('click', () => selectMode(index));
  button.addEventListener('keydown', (event) => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % buttons.length;
    if (event.key === 'ArrowLeft') next = (index - 1 + buttons.length) % buttons.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = buttons.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    selectMode(next);
    buttons[next].focus();
  });
});
selectMode(0);
tabs.hidden = false;

// Content is visible without JavaScript. Only animate sections once on entry.
// CSS also honours a motion preference changed while the page is open.
const motion = matchMedia('(prefers-reduced-motion: reduce)');
if (!motion.matches && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    }
  }, { threshold: 0.12 });
  document.querySelectorAll('[data-reveal]').forEach((section) => {
    section.classList.add('reveal-ready');
    observer.observe(section);
  });
  motion.addEventListener('change', () => {
    if (!motion.matches) return;
    observer.disconnect();
    document.querySelectorAll('.reveal-ready').forEach((section) => section.classList.add('is-visible'));
  });
}
