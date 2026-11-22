// The device page's toolbar: its clusters of controls — each panel's placed
// by the panel (page-panels.js), each action's when the device can do what
// it needs — and how it folds into menus when the row is narrow. What it
// needs of the page is its port: { abilities } (the device's, or null when
// none are listed). Out of page/device-page.js (design §4, page/).
import { toolbarOf } from '../page-panels.js';

export function toolbarView(page) {
  // ── Toolbar clusters ─────────────────────────────────────────────
  //
  // The strip is seven CONTEXT CLUSTERS, not fifteen loose controls,
  // and when the row runs out of width a WHOLE cluster folds into one
  // menu — never an item, never a partial group. A flat per-control
  // priority queue was tried first and tore Shake off Home on a
  // tie-break between equal ranks; `docs/mockups/focus-toolbar-overflow.html`
  // runs both so the difference is visible.
  //
  // The grouping is applied at runtime rather than authored into
  // page/device-page.html. That template is a flat list of buttons and reads
  // better as one; keeping the cluster definition here means the
  // membership, the fold order and the menu's idea of each control's
  // ROLE live in a single table instead of being split between HTML
  // nesting and a JS lookup.
  //
  // `role` is what the control IS, which is what its menu row has to
  // render. Flattening everything to icon + label + value turned the
  // codec picker into a caption reading "Codec  H.264" with no way to
  // reach MJPEG.
  //
  // `label` is declared rather than read off the button's `title`
  // because a tooltip and a menu row are different sentences: the
  // tooltip on the camera button says "Toggle camera control", which
  // is the right thing to say when hovering an unlabelled glyph and
  // the wrong thing to put in a list where every row is a control and
  // the verb is implied. The `title` is still the fallback, so a
  // button added without a label here still renders.
  const TOOLBAR_CLUSTERS = [
    {
      id: 'stream', label: 'Stream', fold: 3, icon: 'film',
      members: [
        { id: 'nativeStatus', label: 'Frame rate', role: 'readout' },
        { id: 'nativeFormatPicker', label: 'Codec', role: 'choice' },
      ],
    },
    {
      id: 'view', icon: 'cube',
      members: [
        { id: 'native3DToggle', label: '3D view', role: 'state' },
        { id: 'nativeHandheldToggle', label: 'Handheld', role: 'action' },
      ],
    },
    {
      id: 'control', label: 'Control', fold: 4, icon: 'home',
      members: [
        { id: 'nativeRotate', label: 'Rotate', role: 'action', needs: 'orientation' },
        { id: 'nativeHome', label: 'Home', role: 'action', needs: 'press' },
        { id: 'nativeAppSwitcher', label: 'App switcher', role: 'action', needs: 'press' },
        { id: 'nativeShake', label: 'Shake', role: 'action', needs: 'shake' },
      ],
    },
    // Each panel places its own control here (its `cluster`): page/page-panels.js.
    { id: 'simulate', label: 'Simulate', fold: 1, icon: 'wave', members: [] },
    {
      id: 'inspect', label: 'Inspect', fold: 2, icon: 'glass',
      members: [
        { id: 'nativeAxToggle', label: 'Accessibility', role: 'state', needs: 'accessibility' },
      ],
    },
    {
      id: 'capture',
      members: [
        { id: 'nativeScreenshot', label: 'Screenshot', role: 'action' },
        { id: 'nativeRecordBtn', label: 'Record', role: 'action' },
        { id: 'nativeCaptureSize', role: 'mount' },
      ],
    },
  ];

  // Glyphs for the folded-cluster buttons. Every member row borrows its
  // icon from the real button it proxies, so only the cluster headers
  // need art of their own.
  const CLUSTER_ICONS = {
    film:  'M4 5h16v14H4zM4 9h16M4 15h16M8 5v14M16 5v14',
    cube:  'M12 2l9 5v10l-9 5-9-5V7z M12 12l9-5 M12 12v10 M12 12L3 7',
    home:  'M4 11l8-7 8 7v9H4z',
    wave:  'M3 12h3l2-6 3 12 3-9 2 3h5',
    glass: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM16.5 16.5L21 21',
    more:  'M6 12h.01M12 12h.01M18 12h.01',
    // Rows that have no button in the bar to borrow a glyph from. Both
    // wore the Stream cluster's own film icon at first, which made
    // "Frame rate" and "Codec" look like the same control twice.
    gauge: 'M12 20a8 8 0 1 1 8-8M12 12l4.5-3',
    codec: 'M3 8h4l3 8h4l3-8h4',
  };

  const CARET_SVG =
      '<svg class="tb-caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" ' +
      'width="11" height="11"><polyline points="6 9 12 15 18 9"/></svg>';

  const clusterSvg = (name) =>
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
      'stroke-linecap="round" stroke-linejoin="round" width="15" height="15">' +
      '<path d="' + CLUSTER_ICONS[name] + '"/></svg>';

  let toolbarFold = null;

  /**
   * Move the flat strip into cluster containers, once.
   *
   * Every control keeps its own element — same id, same inline
   * `onclick`, same `.active` class — so nothing about how a button
   * behaves changes; only where it sits. The fold menus are built as a
   * PROJECTION of these buttons (their icon, their `title`, their
   * active state), which is why there is no second catalogue of labels
   * to drift out of sync.
   */
  function buildToolbarClusters() {
    const controls = document.querySelector('#simNativeView .tb-controls');
    const strip = document.getElementById('nativeToolScroll');
    if (!controls || !strip || !window.Baguette || !window.Baguette._ToolbarFold) {
      return false;
    }

    // Only the controls this device has an ability for; a cluster left
    // with none goes too, and with it its fold menu.
    // The device's toolbar: each control only when it can do what the control
    // needs, every panel's in its own cluster (device/toolbar.js).
    const toolbar = toolbarOf(TOOLBAR_CLUSTERS, page.abilities);
    toolbar.hidden.forEach((id) => { const el = document.getElementById(id); if (el) el.remove(); });
    TOOLBAR_CLUSTERS.splice(0, TOOLBAR_CLUSTERS.length, ...toolbar.clusters);

    // The scroller and its chevrons are what this replaces.
    ['nativeScrollLeft', 'nativeScrollRight'].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.remove();
    });

    TOOLBAR_CLUSTERS.forEach((cluster, index) => {
      if (index > 0) {
        const sep = document.createElement('span');
        sep.className = 'tb-sep';
        sep.dataset.sepFor = cluster.id;
        controls.appendChild(sep);
      }
      const host = document.createElement('span');
      host.className = 'tb-cluster';
      host.dataset.cluster = cluster.id;
      cluster.members.forEach((member) => {
        const el = document.getElementById(member.id);
        if (el) host.appendChild(el);
      });
      controls.appendChild(host);

      if (!cluster.fold) return;
      controls.appendChild(foldHost(cluster.id, cluster.label, cluster.icon));
    });

    // The merged menu sits where the folded clusters were — before
    // Capture, since every foldable cluster precedes it. Appending it
    // after Capture left it hanging off the right edge of the bar,
    // reading as an afterthought rather than as the clusters it stands
    // in for.
    const captureHost = controls.querySelector('[data-cluster="capture"]');
    const captureSep = controls.querySelector('[data-sep-for="capture"]');
    controls.insertBefore(foldHost('more', 'More controls', 'more'),
        captureSep || captureHost || null);
    strip.remove();

    toolbarFold = new window.Baguette._ToolbarFold(TOOLBAR_CLUSTERS);
    return true;
  }

  function foldHost(id, label, icon) {
    const host = document.createElement('span');
    host.className = 'tb-fold';
    host.dataset.fold = id;
    host.hidden = true;
    host.innerHTML =
        '<button type="button" class="tb-fold-btn" aria-expanded="false" ' +
        'aria-haspopup="true" title="' + label + '">' +
        clusterSvg(icon) + CARET_SVG + '</button>' +
        '<div class="tb-fold-pop" hidden></div>';
    return host;
  }

  /** Show the clusters this state keeps, and the fold buttons it needs. */
  function applyToolbarState(state) {
    const bar = document.querySelector('#simNativeView .top-bar');
    if (!bar) return;
    const folded = state.folded;
    const merged = state.merged;

    TOOLBAR_CLUSTERS.forEach((cluster) => {
      const isFolded = folded.indexOf(cluster.id) >= 0;
      const host = document.querySelector('[data-cluster="' + cluster.id + '"]');
      const sep = document.querySelector('[data-sep-for="' + cluster.id + '"]');
      const fold = document.querySelector('[data-fold="' + cluster.id + '"]');
      if (host) host.hidden = isFolded;
      if (sep) sep.hidden = isFolded;
      if (fold) fold.hidden = !isFolded || merged;
    });
    const more = document.querySelector('[data-fold="more"]');
    if (more) more.hidden = !merged;
    bar.classList.toggle('tight', state.tight);
  }

  /**
   * Ask ToolbarFold for the widest state that fits, then fill in the
   * menus for whatever ended up folded.
   *
   * Re-measuring after every candidate is what makes this exact: there
   * is no width table to keep in sync with the CSS, and it stays right
   * when a device name is long or a webfont lands late.
   */
  function layoutToolbar() {
    const bar = document.querySelector('#simNativeView .top-bar');
    if (!bar || !toolbarFold) return;

    restoreClusterMembers();
    bar.classList.add('measuring');
    const state = toolbarFold.plan((candidate) => {
      applyToolbarState(candidate);
      return bar.scrollWidth <= bar.clientWidth + 1;
    });
    bar.classList.remove('measuring');
    fillFoldMenus(state);
  }

  /**
   * Put every member element back in its own cluster, in declared
   * order.
   *
   * A `choice` row MOVES the real control into the menu rather than
   * copying it — a cloned picker would be a second `#nativeFormatPicker`
   * with none of the page's handlers on it. That means the menu owns
   * the only copy while it is folded, so wiping the popovers without
   * this first deleted the codec picker outright: `getElementById`
   * returned null for the rest of the session and the Stream menu
   * silently lost its one interactive row. Restore, then rebuild.
   */
  function restoreClusterMembers() {
    TOOLBAR_CLUSTERS.forEach((cluster) => {
      const host = document.querySelector('[data-cluster="' + cluster.id + '"]');
      if (!host) return;
      cluster.members.forEach((member) => {
        const el = document.getElementById(member.id);
        if (el && el.parentElement !== host) host.appendChild(el);
      });
    });
  }

  /** Build the menu bodies once, for the state that won. */
  function fillFoldMenus(state) {
    restoreClusterMembers();
    document.querySelectorAll('#simNativeView .tb-fold-pop')
        .forEach((pop) => { pop.innerHTML = ''; });

    const foldedClusters = TOOLBAR_CLUSTERS
        .filter((c) => state.folded.indexOf(c.id) >= 0);

    if (state.merged) {
      const pop = document.querySelector('[data-fold="more"] .tb-fold-pop');
      if (pop) {
        foldedClusters.forEach((cluster) => pop.appendChild(accordion(cluster)));
      }
      return;
    }
    foldedClusters.forEach((cluster) => {
      const pop = document.querySelector(
          '[data-fold="' + cluster.id + '"] .tb-fold-pop');
      if (!pop) return;
      cluster.members.forEach((m) => {
        const row = menuRow(m);
        if (row) pop.appendChild(row);
      });
    });
  }

  /**
   * One cluster as a collapsed accordion section.
   *
   * `<details>` will happily open all four at once, which puts all
   * thirteen rows back and undoes the reason for having an accordion —
   * so `name=` groups them where it is supported, and `syncAccordion`
   * enforces it everywhere else.
   */
  function accordion(cluster) {
    const details = document.createElement('details');
    details.className = 'tb-acc';
    details.setAttribute('name', 'nativeToolbarAcc');
    const summary = document.createElement('summary');
    summary.innerHTML = clusterSvg(cluster.icon) +
        '<span>' + cluster.label + '</span>' +
        '<span class="tb-acc-n">' + cluster.members.length + '</span>' + CARET_SVG;
    details.appendChild(summary);
    const body = document.createElement('div');
    body.className = 'tb-acc-body';
    cluster.members.forEach((m) => {
      const row = menuRow(m);
      if (row) body.appendChild(row);
    });
    details.appendChild(body);
    return details;
  }

  /**
   * A folded control as a menu row, rendered for what it IS.
   *
   *   action    a button; clicking the row clicks the real one
   *   state     the same, plus a dot when it is currently on
   *   choice    the real control, moved in — a value you cannot change
   *             is a caption pretending to be a control
   *   readout   no hover, no pointer: nothing happens when pressed
   *
   * `state` used to draw a SWITCH, which was wrong twice over. Every
   * control that can reach this menu — status bar, location, camera,
   * accessibility, logs — opens a PANEL; a switch says "a setting you
   * flip and leave", and these are disclosures. And the switch made
   * the row keep the menu open so you could see it move, which left
   * the panel you had just opened sitting behind the menu covering it.
   * A dot reports the same state without claiming to be a setting, and
   * every row now closes the menu, because every row reveals something
   * the menu is standing on top of.
   */
  function menuRow(member) {
    const source = document.getElementById(member.id);
    if (!source) return null;
    const label = member.label || source.getAttribute('title') || member.id;

    if (member.role === 'readout') {
      const row = document.createElement('div');
      row.className = 'tb-read';
      row.innerHTML = clusterSvg('gauge') + '<span>' + label + '</span>' +
          '<span class="tb-val"></span>';
      row.querySelector('.tb-val').textContent = source.textContent || '—';
      return row;
    }

    if (member.role === 'choice') {
      const row = document.createElement('div');
      row.className = 'tb-choice';
      row.innerHTML = clusterSvg('codec') + '<span>' + label + '</span>';
      // The real picker is moved in, not copied: it keeps its handlers,
      // its `.active` pill, and its identity as the one control the
      // rest of the page already talks to.
      row.appendChild(source);
      return row;
    }

    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'tb-row' + (source.classList.contains('active') ? ' on' : '');
    const glyph = source.querySelector('svg');
    row.innerHTML = (glyph ? glyph.outerHTML : clusterSvg('more')) +
        '<span>' + label + '</span>' +
        (member.role === 'state' ? '<span class="tb-dot"></span>' : '');
    row.addEventListener('click', () => {
      source.click();
      closeFoldMenus();
    });
    return row;
  }

  function closeFoldMenus() {
    document.querySelectorAll('#simNativeView .tb-fold-pop')
        .forEach((n) => { n.hidden = true; });
    document.querySelectorAll('#simNativeView .tb-fold-btn')
        .forEach((n) => n.setAttribute('aria-expanded', 'false'));
  }

  return { buildToolbarClusters, closeFoldMenus, layoutToolbar };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._ToolbarView = { toolbarView };
}
