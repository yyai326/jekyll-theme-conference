(() => {
	'use strict';

	const normalize = (value) => String(value || '')
		.normalize('NFKD')
		.replace(/[\u0300-\u036f]/g, '')
		.replace(/[^a-zA-Z0-9]+/g, ' ')
		.trim()
		.toLowerCase();

	const initProgramAbstracts = async () => {
		const inspector = document.getElementById('program-abstract-inspector');
		const backdrop = document.querySelector('.program-abstract-backdrop');
		if (!inspector || !backdrop) {
			return;
		}

		let entries;
		try {
			const response = await fetch(inspector.dataset.manifestUrl, { credentials: 'same-origin' });
			if (!response.ok) {
				throw new Error(`HTTP ${response.status}`);
			}
			entries = await response.json();
		} catch (error) {
			console.error('Unable to load the program abstracts.', error);
			return;
		}

		if (!Array.isArray(entries)) {
			console.error('The program abstract manifest is not an array.');
			return;
		}

		const entriesById = new Map(entries.map((entry) => [String(entry.id), entry]));
		const entriesBySpeaker = new Map(entries.map((entry) => [normalize(entry.speaker), entry]));
		const title = inspector.querySelector('#program-abstract-title');
		const speaker = inspector.querySelector('.program-abstract-speaker');
		const kind = inspector.querySelector('.program-abstract-kind');
		const meta = inspector.querySelector('.program-abstract-meta');
		const note = inspector.querySelector('.program-abstract-note');
		const status = inspector.querySelector('.program-abstract-status');
		const pageImage = inspector.querySelector('.program-abstract-page');
		const closeButton = inspector.querySelector('.program-abstract-close');
		const siteRoot = inspector.dataset.siteRoot || '/';
		let activeId = null;
		let lastTrigger = null;
		let loadToken = 0;

		const resolveAssetUrl = (path) => {
			if (/^(?:[a-z]+:)?\/\//i.test(path)) {
				return path;
			}
			const root = siteRoot === '/' ? '' : siteRoot.replace(/\/$/, '');
			return `${root}/${String(path).replace(/^\//, '')}`;
		};

		const addTrigger = (talkElement, entry) => {
			if (!entry || talkElement.dataset.abstractId) {
				return;
			}

			talkElement.dataset.abstractId = String(entry.id);
			talkElement.classList.add('abstract-talk');
			talkElement.title = 'View abstract';

			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'abstract-trigger';
			button.dataset.abstractId = String(entry.id);
			button.setAttribute('aria-controls', inspector.id);
			button.setAttribute('aria-expanded', 'false');
			button.textContent = 'Abstract';
			talkElement.appendChild(button);
		};

		document.querySelectorAll('.talk-slot:not(.text-muted)').forEach((talkElement) => {
			const talkTitle = talkElement.querySelector('.talk-title');
			const talkSpeaker = talkElement.querySelector('.program-room-content > strong, :scope > strong');
			if (!talkTitle || !talkSpeaker) {
				return;
			}
			addTrigger(talkElement, entriesBySpeaker.get(normalize(talkSpeaker.textContent)));
		});

		document.querySelectorAll('.highlight-slot.shared-talk-slot').forEach((talkElement) => {
			const label = talkElement.querySelector('.slot-label');
			if (!label || normalize(label.textContent) !== 'plenary talk') {
				return;
			}
			const talkSpeaker = talkElement.querySelector('.slot-meta strong');
			if (!talkSpeaker) {
				return;
			}
			addTrigger(talkElement, entriesBySpeaker.get(normalize(talkSpeaker.textContent)));
		});

		const setExpandedState = (id) => {
			document.querySelectorAll('.abstract-trigger').forEach((button) => {
				button.setAttribute('aria-expanded', String(id !== null && button.dataset.abstractId === id));
			});
		};

		const formatTime = (value) => String(value || '').replace(/\s*-\s*/g, '–');

		const openAbstract = (id, trigger) => {
			id = String(id);
			if (activeId === id && inspector.classList.contains('is-open')) {
				closeAbstract();
				return;
			}

			const entry = entriesById.get(id);
			if (!entry) {
				return;
			}

			activeId = id;
			lastTrigger = trigger || lastTrigger;
			loadToken += 1;
			const currentToken = loadToken;

			kind.textContent = entry.kind === 'plenary' ? 'Plenary abstract' : 'Contributed abstract';
			title.textContent = entry.title;
			speaker.textContent = entry.speaker;
			const location = entry.room
				? (entry.kind === 'plenary' ? entry.room : `Room ${entry.room}`)
				: null;
			meta.textContent = [entry.day, formatTime(entry.time), location]
				.filter(Boolean)
				.join('  •  ');
			note.textContent = entry.note || '';
			note.hidden = !entry.note;

			pageImage.hidden = true;
			pageImage.removeAttribute('src');
			pageImage.alt = `Abstract page for “${entry.title},” presented by ${entry.speaker}.`;
			status.hidden = false;
			status.textContent = 'Loading abstract…';

			pageImage.onload = () => {
				if (currentToken !== loadToken) {
					return;
				}
				status.hidden = true;
				pageImage.hidden = false;
			};
			pageImage.onerror = () => {
				if (currentToken !== loadToken) {
					return;
				}
				pageImage.hidden = true;
				status.hidden = false;
				status.textContent = 'The abstract could not be displayed. Please reload the page and try again.';
			};
			pageImage.src = resolveAssetUrl(entry.image);

			inspector.hidden = false;
			backdrop.hidden = false;
			inspector.setAttribute('aria-hidden', 'false');
			document.body.classList.add('program-abstract-open');
			setExpandedState(id);

			requestAnimationFrame(() => {
				inspector.classList.add('is-open');
				backdrop.classList.add('is-open');
				title.focus({ preventScroll: true });
			});
		};

		const closeAbstract = () => {
			if (!inspector.classList.contains('is-open')) {
				return;
			}

			loadToken += 1;
			activeId = null;
			inspector.classList.remove('is-open');
			backdrop.classList.remove('is-open');
			inspector.setAttribute('aria-hidden', 'true');
			document.body.classList.remove('program-abstract-open');
			setExpandedState(null);

			window.setTimeout(() => {
				if (!inspector.classList.contains('is-open')) {
					inspector.hidden = true;
					backdrop.hidden = true;
				}
			}, 270);

			if (lastTrigger && document.contains(lastTrigger)) {
				lastTrigger.focus({ preventScroll: true });
			}
		};

		document.addEventListener('click', (event) => {
			const trigger = event.target.closest('.abstract-trigger');
			if (trigger) {
				event.stopPropagation();
				openAbstract(trigger.dataset.abstractId, trigger);
				return;
			}

			if (event.target.closest('[data-abstract-close]')) {
				closeAbstract();
				return;
			}

			const talkElement = event.target.closest('.abstract-talk[data-abstract-id]');
			if (!talkElement || event.target.closest('a, button, input, select, textarea')) {
				return;
			}
			if (window.getSelection && window.getSelection().toString().trim()) {
				return;
			}
			openAbstract(talkElement.dataset.abstractId, talkElement.querySelector('.abstract-trigger'));
		});

		document.addEventListener('keydown', (event) => {
			if (!inspector.classList.contains('is-open')) {
				return;
			}
			if (event.key === 'Escape') {
				event.preventDefault();
				closeAbstract();
				return;
			}
			if (event.key === 'Tab') {
				event.preventDefault();
				closeButton.focus();
			}
		});
	};

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', initProgramAbstracts, { once: true });
	} else {
		initProgramAbstracts();
	}
})();
