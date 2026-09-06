const burger=document.querySelector('.burger');
const menu=document.querySelector('#mobile-menu');
function closeMenu(){burger.setAttribute('aria-expanded','false');burger.setAttribute('aria-label','Open navigation');menu.hidden=true;document.body.classList.remove('menu-open')}
burger.addEventListener('click',()=>{const opening=menu.hidden;menu.hidden=!opening;burger.setAttribute('aria-expanded',String(opening));burger.setAttribute('aria-label',opening?'Close navigation':'Open navigation');document.body.classList.toggle('menu-open',opening)});
menu.querySelectorAll('a,.overlay').forEach(el=>el.addEventListener('click',closeMenu));
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!menu.hidden){closeMenu();burger.focus()}if(e.key==='Tab'&&!menu.hidden){const items=[burger,...menu.querySelectorAll('a')];const first=items[0],last=items[items.length-1];if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus()}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus()}}});
window.addEventListener('resize',()=>{if(innerWidth>720)closeMenu()});
let toastTimer;const toast=document.querySelector('.toast');
document.querySelectorAll('[data-copy]').forEach(button=>button.addEventListener('click',async()=>{const value=document.getElementById(button.dataset.copy).textContent;try{await navigator.clipboard.writeText(value);toast.textContent='Copied to clipboard';}catch{toast.textContent='Select and copy the command above.';const range=document.createRange();range.selectNodeContents(document.getElementById(button.dataset.copy));getSelection().removeAllRanges();getSelection().addRange(range)}toast.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>toast.classList.remove('show'),2600)}));
const video=document.querySelector('video');const motion=document.querySelector('#motion');const reduced=matchMedia('(prefers-reduced-motion: reduce)');
function updateMotion(){motion.textContent=video.paused?'Play motion ▷':'Pause motion Ⅱ';motion.setAttribute('aria-label',video.paused?'Play background video':'Pause background video')}
if(reduced.matches){video.pause();motion.hidden=true}video.addEventListener('play',updateMotion);video.addEventListener('pause',updateMotion);motion.addEventListener('click',()=>{if(video.paused)video.play().catch(()=>{motion.textContent='Motion unavailable'});else video.pause()});
reduced.addEventListener('change',e=>{motion.hidden=e.matches;if(e.matches)video.pause()});
