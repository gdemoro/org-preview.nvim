'use strict';

/*
 * Dependency-free harness for exercising the *actual* TOC client script that
 * org-preview.nvim injects into served pages.
 *
 * It parses a small, controlled HTML fixture into a minimal DOM, evaluates the
 * injected client script inside a Node `vm` context (using only Node built-ins:
 * fs/vm), drives the toggle and links, and prints a JSON snapshot of the
 * observable result on stdout.  No npm packages are involved.
 *
 * Usage:
 *   node toc_client.js --html fixture.html --script toc.js \
 *        [--ready complete|loading] [--wide 0|1]
 */

const fs = require('fs');
const vm = require('vm');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    out[argv[i].replace(/^--/, '')] = argv[i + 1];
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));

const VOID = new Set([
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr',
]);

class ClassList {
  constructor(el) {
    this.el = el;
  }
  _list() {
    return (this.el.getAttribute('class') || '').split(/\s+/).filter(Boolean);
  }
  _set(list) {
    this.el.setAttribute('class', list.join(' '));
  }
  add(c) {
    const l = this._list();
    if (!l.includes(c)) {
      l.push(c);
      this._set(l);
    }
  }
  remove(c) {
    this._set(this._list().filter((x) => x !== c));
  }
  contains(c) {
    return this._list().includes(c);
  }
}

class Element {
  constructor(tag) {
    this._tag = String(tag).toLowerCase();
    this.attributes = {};
    this.nodes = [];
    this.parent = null;
    this.listeners = {};
    this._classList = null;
  }
  get tagName() {
    return this._tag.toUpperCase();
  }
  get children() {
    return this.nodes.filter((n) => n instanceof Element);
  }
  appendChild(c) {
    c.parent = this;
    this.nodes.push(c);
    return c;
  }
  prepend(c) {
    c.parent = this;
    this.nodes.unshift(c);
  }
  querySelector(sel) {
    let found = null;
    const selectors = sel.split(',').map((s) => s.trim());
    walk(this, (e) => {
      if (!found && selectors.some((s) => matchesSelector(e, s))) {
        found = e;
      }
    });
    return found;
  }
  setAttribute(n, v) {
    this.attributes[n] = String(v);
  }
  getAttribute(n) {
    return Object.prototype.hasOwnProperty.call(this.attributes, n)
      ? this.attributes[n]
      : null;
  }
  removeAttribute(n) {
    delete this.attributes[n];
  }
  hasAttribute(n) {
    return Object.prototype.hasOwnProperty.call(this.attributes, n);
  }
  addEventListener(t, fn) {
    (this.listeners[t] = this.listeners[t] || []).push(fn);
  }
  dispatch(t, ev) {
    (this.listeners[t] || []).forEach((fn) => fn(ev));
  }
  closest(sel) {
    let n = this;
    while (n) {
      if (matchesSelector(n, sel)) {
        return n;
      }
      n = n.parent;
    }
    return null;
  }
  get textContent() {
    return this.nodes
      .map((n) => (typeof n === 'string' ? n : n.textContent))
      .join('');
  }
  set textContent(v) {
    this.nodes = [String(v)];
  }
  get classList() {
    if (!this._classList) {
      this._classList = new ClassList(this);
    }
    return this._classList;
  }
  get className() {
    return this.getAttribute('class') || '';
  }
  set className(v) {
    this.setAttribute('class', v);
  }
  get id() {
    return this.getAttribute('id') || '';
  }
  set id(v) {
    this.setAttribute('id', v);
  }
  scrollIntoView() {
    this.__scrolled = true;
  }
}

