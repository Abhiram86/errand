/// Playwright-style accessibility tree snapshot scripts for embedded browser.
library;

/// Token-efficient Playwright-style accessibility tree snapshot generator script.
const String kPlaywrightSnapshotScript = r'''
(() => {
  const MAX_NODES = __MAX_NODES__;
  const TARGET_REF = __TARGET_REF__;
  const TARGET_SEL = __TARGET_SEL__;
  const MAX_TRAVERSAL = Math.max(MAX_NODES * 10, 1500);
  const TIME_BUDGET_MS = 1000;
  const startTime = Date.now();
  let nextId = 1;
  let nodeCount = 0;
  let visitedCount = 0;
  let hitBudget = false;

  function cleanText(val, max = 150) {
    if (!val) return '';
    return String(val)
      .replace(/\s+/g, ' ')
      .replace(/\u00a0/g, ' ')
      .trim()
      .slice(0, max);
  }

  function isVisible(el) {
    if (!(el instanceof Element)) return false;
    const tag = el.tagName.toLowerCase();
    if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'template' || tag === 'svg' || tag === 'path') {
      return false;
    }
    if (el.getAttribute('aria-hidden') === 'true') {
      return false;
    }
    const style = window.getComputedStyle(el);
    if (
      style.display === 'none' ||
      style.visibility === 'hidden' ||
      style.visibility === 'collapse' ||
      style.opacity === '0'
    ) {
      return false;
    }
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) {
      if (!el.firstElementChild) return false;
    }
    return true;
  }

  const INTERACTIVE_ROLES = new Set([
    'button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem',
    'option', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton'
  ]);

  const LANDMARK_ROLES = new Set([
    'banner', 'navigation', 'main', 'contentinfo', 'complementary',
    'region', 'search', 'form', 'dialog', 'article'
  ]);

  function getImplicitRole(el) {
    const tag = el.tagName.toLowerCase();
    switch (tag) {
      case 'a': return el.hasAttribute('href') ? 'link' : '';
      case 'button': return 'button';
      case 'input': {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (['button', 'submit', 'reset'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (type === 'search') return 'searchbox';
        if (type === 'hidden') return '';
        return 'textbox';
      }
      case 'textarea': return 'textbox';
      case 'select': return el.hasAttribute('multiple') ? 'listbox' : 'combobox';
      case 'option': return 'option';
      case 'header': return 'banner';
      case 'nav': return 'navigation';
      case 'main': return 'main';
      case 'footer': return 'contentinfo';
      case 'aside': return 'complementary';
      case 'article': return 'article';
      case 'section': return 'region';
      case 'form': return 'form';
      case 'dialog': return 'dialog';
      case 'ul':
      case 'ol': return 'list';
      case 'li': return 'listitem';
      case 'table': return 'table';
      case 'tr': return 'row';
      case 'th': return 'columnheader';
      case 'td': return 'cell';
      case 'img': return 'img';
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6': return 'heading';
      default: return '';
    }
  }

  function getRole(el) {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit.trim().toLowerCase();
    return getImplicitRole(el);
  }

  function getHeadingLevel(el) {
    const tag = el.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) {
      return Number(tag[1]);
    }
    const ariaLevel = el.getAttribute('aria-level');
    if (ariaLevel) {
      const num = Number(ariaLevel);
      if (!isNaN(num) && num > 0) return num;
    }
    return undefined;
  }

  function getAgentId(el) {
    let id = el.getAttribute('data-agent-id');
    if (!id) {
      id = 'e' + nextId++;
      el.setAttribute('data-agent-id', id);
    }
    return id;
  }

  function isInteractive(el, role) {
    if (INTERACTIVE_ROLES.has(role)) return true;
    const tag = el.tagName.toLowerCase();
    if (tag === 'button' || tag === 'select' || tag === 'textarea') return true;
    if (tag === 'a' && el.hasAttribute('href')) return true;
    if (tag === 'input' && (el.getAttribute('type') || '').toLowerCase() !== 'hidden') return true;
    if (el.hasAttribute('onclick') || el.tabIndex >= 0) return true;
    try {
      if (window.getComputedStyle(el).cursor === 'pointer') return true;
    } catch (_) {}
    return false;
  }

  function getAccessibleName(el, role) {
    const ariaLabel = el.getAttribute('aria-label');
    if (ariaLabel && ariaLabel.trim()) return cleanText(ariaLabel);

    const ariaLabelledby = el.getAttribute('aria-labelledby');
    if (ariaLabelledby) {
      const parts = ariaLabelledby.split(/\s+/)
        .map(id => document.getElementById(id))
        .filter(Boolean)
        .map(n => cleanText(n.innerText || n.textContent));
      const res = cleanText(parts.join(' '));
      if (res) return res;
    }

    const tag = el.tagName.toLowerCase();
    if (tag === 'img') {
      const alt = el.getAttribute('alt');
      if (alt != null) return cleanText(alt);
      const title = el.getAttribute('title');
      if (title) return cleanText(title);
      return '';
    }

    if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      if (el.id) {
        try {
          const label = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (label) {
            const t = cleanText(label.innerText || label.textContent);
            if (t) return t;
          }
        } catch (_) {}
      }
      const parentLabel = el.closest('label');
      if (parentLabel) {
        const t = cleanText(parentLabel.innerText || parentLabel.textContent);
        if (t) return t;
      }
      const placeholder = el.getAttribute('placeholder');
      if (placeholder) return cleanText(placeholder);
    }

    if (role === 'heading' || role === 'button' || role === 'link' || role === 'tab' || role === 'menuitem' || role === 'option') {
      if (el.children.length === 0) {
        return cleanText(el.innerText || el.textContent);
      }
      const altImg = el.querySelector('img[alt]');
      const txt = cleanText(el.innerText || el.textContent);
      if (altImg && altImg.getAttribute('alt')) {
        const alt = cleanText(altImg.getAttribute('alt'));
        return cleanText(alt + (txt ? ' ' + txt : ''));
      }
      if (txt && txt.length <= 80) return txt;
    }

    if (role === 'navigation' || role === 'region' || role === 'dialog' || role === 'form') {
      const title = el.getAttribute('title') || el.getAttribute('name');
      if (title) return cleanText(title);
    }

    const title = el.getAttribute('title');
    if (title) return cleanText(title);

    return '';
  }

  function getHref(el) {
    if (el.tagName.toLowerCase() !== 'a') return undefined;
    const href = el.getAttribute('href');
    if (!href) return undefined;
    try {
      if (href.startsWith('/') && !href.startsWith('//')) return href;
      return new URL(href, window.location.href).href;
    } catch {
      return href;
    }
  }

  function getValue(el) {
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (type === 'password') return '[password]';
      if (type === 'checkbox' || type === 'radio') return undefined;
      if (el instanceof HTMLSelectElement) {
        const sel = Array.from(el.selectedOptions).map(o => cleanText(o.textContent)).join(', ');
        return sel ? cleanText(sel, 60) : undefined;
      }
      const val = cleanText(el.value, 60);
      return val || undefined;
    }
    return undefined;
  }

  function getClasses(el) {
    const rawClass = typeof el.className === 'string' ? el.className.trim() : (el.getAttribute('class') || '').trim();
    if (!rawClass) return undefined;
    const parts = rawClass.split(/\s+/).filter(Boolean);
    if (parts.length === 0) return undefined;
    return parts.slice(0, 3).join(' ').slice(0, 40);
  }

  function walk(el, depth = 0) {
    if (nodeCount >= MAX_NODES) return null;
    if (++visitedCount >= MAX_TRAVERSAL) {
      hitBudget = true;
      return null;
    }
    if (Date.now() - startTime > TIME_BUDGET_MS) {
      hitBudget = true;
      return null;
    }
    if (!isVisible(el)) return null;
    if (depth > 16) return null;

    const role = getRole(el) || 'generic';
    const interactive = isInteractive(el, role);
    const headingLevel = role === 'heading' ? getHeadingLevel(el) : undefined;
    const name = getAccessibleName(el, role);
    const href = getHref(el);
    const value = getValue(el);
    const domId = el.id ? el.id.trim() : undefined;
    const domClass = (interactive || domId || role !== 'generic') ? getClasses(el) : undefined;

    const isSignificant = interactive || LANDMARK_ROLES.has(role) || headingLevel != null ||
                          role === 'list' || role === 'listitem' || role === 'table' ||
                          role === 'img' || (domId != null && domId.length > 0);
    const ref = isSignificant ? getAgentId(el) : undefined;

    let cursor = false;
    if (interactive) {
      cursor = true;
    } else {
      try {
        if (window.getComputedStyle(el).cursor === 'pointer') cursor = true;
      } catch (_) {}
    }

    const disabled = el.hasAttribute('disabled') || el.getAttribute('aria-disabled') === 'true' ? true : undefined;
    const checked = el.checked === true || el.getAttribute('aria-checked') === 'true' ? true : undefined;
    const selected = el.getAttribute('aria-selected') === 'true' ? true : undefined;
    const expanded = el.getAttribute('aria-expanded') != null ? el.getAttribute('aria-expanded') === 'true' : undefined;
    const required = el.hasAttribute('required') || el.getAttribute('aria-required') === 'true' ? true : undefined;

    const children = [];

    const childNodes = Array.from(el.childNodes);
    for (const ch of childNodes) {
      if (nodeCount >= MAX_NODES) break;

      if (ch.nodeType === Node.TEXT_NODE) {
        const text = cleanText(ch.textContent);
        if (!text) continue;
        if (name && text.toLowerCase() === name.toLowerCase() && el.children.length === 0) {
          continue;
        }
        children.push({ type: 'text', text });
      } else if (ch.nodeType === Node.ELEMENT_NODE) {
        const childNode = walk(ch, depth + 1);
        if (childNode) {
          children.push(childNode);
        }
      }
    }

    // Single-child generic wrapper collapsing
    if (role === 'generic' && !name && !ref && !cursor && !domId && !href) {
      if (children.length === 0) {
        return null;
      }
      if (children.length === 1 && children[0].type !== 'text') {
        return children[0];
      }
    }

    nodeCount++;

    return {
      role,
      name: name || undefined,
      ref,
      cursor: cursor || undefined,
      level: headingLevel,
      domId,
      domClass,
      href,
      value,
      disabled,
      checked,
      selected,
      expanded,
      required,
      children: children.length > 0 ? children : undefined
    };
  }

  function serializeToLines(node, depth = 0) {
    const indent = '  '.repeat(depth);
    const role = node.role || 'generic';
    const parts = [`${indent}- ${role}`];

    if (node.name) {
      parts.push(`"${node.name.replace(/"/g, '\\"')}"`);
    }
    if (node.ref) {
      parts.push(`[ref=${node.ref}]`);
    }
    if (node.level) {
      parts.push(`[level=${node.level}]`);
    }
    if (node.domId) {
      parts.push(`[id="${node.domId}"]`);
    }
    if (node.domClass) {
      parts.push(`[class="${node.domClass}"]`);
    }
    if (node.cursor) {
      parts.push(`[cursor=pointer]`);
    }
    if (node.disabled) {
      parts.push(`[disabled]`);
    }
    if (node.checked) {
      parts.push(`[checked]`);
    }
    if (node.selected) {
      parts.push(`[selected]`);
    }
    if (node.expanded === true) {
      parts.push(`[expanded]`);
    } else if (node.expanded === false) {
      parts.push(`[collapsed]`);
    }
    if (node.required) {
      parts.push(`[required]`);
    }
    if (node.value) {
      parts.push(`[value="${node.value.replace(/"/g, '\\"')}"]`);
    }

    const hasChildren = (node.href != null) || (node.children && node.children.length > 0);
    const line = parts.join(' ') + (hasChildren ? ':' : '');
    const lines = [line];

    if (node.href) {
      lines.push(`${indent}  - /url: ${node.href}`);
    }

    if (node.children) {
      for (const ch of node.children) {
        if (ch.type === 'text') {
          lines.push(`${indent}  - text: ${ch.text}`);
        } else {
          lines.push(...serializeToLines(ch, depth + 1));
        }
      }
    }

    return lines;
  }

  let root = null;
  if (TARGET_REF) {
    root = document.querySelector('[data-agent-id="' + TARGET_REF + '"]');
    if (!root) root = document.getElementById(TARGET_REF);
    if (!root) {
      try { root = document.querySelector(TARGET_REF); } catch (_) {}
    }
  }
  if (!root && TARGET_SEL) {
    try { root = document.querySelector(TARGET_SEL); } catch (_) {}
  }
  const isScoped = !!root;
  if (!root && (TARGET_REF || TARGET_SEL)) {
    return JSON.stringify({ error: 'Target element for scoped snapshot not found (ref: ' + (TARGET_REF || '') + ', selector: ' + (TARGET_SEL || '') + ').' });
  }
  if (!root) root = document.body || document.documentElement;
  const treeRoot = root ? walk(root) : null;
  const lines = treeRoot ? serializeToLines(treeRoot) : [];

  return JSON.stringify({
    meta: {
      url: window.location.href,
      title: document.title,
      scoped: isScoped ? (TARGET_REF ? '[ref=' + TARGET_REF + ']' : TARGET_SEL) : null,
      scroll: {
        x: Math.round(window.scrollX),
        y: Math.round(window.scrollY),
        totalHeight: Math.round(document.documentElement.scrollHeight)
      }
    },
    tree: lines.join('\n'),
    stats: {
      nodeCount,
      visitedCount,
      truncated: nodeCount >= MAX_NODES || hitBudget,
      reason: nodeCount >= MAX_NODES ? 'node_cap' : (hitBudget ? 'traversal_budget' : 'none')
    }
  });
})()
''';