function matchesSelector(el, sel) {
  // Supports a single compound simple selector: tag, #id, .class,
  // tag#id, tag.class, #id.class or tag#id.class.  Used by closest() so the
  // stub reflects real selector matching instead of accepting fixed strings.
  const m = /^([a-zA-Z][a-zA-Z0-9_-]*)?(#[-\w]+)?(\.[-\w]+)?$/.exec(sel);
  if (!m) {
    return false;
  }
  const tag = m[1];
  const id = m[2];
  const cls = m[3];
  if (tag && el._tag !== tag.toLowerCase()) {
    return false;
  }
  if (id && el.getAttribute('id') !== id.slice(1)) {
    return false;
  }
  if (cls && !el.classList.contains(cls.slice(1))) {
    return false;
  }
  return true;
}

function findTagEnd(html, start) {
  let quote = null;
  for (let i = start; i < html.length; i++) {
    const c = html[i];
    if (quote) {
      if (c === quote) {
        quote = null;
      }
    } else if (c === '"' || c === "'") {
      quote = c;
    } else if (c === '>') {
      return i;
    }
  }
  return -1;
}

const ATTR_RE = /([^\s"'>/=]+)(?:\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>`]+)))?/g;

function parseAttrs(raw, el) {
  let m;
  ATTR_RE.lastIndex = 0;
  while ((m = ATTR_RE.exec(raw)) !== null) {
    const name = m[1].toLowerCase();
    let value = '';
    if (m[3] !== undefined) {
      value = m[3];
    } else if (m[4] !== undefined) {
      value = m[4];
    } else if (m[5] !== undefined) {
      value = m[5];
    }
    el.setAttribute(name, value);
  }
}

function parseHTML(html) {
  const root = new Element('#root');
  const stack = [root];
  let i = 0;
  const len = html.length;
  const pushText = (text) => {
    if (text) {
      stack[stack.length - 1].nodes.push(text);
    }
  };
  while (i < len) {
    const lt = html.indexOf('<', i);
    if (lt === -1) {
      pushText(html.slice(i));
      break;
    }
    if (lt > i) {
      pushText(html.slice(i, lt));
    }
    if (html.startsWith('<!--', lt)) {
      const end = html.indexOf('-->', lt + 4);
      i = end === -1 ? len : end + 3;
      continue;
    }
    if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
      const end = html.indexOf('>', lt);
      i = end === -1 ? len : end + 1;
      continue;
    }
    const end = findTagEnd(html, lt + 1);
    if (end === -1) {
      pushText(html.slice(lt));
      break;
    }
    const raw = html.slice(lt + 1, end).trim();
    i = end + 1;
    if (raw.startsWith('/')) {
      const name = raw.slice(1).trim().toLowerCase();
      for (let k = stack.length - 1; k > 0; k--) {
        if (stack[k]._tag === name) {
          stack.length = k;
          break;
        }
      }
      continue;
    }
    const m = raw.match(/^([a-zA-Z0-9:_-]+)/);
    if (!m) {
      continue;
    }
    const name = m[1].toLowerCase();
    const el = new Element(name);
    parseAttrs(raw.slice(m[1].length), el);
    const parent = stack[stack.length - 1];
    parent.nodes.push(el);
    el.parent = parent;
    if (name === 'script' || name === 'style') {
      const closeRe = new RegExp('</' + name + '\\s*>', 'i');
      const cm = html.slice(i).match(closeRe);
      i = cm ? i + cm.index + cm[0].length : len;
      continue;
    }
    if (VOID.has(name) || raw.endsWith('/')) {
      continue;
    }
    stack.push(el);
  }
  return root;
}

function walk(el, fn) {
  for (const n of el.nodes) {
    if (n instanceof Element) {
      fn(n);
      walk(n, fn);
    }
  }
}

const html = fs.readFileSync(args.html, 'utf8');
const script = fs.readFileSync(args.script, 'utf8');
const root = parseHTML(html);

const docListeners = {};
let body = null;
walk(root, (e) => {
  if (!body && e._tag === 'body') {
    body = e;
  }
});

const document = {
  readyState: args.ready || 'complete',
  body,
  createElement(tag) {
    return new Element(tag);
  },
  getElementById(id) {
    let found = null;
    walk(root, (e) => {
      if (!found && e.getAttribute('id') === id) {
        found = e;
      }
    });
    return found;
  },
  querySelectorAll(sel) {
    const tags = sel.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
    const out = [];
    walk(root, (e) => {
      if (tags.includes(e._tag)) {
        out.push(e);
      }
    });
    return out;
  },
  addEventListener(t, fn) {
    (docListeners[t] = docListeners[t] || []).push(fn);
  },
};

const window = {
  matchMedia(q) {
    return {
      matches: args.wide === '1',
      media: q,
      addEventListener() {},
      removeEventListener() {},
      addListener() {},
      removeListener() {},
    };
  },
};

const sandbox = { document, window, console };
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(script, sandbox, { filename: 'toc-client.js' });

const collectNavs = () => {
  const out = [];
  walk(root, (e) => {
    if (e.classList.contains('op-toc')) {
      out.push(e);
    }
  });
  return out;
};

const navCountBefore = collectNavs().length;

if (document.readyState === 'loading') {
  (docListeners['DOMContentLoaded'] || []).forEach((fn) => fn({}));
}

let toggle = null;
let nav = null;
walk(root, (e) => {
  if (!toggle && e.classList.contains('op-toc-toggle')) {
    toggle = e;
  }
  if (!nav && e.classList.contains('op-toc')) {
    nav = e;
  }
});

const snapshot = () => ({
  expanded: toggle ? toggle.getAttribute('aria-expanded') : null,
  hidden: nav ? nav.hasAttribute('hidden') : null,
  bodyOpen: body ? body.classList.contains('op-toc-open') : null,
});

const initial = snapshot();
let afterFirst = null;
let afterSecond = null;
if (toggle) {
  toggle.dispatch('click', { preventDefault() {} });
  afterFirst = snapshot();
  toggle.dispatch('click', { preventDefault() {} });
  afterSecond = snapshot();
}

const links = [];
walk(root, (e) => {
  if (e.classList.contains('op-toc-link')) {
    links.push(e);
  }
});

const resetScroll = () => walk(root, (e) => {
  e.__scrolled = false;
});

const scrollTargets = links.map((l) => {
  resetScroll();
  l.dispatch('click', { preventDefault() {} });
  let target = null;
  walk(root, (e) => {
    if (e.__scrolled) {
      target = e.getAttribute('id');
    }
  });
  return target;
});

const headings = [];
walk(root, (e) => {
  if (/^h[1-6]$/.test(e._tag)) {
    headings.push({
      tag: e.tagName,
      id: e.getAttribute('id'),
      className: e.getAttribute('class'),
      text: e.textContent,
    });
  }
});

const navs = collectNavs();

const state = {
  ready: document.readyState,
  deferred: document.readyState === 'loading',
  navCountBefore,
  navCount: navs.length,
  navIds: navs.map((n) => n.getAttribute('id')),
  hasToggle: !!toggle,
  toggle: toggle
    ? {
      tag: toggle.tagName,
      text: toggle.textContent,
      ariaControls: toggle.getAttribute('aria-controls'),
      ariaExpanded: toggle.getAttribute('aria-expanded'),
      hasId: toggle.hasAttribute('id'),
      className: toggle.className,
    }
    : null,
  initial,
  afterFirst,
  afterSecond,
  headings,
  links: links.map((l) => ({
    text: l.textContent,
    title: l.getAttribute('title'),
    href: l.href,
    level: l.parent ? l.parent.getAttribute('data-level') : null,
    badges: l.children
      .filter((e) => e.classList.contains('todo') || e.classList.contains('done'))
      .map((e) => ({ text: e.textContent, className: e.className })),
  })),
  scrollTargets,
};

process.stdout.write(JSON.stringify(state));
